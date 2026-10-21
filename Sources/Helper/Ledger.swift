import Foundation

struct LedgerEntry: Codable {
    let originalParent: String
    let name: String
    let trashedPath: String
    let uid: uid_t
    let device: Int64
    let inode: UInt64
}

/// Remembers what the helper moved, so it can put exactly those items back (Undo).
/// Stored root-only on disk so it survives helper restarts.
final class Ledger {
    private let url: URL
    private var entries: [String: LedgerEntry]

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        entries = data.flatMap { try? PropertyListDecoder().decode([String: LedgerEntry].self, from: $0) } ?? [:]
    }

    func record(_ entry: LedgerEntry) -> String {
        let token = UUID().uuidString
        entries[token] = entry
        save()
        return token
    }

    func entry(_ token: String) -> LedgerEntry? {
        entries[token]
    }

    func remove(_ token: String) {
        entries[token] = nil
        save()
    }

    private func save() {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? PropertyListEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}
