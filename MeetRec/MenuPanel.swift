import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus (for the name field) without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The MeetRec dropdown under the menu bar.
///
/// The window itself is transparent and fixed in size (from the anchor down to the bottom of the
/// screen). The visible card — blur, rounded corners, border, shadow — is drawn by SwiftUI in
/// `PanelCard`, hugging the content from the top. So when a section expands or collapses, SwiftUI
/// animates the card's height smoothly and the window never has to resize mid-animation (resizing the
/// window to follow the content caused jumps). Clicks on the transparent part fall through to whatever
/// is below and close the panel, like a menu.
///
/// `NSPopover` is not used: it needs a visible anchor view, and Ice hides status items by moving them
/// off screen.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    static let cardWidth: CGFloat = 460
    /// Transparent margin around the card for its shadow.
    static let margin: CGFloat = 18
    private static let gap: CGFloat = 4

    private let panel: KeyablePanel
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel.isVisible }
    /// Called with true when the panel appears and false when it closes.
    var onVisibilityChange: ((Bool) -> Void)?

    init<Content: View>(rootView: Content) {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth + 2 * Self.margin, height: 600),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = false // SwiftUI draws the card's shadow
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let hosting = NSHostingView(rootView: PanelCard(margin: Self.margin) { rootView })
        // The window has a fixed frame; SwiftUI must not try to size it.
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    /// Shows the panel under `itemFrame` (the status item in screen coordinates), or in the top right
    /// corner of the main screen when the item is hidden.
    func show(below itemFrame: NSRect?) {
        let screen = itemFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let windowWidth = Self.cardWidth + 2 * Self.margin

        let top = (itemFrame?.minY ?? visible.maxY) - Self.gap + Self.margin
        var x = itemFrame.map { $0.midX - windowWidth / 2 } ?? (visible.maxX - windowWidth + Self.margin - 6)
        x = min(max(x, visible.minX - Self.margin + 6), visible.maxX - windowWidth + Self.margin - 6)
        let frame = NSRect(x: x, y: visible.minY, width: windowWidth, height: min(top, visible.maxY + Self.margin) - visible.minY)
        panel.setFrame(frame, display: true)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        startOutsideClickMonitor()
        onVisibilityChange?(true)
        Log.debug("Panel shown, window \(NSStringFromRect(panel.frame)) (\(itemFrame == nil ? "top right" : "under status item"))")
    }

    /// `.none` keeps the panel out of screen sharing and screenshots (in apps that honour it).
    func setSharingType(_ type: NSWindow.SharingType) {
        if panel.sharingType != type { panel.sharingType = type }
    }

    func close() {
        guard panel.isVisible else { return }
        stopOutsideClickMonitor()
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    /// Fades out instead of vanishing (after "Начать запись" / "Остановить").
    func closeAnimated() {
        guard panel.isVisible else { return }
        stopOutsideClickMonitor()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.onVisibilityChange?(false)
            }
        })
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Another app or window took focus: fold away like a menu. Pickers' pop-up menus inside the
        // panel do not resign key, so they keep working.
        if NSApp.modalWindow == nil { close() }
    }

    // MARK: - Outside clicks

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        // Global monitors only see clicks delivered to other apps: outside the card, including the
        // transparent part of this window, which lets clicks through.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

/// The visible panel: translucent blurred card hugging its content at the top of the window.
private struct PanelCard<Content: View>: View {
    let margin: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(width: MenuPanelController.cardWidth)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            Spacer(minLength: 0)
        }
        .padding(margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Behind-window blur, like menus and popovers.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
