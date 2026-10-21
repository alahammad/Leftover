import Foundation

/// Folders (relative to `~/Library` and `/Library`) where apps leave files behind.
/// The app scans them; the helper only agrees to move items located inside them.
enum SearchLocations {
    static let librarySubpaths = [
        "Application Scripts",
        "Application Support",
        "Application Support/CrashReporter",
        "Caches",
        "Containers",
        "Group Containers",
        "Cookies",
        "HTTPStorages",
        "WebKit",
        "Internet Plug-Ins",
        "LaunchAgents",
        "LaunchDaemons",
        "PrivilegedHelperTools",
        "Logs",
        "Logs/DiagnosticReports",
        "Preferences",
        "Preferences/ByHost",
        "SyncedPreferences",
        "Saved Application State",
        "Services",
        "QuickLook",
        "Spotlight",
        "PreferencePanes",
        "Screen Savers",
        "Input Methods",
        "Extensions",
        "Audio/Plug-Ins/Components",
        "Audio/Plug-Ins/VST",
        "Audio/Plug-Ins/VST3",
        "Audio/Plug-Ins/HAL",
        "Audio/MIDI Drivers",
    ]

    static let receipts = "/private/var/db/receipts"
}
