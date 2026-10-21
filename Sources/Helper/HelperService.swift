import Foundation

final class HelperService: NSObject, NSXPCListenerDelegate {
    private static let supportFolder = "/Library/Application Support/\(BuildConfig.appBundleID)"
    private let ledger = Ledger(url: URL(fileURLWithPath: supportFolder + "/trash-ledger.plist"))

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = BuildConfig.requirement(identifier: BuildConfig.appBundleID) else {
            NSLog("Leftover helper: unsigned build, refusing connection")
            return false
        }
        // Checked against the connection's audit token on every message, unlike a PID lookup.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LeftoverHelperProtocol.self)
        connection.exportedObject = HelperSession(
            uid: connection.effectiveUserIdentifier, ledger: ledger, stagingFolder: Self.supportFolder + "/staging")
        connection.resume()
        return true
    }
}

/// One per connection, bound to the user id of the connecting app.
final class HelperSession: NSObject, LeftoverHelperProtocol {
    private static let lock = NSLock()
    private let uid: uid_t
    private let ledger: Ledger
    /// Root-only folder where restored items are verified before going back into place.
    private let stagingFolder: String

    init(uid: uid_t, ledger: Ledger, stagingFolder: String) {
        self.uid = uid
        self.ledger = ledger
        self.stagingFolder = stagingFolder
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply(BuildConfig.version)
    }

    func trashItem(atPath path: String, withReply reply: @escaping (String?, String?, String?) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            let home = try PathPolicy.homeDirectory(for: uid)
            let source = try PathPolicy.validatedSource(path, home: home)

            let parentFD = try SafeFS.openDirectory(source.parent)
            defer { close(parentFD) }
            // Re-check where the opened directory really is, in case a path component was swapped.
            try PathPolicy.requireAllowedParent(try SafeFS.path(of: parentFD), home: home)

            // Identify the item while it is still in its original folder, before the user can touch it.
            let identity = try SafeFS.identity(dir: parentFD, name: source.name)
            let trash = try SafeFS.trashDirectory(home: home, uid: uid)
            let trashedPath = try SafeFS.move(fromDir: parentFD, name: source.name, intoFolder: trash)

            let token = ledger.record(LedgerEntry(
                originalParent: source.parent, name: source.name, trashedPath: trashedPath,
                uid: uid, device: identity.device, inode: identity.inode))
            reply(token, trashedPath, nil)
        } catch {
            reply(nil, nil, error.localizedDescription)
        }
    }

    func restoreItem(token: String, withReply reply: @escaping (String?) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            guard let entry = ledger.entry(token), entry.uid == uid else {
                throw HelperFailure("This item wasn't moved by Leftover's helper.")
            }
            let home = try PathPolicy.homeDirectory(for: uid)
            let trash = try SafeFS.trashDirectory(home: home, uid: uid)
            guard entry.trashedPath.hasPrefix(trash + "/") else {
                throw HelperFailure("This item isn't in your Trash any more.")
            }

            // The Trash is writable by the user, so first pull the item somewhere only root can
            // reach, then check it is exactly the object that was moved.
            let stagingFD = try openStaging()
            defer { close(stagingFD) }
            guard SafeFS.rename(fromDir: AT_FDCWD, fromPath: entry.trashedPath, toDir: stagingFD, toPath: token) else {
                throw SafeFS.moveError(errno, entry.name)
            }
            let putBack = { _ = SafeFS.rename(fromDir: stagingFD, fromPath: token, toDir: AT_FDCWD, toPath: entry.trashedPath) }

            let identity = try SafeFS.identity(dir: stagingFD, name: token)
            guard identity == SafeFS.Identity(device: entry.device, inode: entry.inode) else {
                putBack()
                throw HelperFailure("The item in the Trash has changed since it was moved, so it won't be restored.")
            }

            let parentFD = try SafeFS.openDirectory(entry.originalParent)
            defer { close(parentFD) }
            guard try SafeFS.path(of: parentFD) == entry.originalParent else {
                putBack()
                throw HelperFailure("The original folder has moved.")
            }
            guard SafeFS.rename(fromDir: stagingFD, fromPath: token, toDir: parentFD, toPath: entry.name) else {
                let error = SafeFS.moveError(errno, entry.name)
                putBack()
                throw error
            }
            ledger.remove(token)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    private func openStaging() throws -> Int32 {
        try? FileManager.default.createDirectory(
            atPath: stagingFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try SafeFS.openDirectory(stagingFolder)
    }
}

struct HelperFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
