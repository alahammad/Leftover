import SwiftUI

/// Layout constants shared by the window, the hero header and the zap overlay.
enum Theme {
    static let windowWidth: CGFloat = 460
    static let compactHeight: CGFloat = 390
    static let reviewHeight: CGFloat = 600
    static let heroHeight: CGFloat = 190
    static let iconSize: CGFloat = 112
    /// Distance from the window's top edge to the centre of the hero icon.
    static let iconCenterFromTop: CGFloat = 104

    static let accent = Color(red: 0.36, green: 0.84, blue: 0.96)
    static let heroTop = Color(red: 0.21, green: 0.22, blue: 0.24)
    static let heroBottom = Color(red: 0.15, green: 0.16, blue: 0.17)
    static let panel = Color(red: 0.13, green: 0.14, blue: 0.15)
}

/// Hands the hosting NSWindow to `onWindow` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSWindow {
    /// Compact, fixed-size utility window whose content runs under a transparent title bar.
    func applyLeftoverChrome() {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        styleMask.insert(.fullSizeContentView)
        styleMask.remove(.resizable)
        standardWindowButton(.zoomButton)?.isEnabled = false
        backgroundColor = NSColor(Theme.panel)
    }
}

/// A transparent, click-through window over the main window, so the zap can
/// spill past the window's edges.
@MainActor
final class ZapOverlay {
    private var panel: NSPanel?

    func play(icon: NSImage, over window: NSWindow?, completion: @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }
        finish()
        let side: CGFloat = 900
        let center = CGPoint(x: window.frame.midX, y: window.frame.maxY - Theme.iconCenterFromTop)
        let panel = UnconstrainedPanel(
            contentRect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ZapAnimationView(icon: icon, iconSize: Theme.iconSize, showsBackdrop: false) {
            [weak self] in
            self?.finish()
            completion()
        })
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
    }

    private func finish() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}

/// macOS normally pushes windows below the menu bar; the overlay must stay centred on the icon
/// even when the main window sits near the top of the screen.
private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
