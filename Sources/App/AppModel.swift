import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var target: AppTarget?
    @Published var files: [RelatedFile] = []
    @Published var isScanning = false
    @Published var isWorking = false
    @Published var result: RemovalResult?
    /// Icon of the app being zapped while the removal animation plays.
    @Published var zapIcon: NSImage?
    @Published var errorMessage: String?
    @Published var hasFullDiskAccess = FullDiskAccess.isGranted()
    @Published var helperStatus: HelperClient.Status

    /// Hides the setup card for this session ("Not Now").
    @Published var setupDismissed = false

    let helper = HelperClient()
    private var trasher: Trasher { Trasher(helper: helper) }
    private weak var window: NSWindow?
    private let zapOverlay = ZapOverlay()

    /// Height of the (transparent) title bar, which macOS adds on top of the SwiftUI content.
    @Published private var titleBarInset: CGFloat = 0

    /// Outer height of the window, title bar included.
    var windowHeight: CGFloat {
        target != nil && result == nil ? Theme.reviewHeight : Theme.compactHeight
    }

    /// Height below the title bar; macOS sizes the window from this.
    var contentHeight: CGFloat { windowHeight - titleBarInset }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.applyLeftoverChrome()
        titleBarInset = window.frame.height - window.contentLayoutRect.height
    }

    private func playZap(_ icon: NSImage) {
        zapIcon = icon
        zapOverlay.play(icon: icon, over: window) { [weak self] in self?.zapIcon = nil }
    }

    init() {
        helperStatus = helper.status
    }

    var selectedFiles: [RelatedFile] { files.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    func start() async {
        refreshPermissions()
        // Debug aid: LEFTOVER_DEMO_ZAP=/Applications/Foo.app plays the animation without removing anything.
        if let demo = ProcessInfo.processInfo.environment["LEFTOVER_DEMO_ZAP"] {
            try? await Task.sleep(nanoseconds: 600_000_000)   // let the window settle first
            playZap(NSWorkspace.shared.icon(forFile: demo))
        }
        guard helperStatus == .enabled else { return }
        // A helper from an older build keeps running old code until it is registered again.
        if (try? await helper.version()) != BuildConfig.version {
            try? await helper.reregister()
            refreshPermissions()
        }
    }

    func refreshPermissions() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
        helperStatus = helper.status
        objectWillChange.send()   // running-state of the target may have changed too
    }

    func load(_ url: URL) {
        do {
            let app = try AppInspector.inspect(url)
            target = app
            result = nil
            scan(app)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func scan(_ app: AppTarget) {
        isScanning = true
        files = []
        Task.detached(priority: .userInitiated) {
            let found = RelatedFileFinder().find(for: app)
            await MainActor.run {
                guard self.target == app else { return }
                self.files = found
                self.isScanning = false
            }
        }
    }

    func quitTarget() {
        target?.runningInstances.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshPermissions()
        }
    }

    func removeSelected() async {
        guard let target else { return }
        if !target.runningInstances.isEmpty {
            errorMessage = "Quit \(target.name) first, then remove it."
            return
        }
        isWorking = true
        let icon = target.icon   // once the app is in the Trash its icon becomes generic
        let files = selectedFiles
        let outcome = await trasher.trash(files.map(\.url))
        let movedURLs = Set(outcome.moved.map(\.original))
        let result = RemovalResult(
            moved: outcome.moved,
            failures: outcome.failures,
            bytes: files.filter { movedURLs.contains($0.url) }.reduce(0) { $0 + $1.size })
        self.result = result
        isWorking = false
        if !result.moved.isEmpty { playZap(icon) }
    }

    func undo() async {
        guard let result else { return }
        isWorking = true
        let failures = await trasher.restore(result.moved)
        isWorking = false
        self.result = nil
        if !failures.isEmpty {
            errorMessage = "Some items couldn't be put back:\n" + failures.joined(separator: "\n")
        }
        if let target { scan(target) }
    }

    func reset() {
        target = nil
        files = []
        result = nil
    }

    func enableHelper() {
        do {
            try helper.register()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshPermissions()
        if helperStatus == .requiresApproval { helper.openApprovalSettings() }
    }
}
