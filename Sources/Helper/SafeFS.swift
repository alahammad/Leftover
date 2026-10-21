import Foundation

/// Filesystem operations that can't be redirected by swapping a path component for a symlink.
///
/// `~/.Trash` is privacy-protected: processes without Full Disk Access can't open or list it,
/// but they may rename items into and out of it and stat its entries. So the Trash is
/// only ever addressed by fully resolved paths with RENAME_NOFOLLOW_ANY, never opened.
enum SafeFS {
    struct Identity: Equatable {
        let device: Int64
        let inode: UInt64
    }

    private static let bundleExtensions: Set<String> = [
        "app", "bundle", "plugin", "framework", "kext", "systemextension", "prefpane", "component",
        "vst", "vst3", "driver", "qlgenerator", "mdimporter", "saver", "service", "workflow", "savedstate",
    ]

    static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw posixError(errno, path) }
        defer { free(resolved) }
        return normalized(String(cString: resolved))
    }

    static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(errno, path) }
        return fd
    }

    /// The real location of an open directory.
    static func path(of fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        guard result != -1 else { throw posixError(errno, "F_GETPATH") }
        return normalized(String(cString: buffer))
    }

    /// Returns `~/.Trash` after making sure it is a real folder (not a symlink) owned by the user.
    static func trashDirectory(home: String, uid: uid_t) throws -> String {
        let trash = home + "/.Trash"
        var st = stat()
        if lstat(trash, &st) != 0 {
            guard mkdir(trash, 0o700) == 0, lstat(trash, &st) == 0 else { throw posixError(errno, trash) }
            chown(trash, uid, gid_t(getpwuid(uid)?.pointee.pw_gid ?? 20))
            st.st_uid = uid
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else {
            throw HelperFailure("Your Trash folder isn't a normal folder owned by you, so nothing was moved.")
        }
        return trash
    }

    static func identity(dir: Int32, name: String) throws -> Identity {
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(errno, name) }
        return Identity(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// Moves `name` (inside `fromDir`) to `destination`, a fully resolved absolute path.
    /// Tries "Name", "Name 2", "Name 3"… and returns the path that was used.
    static func move(fromDir: Int32, name: String, intoFolder folder: String) throws -> String {
        // "Report 2.pdf" and "Foo 2.app", but "com.example.cache 2" for plain folders.
        var st = stat()
        let isPlainFolder = fstatat(fromDir, name, &st, AT_SYMLINK_NOFOLLOW) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
            && !bundleExtensions.contains((name as NSString).pathExtension.lowercased())
        let ext = isPlainFolder ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for counter in 1...10_000 {
            let candidate = counter == 1 ? name : (ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            let destination = folder + "/" + candidate
            if rename(fromDir: fromDir, fromPath: name, toDir: AT_FDCWD, toPath: destination) { return destination }
            guard errno == EEXIST else { throw moveError(errno, name) }
        }
        throw HelperFailure("Couldn't find a free name for \(name) in the Trash.")
    }

    /// Atomic rename that never overwrites and refuses symlinks anywhere in either path.
    @discardableResult
    static func rename(fromDir: Int32, fromPath: String, toDir: Int32, toPath: String) -> Bool {
        renameatx_np(fromDir, fromPath, toDir, toPath, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0
    }

    static func moveError(_ code: Int32, _ name: String) -> Error {
        code == EXDEV ? HelperFailure("\(name) is on a different disk than your Trash.") : posixError(code, name)
    }

    static func posixError(_ code: Int32, _ subject: String) -> Error {
        HelperFailure("\(subject): \(String(cString: strerror(code)))")
    }

    /// Firmlinked folders such as /Applications can report their Data-volume path.
    private static func normalized(_ path: String) -> String {
        let dataVolume = "/System/Volumes/Data"
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }
}
