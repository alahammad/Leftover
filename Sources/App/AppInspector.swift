import AppKit

struct AppTarget: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let bundleName: String?
    let version: String?

    var id: URL { url }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }
}

enum InspectError: LocalizedError {
    case notAnApp
    case noBundleID
    case systemApp(String)
    case isSelf

    var errorDescription: String? {
        switch self {
        case .notAnApp: "That isn't an application."
        case .noBundleID: "This app has no bundle identifier, so its files can't be found reliably."
        case .systemApp(let name): "\(name) is part of macOS and can't be removed."
        case .isSelf: "Leftover can't remove itself while it's running."
        }
    }
}

enum AppInspector {
    /// Apple apps that ship with macOS. Apps under /System are refused as well.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS",
        "com.apple.FaceTime", "com.apple.AddressBook", "com.apple.iCal", "com.apple.reminders",
        "com.apple.Notes", "com.apple.Maps", "com.apple.Photos", "com.apple.Music", "com.apple.TV",
        "com.apple.podcasts", "com.apple.AppStore", "com.apple.systempreferences",
    ]

    static func inspect(_ url: URL) throws -> AppTarget {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension == "app", let bundle = Bundle(url: resolved) else {
            throw InspectError.notAnApp
        }
        guard let bundleID = bundle.bundleIdentifier else { throw InspectError.noBundleID }

        let name = resolved.deletingPathExtension().lastPathComponent
        if resolved.path.hasPrefix("/System/") || protectedBundleIDs.contains(bundleID) {
            throw InspectError.systemApp(name)
        }
        if bundleID == Bundle.main.bundleIdentifier { throw InspectError.isSelf }

        return AppTarget(
            url: resolved,
            name: name,
            bundleID: bundleID,
            bundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}
