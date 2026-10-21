import Foundation

struct TrashRecord {
    enum Method {
        case direct
        case helper(token: String)
        case administrator
    }

    let original: URL
    let trashed: URL
    let method: Method
}

struct RemovalResult {
    var moved: [TrashRecord] = []
    var failures: [(url: URL, message: String)] = []
    var bytes: Int64 = 0
}

/// Moves items to the Trash: directly when the user is allowed to; otherwise through the
/// helper if it's installed, or with one administrator password prompt if it isn't.
struct Trasher {
    let helper: HelperClient

    func trash(_ urls: [URL]) async -> (moved: [TrashRecord], failures: [(url: URL, message: String)]) {
        var moved: [TrashRecord] = []
        var failures: [(url: URL, message: String)] = []
        var needsRoot: [URL] = []

        for url in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                moved.append(TrashRecord(original: url, trashed: (resulting as URL?) ?? url, method: .direct))
            } catch let error as NSError where Self.isPermissionDenied(error) {
                needsRoot.append(url)
            } catch {
                failures.append((url, error.localizedDescription))
            }
        }
        guard !needsRoot.isEmpty else { return (moved, failures) }

        if helper.status == .enabled {
            for url in needsRoot {
                do {
                    let result = try await helper.trash(path: url.path)
                    moved.append(TrashRecord(
                        original: url, trashed: URL(fileURLWithPath: result.trashedPath), method: .helper(token: result.token)))
                } catch {
                    failures.append((url, error.localizedDescription))
                }
            }
        } else {
            let moves = AdminMover.trashMoves(for: needsRoot)
            do {
                let succeeded = try await MainActor.run { try AdminMover.run(moves) }
                for (index, move) in moves.enumerated() {
                    if succeeded.contains(index) {
                        moved.append(TrashRecord(original: move.from, trashed: move.to, method: .administrator))
                    } else {
                        failures.append((move.from, "Couldn't move it to the Trash, even with administrator rights."))
                    }
                }
            } catch {
                failures += needsRoot.map { ($0, error.localizedDescription) }
            }
        }
        return (moved, failures)
    }

    /// Puts records back, newest first. Returns a message per item that couldn't be restored.
    func restore(_ records: [TrashRecord]) async -> [String] {
        var failures: [String] = []
        var adminMoves: [AdminMover.Move] = []

        for record in records.reversed() {
            do {
                switch record.method {
                case .direct:
                    try FileManager.default.moveItem(at: record.trashed, to: record.original)
                case .helper(let token):
                    try await helper.restore(token: token)
                case .administrator:
                    adminMoves.append(AdminMover.Move(from: record.trashed, to: record.original))
                }
            } catch {
                failures.append("\(record.original.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !adminMoves.isEmpty {
            let moves = adminMoves
            do {
                let succeeded = try await MainActor.run { try AdminMover.run(moves) }
                for (index, move) in adminMoves.enumerated() where !succeeded.contains(index) {
                    failures.append("\(move.to.lastPathComponent): couldn't be put back.")
                }
            } catch {
                failures += adminMoves.map { "\($0.to.lastPathComponent): \(error.localizedDescription)" }
            }
        }
        return failures
    }

    static func isPermissionDenied(_ error: NSError) -> Bool {
        let permissionCodes = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
        if error.domain == NSCocoaErrorDomain, permissionCodes.contains(error.code) { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }
}
