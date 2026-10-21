import Foundation

enum FileCategory: String, CaseIterable {
    case application, support, cache, container, preferences, launchItem, log, state, webData, plugin, receipt

    var label: String {
        switch self {
        case .application: "App"
        case .support: "Support"
        case .cache: "Cache"
        case .container: "Container"
        case .preferences: "Preferences"
        case .launchItem: "Launch item"
        case .log: "Logs"
        case .state: "Saved state"
        case .webData: "Web data"
        case .plugin: "Plug-in"
        case .receipt: "Receipt"
        }
    }
}

struct RelatedFile: Identifiable, Hashable {
    let url: URL
    let category: FileCategory
    let reason: String
    let size: Int64
    /// False when the parent folder isn't writable by the user, so the helper is needed.
    let userCanRemove: Bool
    var isSelected: Bool

    var id: URL { url }

    var displayLocation: String {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }
}

/// Finds an app's leftovers by matching folder entries against its bundle identifier and names.
struct RelatedFileFinder {
    private let fm = FileManager.default

    func find(for app: AppTarget) -> [RelatedFile] {
        let matcher = NameMatcher(app: app)
        var seen: Set<String> = [app.url.path]
        var results = [makeFile(app.url, .application, reason: "The application", selected: true)]

        for (root, category) in roots() {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries {
                guard let match = matcher.match(entry) else { continue }
                let url = root.appendingPathComponent(entry)
                guard seen.insert(url.path).inserted else { continue }
                results.append(makeFile(url, category, reason: match.reason, selected: match.isStrong))
            }
        }
        return results
    }

    private func makeFile(_ url: URL, _ category: FileCategory, reason: String, selected: Bool) -> RelatedFile {
        RelatedFile(
            url: url,
            category: category,
            reason: reason,
            size: Self.allocatedSize(of: url),
            userCanRemove: Self.userCanMove(url),
            isSelected: selected)
    }

    private func roots() -> [(URL, FileCategory)] {
        var roots: [(URL, FileCategory)] = []
        let bases = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library"), URL(fileURLWithPath: "/Library")]
        for base in bases {
            for subpath in SearchLocations.librarySubpaths {
                roots.append((base.appendingPathComponent(subpath), Self.category(forSubpath: subpath)))
            }
        }
        roots.append((URL(fileURLWithPath: SearchLocations.receipts), .receipt))
        for name in [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR] {
            if let dir = Self.darwinDirectory(name) { roots.append((dir, .cache)) }
        }
        return roots
    }

    static func category(forSubpath subpath: String) -> FileCategory {
        switch subpath {
        case "Caches": .cache
        case "Containers", "Group Containers", "Application Scripts": .container
        case "Preferences", "Preferences/ByHost", "SyncedPreferences": .preferences
        case "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools": .launchItem
        case "Logs", "Logs/DiagnosticReports", "Application Support/CrashReporter": .log
        case "Saved Application State": .state
        case "Cookies", "HTTPStorages", "WebKit": .webData
        case "Application Support": .support
        default: .plugin
        }
    }

    /// Per-user temp/cache folders under /var/folders (what `getconf DARWIN_USER_TEMP_DIR` prints).
    static func darwinDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(name, &buffer, length)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    /// Moving needs a writable parent; moving a folder (an .app is one) to another folder
    /// also needs write access to the folder itself, because its ".." entry changes.
    static func userCanMove(_ url: URL) -> Bool {
        guard access(url.deletingLastPathComponent().path, W_OK) == 0 else { return false }
        var isDirectory: ObjCBool = false
        let isRealFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        return !isRealFolder || access(url.path, W_OK) == 0
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Matches file names against an app's identity. Comparisons are case-insensitive, and a
/// match inside a longer name only counts at word boundaries ("telegram" ≠ "telegramx").
struct NameMatcher {
    struct Match {
        let reason: String
        let isStrong: Bool
    }

    private let exactBundleID: String
    private let bundleID: String
    private let names: [String]

    init(app: AppTarget) {
        exactBundleID = app.bundleID
        bundleID = app.bundleID.lowercased()
        var names: [String] = []
        for name in [app.name, app.bundleName].compactMap({ $0?.lowercased() }) where name.count >= 3 {
            names.append(name)
            let squashed = name.filter { !$0.isWhitespace }
            if squashed != name { names.append(squashed) }
        }
        self.names = Array(Set(names))
    }

    /// Only these are treated as file extensions; "com.foo.app.ShipIt" keeps its last component.
    private static let fileExtensions: Set<String> = [
        "plist", "savedstate", "binarycookies", "bom", "db", "log", "ips", "diag", "crash", "json", "lockfile",
    ]

    func match(_ fileName: String) -> Match? {
        let lower = fileName.lowercased()
        let ext = (lower as NSString).pathExtension
        let stem = Self.fileExtensions.contains(ext) ? (lower as NSString).deletingPathExtension : lower

        if lower == bundleID || stem == bundleID {
            return Match(reason: "Named after the bundle identifier", isStrong: true)
        }
        if Self.containsWord(lower, bundleID) {
            // Bundle identifiers are case-sensitive: "com.google.chrome.for.testing" is a
            // different app than "com.google.Chrome", so case-only matches start unticked.
            let exactCase = Self.containsWord(fileName, exactBundleID)
            return Match(reason: "Contains the bundle identifier", isStrong: exactCase)
        }
        for name in names {
            if lower == name || stem == name {
                return Match(reason: "Named after the app", isStrong: name.count >= 4)
            }
            // Short names like "TV" or "Go" would match far too much inside longer names.
            // Longer ones still hit other tools from the same vendor ("claude-cli-nodejs"),
            // so these are listed for review but never ticked automatically.
            if name.count >= 4, Self.containsWord(lower, name) {
                return Match(reason: "Contains the app name", isStrong: false)
            }
        }
        return nil
    }

    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let before = found.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: found.lowerBound)]
            let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }
}
