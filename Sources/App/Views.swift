import SwiftUI
import UniformTypeIdentifiers

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeroView(isTargeted: isDropTargeted)
                .frame(height: Theme.heroHeight)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            panel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Theme.windowWidth, height: model.windowHeight)
        .background(Theme.panel)
        // The window is sized from the area below the title bar; the full-height content
        // is bottom-aligned in it so its top runs under the transparent title bar.
        .frame(width: Theme.windowWidth, height: model.contentHeight, alignment: .bottom)
        .preferredColorScheme(.dark)
        .background(WindowAccessor { model.attach($0) })
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .alert("Couldn't Continue", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    @ViewBuilder private var panel: some View {
        if let result = model.result {
            ResultPanel(result: result)
        } else if let target = model.target {
            ReviewPanel(target: target)
        } else {
            IdlePanel()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, model.result == nil, !model.isWorking else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.load(url) }
        }
        return true
    }
}

// MARK: - Hero header

struct HeroView: View {
    @EnvironmentObject private var model: AppModel
    let isTargeted: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HeroBackground(glow: isTargeted ? 1 : 0.45)
            Group {
                if let target = model.target, model.result == nil {
                    Image(nsImage: target.icon)
                        .resizable()
                        .frame(width: Theme.iconSize, height: Theme.iconSize)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                        .opacity(model.zapIcon == nil ? 1 : 0)
                } else {
                    DropWell(isTargeted: isTargeted)
                        .opacity(model.zapIcon == nil ? 1 : 0)
                }
            }
            .position(x: Theme.windowWidth / 2, y: Theme.iconCenterFromTop)

            StatusPill()
                .padding(.top, 10)
                .padding(.trailing, 12)
        }
    }
}

/// Dark gradient with a soft glow and faint rings around the icon.
struct HeroBackground: View {
    let glow: Double

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Theme.heroTop, Theme.heroBottom]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            let center = CGPoint(x: size.width / 2, y: Theme.iconCenterFromTop)
            context.fill(Path(rect), with: .radialGradient(
                Gradient(colors: [Theme.accent.opacity(0.22 * glow), .clear]),
                center: center, startRadius: 0, endRadius: 200))

            for radius in stride(from: CGFloat(78), through: 420, by: 28) {
                let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.045 * (1 - radius / 460))), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: glow)
    }
}

struct DropWell: View {
    @EnvironmentObject private var model: AppModel
    let isTargeted: Bool

    var body: some View {
        Button(action: model.chooseApp) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(isTargeted ? 0.35 : 0.22))
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Theme.accent : Color.white.opacity(0.28),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(isTargeted ? Theme.accent : Color.white.opacity(0.6))
            }
            .frame(width: 104, height: 104)
            .scaleEffect(isTargeted ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
        }
        .buttonStyle(.plain)
        .help("Drop an app here, or click to choose one")
    }
}

struct StatusPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let state = pillState
        Button(action: state.action ?? {}) {
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(state.text)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.25)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .disabled(state.action == nil)
    }

    private var pillState: (text: String, color: Color, action: (() -> Void)?) {
        if !model.hasFullDiskAccess { return ("Full Disk Access Off", .orange, FullDiskAccess.openSettings) }
        switch model.helperStatus {
        case .enabled: return ("Ready", .green, nil)
        case .unsigned: return ("Ready", .green, nil)
        case .notRegistered: return ("Helper Off", .orange, model.enableHelper)
        case .requiresApproval: return ("Approve Helper", .orange, model.helper.openApprovalSettings)
        }
    }
}

// MARK: - Panels

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
    }
}

/// Eyebrow, title, explanation and a call to action, laid out like a card.
struct PanelCard<Actions: View>: View {
    let eyebrow: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .heavy))
                .tracking(2.2)
                .foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 24, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                actions()
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct IdlePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.hasFullDiskAccess && !model.setupDismissed {
            PanelCard(
                eyebrow: "QUICK SETUP",
                title: "Allow Full Disk Access",
                message: "Leftover needs Full Disk Access to see inside protected folders. Add Leftover under Privacy & Security › Full Disk Access, then come back.") {
                Button("Not Now") { model.setupDismissed = true }.buttonStyle(QuietButtonStyle())
                Button("Open Full Disk Access", action: FullDiskAccess.openSettings).buttonStyle(AccentButtonStyle())
            }
        } else if model.helperStatus == .notRegistered && !model.setupDismissed {
            PanelCard(
                eyebrow: "ONE MORE STEP",
                title: "Install the Helper",
                message: "Some apps leave files that belong to the system, like background services. The helper moves those to the Trash for you.") {
                Button("Not Now") { model.setupDismissed = true }.buttonStyle(QuietButtonStyle())
                Button("Install Helper", action: model.enableHelper).buttonStyle(AccentButtonStyle())
            }
        } else if model.helperStatus == .requiresApproval && !model.setupDismissed {
            PanelCard(
                eyebrow: "ONE MORE STEP",
                title: "Approve the Helper",
                message: "macOS asks you to allow background helpers. Switch Leftover on under General › Login Items.") {
                Button("Not Now") { model.setupDismissed = true }.buttonStyle(QuietButtonStyle())
                Button("Open Login Items", action: model.helper.openApprovalSettings).buttonStyle(AccentButtonStyle())
            }
        } else {
            PanelCard(
                eyebrow: "READY",
                title: "Drop an app to remove it",
                message: model.helperStatus == .enabled
                    ? "Leftover finds the files an app left behind and moves everything to the Trash."
                    : "Leftover finds the files an app left behind and moves everything to the Trash. Items marked with a lock need your password.") {
                Button("Choose App…", action: model.chooseApp).buttonStyle(AccentButtonStyle())
            }
        }
    }
}

struct ReviewPanel: View {
    @EnvironmentObject private var model: AppModel
    let target: AppTarget

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Text([target.bundleID, target.version].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Text(formatBytes(model.selectedBytes))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !target.runningInstances.isEmpty {
                HStack {
                    Image(systemName: "play.circle.fill").foregroundStyle(.orange)
                    Text("\(target.name) is running.").font(.system(size: 13))
                    Spacer()
                    Button("Quit \(target.name)", action: model.quitTarget).controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.12))
            }

            if model.isScanning {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($model.files) { $file in
                            FileRow(file: $file)
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.leading, 56)
                        }
                    }
                }
                .background(Color.black.opacity(0.18))
            }

            HStack {
                Button("Cancel", action: model.reset).buttonStyle(QuietButtonStyle())
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Move \(model.selectedFiles.count) to Trash") {
                    Task { await model.removeSelected() }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedFiles.isEmpty || model.isWorking || model.isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct FileRow: View {
    @Binding var file: RelatedFile

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $file.isSelected).labelsHidden().controlSize(.small)
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).font(.system(size: 13)).lineLimit(1)
                Text("\(file.category.label) · \(file.displayLocation)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !file.userCanRemove {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Owned by the system: removed through the helper, or after asking for your password")
            }
            Text(formatBytes(file.size))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(file.reason)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }
}

struct ResultPanel: View {
    @EnvironmentObject private var model: AppModel
    let result: RemovalResult

    var body: some View {
        PanelCard(
            eyebrow: result.failures.isEmpty ? "DONE" : "PARTLY DONE",
            title: "Moved \(result.moved.count) items to the Trash",
            message: failureText ?? "Empty the Trash to free up \(formatBytes(result.bytes)).") {
            Button("Undo") { Task { await model.undo() } }
                .buttonStyle(QuietButtonStyle())
                .disabled(result.moved.isEmpty || model.isWorking)
            Button("Done", action: model.reset)
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private var failureText: String? {
        guard let first = result.failures.first else { return nil }
        let more = result.failures.count > 1 ? " (and \(result.failures.count - 1) more)" : ""
        return "Couldn't move \(first.url.lastPathComponent)\(more): \(first.message)"
    }
}
