import Foundation

/// Moves items that need root, by asking for an administrator password once per batch
/// (the same prompt Finder shows). Used when the privileged helper isn't installed.
enum AdminMover {
    struct Move {
        let from: URL
        let to: URL
    }

    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "The administrator password was cancelled."
            case .failed(let message): message
            }
        }
    }

    /// Plans moves of `urls` into the user's Trash, with names that don't collide.
    static func trashMoves(for urls: [URL]) -> [Move] {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        var taken: Set<String> = []
        return urls.map { url in
            let name = url.lastPathComponent
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            var candidate = name
            var counter = 2
            var st = stat()
            // lstat works inside the privacy-protected Trash even though listing it doesn't.
            while taken.contains(candidate) || lstat(trash.appendingPathComponent(candidate).path, &st) == 0 {
                candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            taken.insert(candidate)
            return Move(from: url, to: trash.appendingPathComponent(candidate))
        }
    }

    /// Runs all moves in one privileged shell and returns the indices of those that succeeded.
    @MainActor
    static func run(_ moves: [Move]) throws -> Set<Int> {
        guard !moves.isEmpty else { return [] }
        let source = "do shell script \(appleScriptQuoted(shellCommand(for: moves))) with administrator privileges"

        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if (error?[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.failed(error?[NSAppleScript.errorMessage] as? String ?? "Couldn't get administrator rights.")
        }
        let output = result.stringValue ?? ""
        let reported = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line in line.hasPrefix("ok:") ? Int(line.dropFirst(3)) : nil }
        // Trust the filesystem over the output: the item must have left and arrived.
        return Set(reported.filter { index in
            var st = stat()
            return lstat(moves[index].from.path, &st) != 0 && lstat(moves[index].to.path, &st) == 0
        })
    }

    /// `mv -n` never overwrites; each move reports its own success, so one failure doesn't stop the rest.
    static func shellCommand(for moves: [Move]) -> String {
        moves.enumerated()
            .map { index, move in "/bin/mv -n \(shellQuoted(move.from.path)) \(shellQuoted(move.to.path)) && echo ok:\(index)" }
            .joined(separator: "; ") + "; true"
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
