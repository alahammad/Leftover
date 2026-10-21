import Foundation

/// Decides which items the helper is willing to move.
enum PathPolicy {
    struct Source {
        let parent: String   // fully resolved parent directory
        let name: String     // last path component (not resolved, so symlinks are moved, not followed)
    }

    static func homeDirectory(for uid: uid_t) throws -> String {
        guard uid != 0, let entry = getpwuid(uid), let dir = entry.pointee.pw_dir else {
            throw HelperFailure("Couldn't find the home folder of the requesting user.")
        }
        return try SafeFS.realPath(String(cString: dir))
    }

    static func validatedSource(_ raw: String, home: String) throws -> Source {
        let components = (raw as NSString).pathComponents
        guard raw.hasPrefix("/"), components.count > 2,
              !components.contains(".."), !components.contains(".") else {
            throw HelperFailure("Refusing an unusual path: \(raw)")
        }
        let name = (raw as NSString).lastPathComponent
        let parent = try SafeFS.realPath((raw as NSString).deletingLastPathComponent)
        try requireAllowedParent(parent, home: home)
        return Source(parent: parent, name: name)
    }

    /// An item may be moved only if it sits somewhere inside one of the allowed roots.
    static func requireAllowedParent(_ parent: String, home: String) throws {
        let isAllowed = allowedRoots(home: home).contains { root in
            parent == root || parent.hasPrefix(root + "/")
        }
        guard isAllowed else {
            throw HelperFailure("Leftover's helper doesn't remove items from \(parent).")
        }
    }

    static func allowedRoots(home: String) -> [String] {
        var roots = ["/Applications", home + "/Applications", SearchLocations.receipts]
        for base in ["/Library", home + "/Library"] {
            roots += SearchLocations.librarySubpaths.map { base + "/" + $0 }
        }
        return roots
    }
}
