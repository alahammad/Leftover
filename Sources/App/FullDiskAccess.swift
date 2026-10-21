import AppKit

enum FullDiskAccess {
    /// Tries to open files that macOS only lets apps with Full Disk Access read.
    /// EPERM/EACCES means access is denied; a missing file proves nothing, so the next one is tried.
    static func isGranted() -> Bool {
        let home = NSHomeDirectory()
        let probes = [
            home + "/Library/Safari/CloudTabs.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]
        var denied = false
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return !denied
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
