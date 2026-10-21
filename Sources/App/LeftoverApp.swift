import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count {
            exit(CommandLineScan.run(path: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count {
            exit(CommandLineScan.selfTest(path: arguments[index + 1]))
        }
        LeftoverApp.main()
    }
}

struct LeftoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single window, like a utility: opening an app reuses it instead of adding windows.
        Window("Leftover", id: "main") {
            ContentView()
                .environmentObject(model)
                .task { await model.start() }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openAppNotification)) { note in
                    if let url = note.object as? URL { model.load(url) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openAppNotification = Notification.Name("LeftoverOpenApp")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// An app dropped on the Dock icon, or `open -a Leftover Foo.app`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // Give the window a moment to exist when this launches the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: Self.openAppNotification, object: url)
        }
    }
}

/// `Leftover --scan /Applications/Foo.app` prints what would be removed, without removing anything.
enum CommandLineScan {
    static func run(path: String) -> Int32 {
        do {
            let app = try AppInspector.inspect(URL(fileURLWithPath: path))
            print("App:         \(app.name) (\(app.bundleID)) \(app.version ?? "")")
            print("Full Disk:   \(FullDiskAccess.isGranted() ? "granted" : "NOT granted")")
            print("Helper:      \(HelperClient().status)")
            print("Running:     \(app.runningInstances.isEmpty ? "no" : "yes")")
            let files = RelatedFileFinder().find(for: app)
            for file in files {
                let mark = file.isSelected ? "[x]" : "[ ]"
                let lock = file.userCanRemove ? " " : "🔒"
                let size = formatBytes(file.size).padding(toLength: 10, withPad: " ", startingAt: 0)
                let category = file.category.label.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("\(mark)\(lock) \(category) \(size) \(file.url.path)   — \(file.reason)")
            }
            let total = files.filter(\.isSelected).reduce(0) { $0 + $1.size }
            print("\(files.count) items, \(formatBytes(total)) selected")
            return 0
        } catch {
            print("Error: \(error.localizedDescription)")
            return 1
        }
    }

    /// `Leftover --selftest /path/Test.app` trashes the ticked items, checks they reached the
    /// Trash, then restores them and checks they're back. Meant for throwaway test apps.
    static func selfTest(path: String) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            defer { done.signal() }
            do {
                let app = try AppInspector.inspect(URL(fileURLWithPath: path))
                let files = RelatedFileFinder().find(for: app).filter(\.isSelected)
                let trasher = Trasher(helper: HelperClient())
                let outcome = await trasher.trash(files.map(\.url))
                for record in outcome.moved {
                    let ok = !FileManager.default.fileExists(atPath: record.original.path)
                        && FileManager.default.fileExists(atPath: record.trashed.path)
                    print("\(ok ? "trashed " : "FAILED  ") \(record.original.path) -> \(record.trashed.path) (\(record.method))")
                    if !ok { status = 1 }
                }
                for failure in outcome.failures {
                    print("FAILED   \(failure.url.path): \(failure.message)")
                    status = 1
                }
                let restoreFailures = await trasher.restore(outcome.moved)
                for record in outcome.moved {
                    let ok = FileManager.default.fileExists(atPath: record.original.path)
                    print("\(ok ? "restored" : "FAILED  ") \(record.original.path)")
                    if !ok { status = 1 }
                }
                restoreFailures.forEach { print("FAILED   \($0)") }
            } catch {
                print("Error: \(error.localizedDescription)")
                status = 1
            }
        }
        done.wait()
        print(status == 0 ? "Self-test passed" : "Self-test FAILED")
        return status
    }
}
