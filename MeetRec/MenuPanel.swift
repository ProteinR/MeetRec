import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus (for the name field) without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The MeetRec dropdown: a rounded, translucent panel under the menu bar.
///
/// Replaces `NSPopover`, which needs a visible anchor view. Ice hides status items by moving them
/// off screen, and a popover attached to a fake anchor drew its arrow in the wrong place whenever the
/// content changed height. This panel has no arrow, keeps its top edge fixed while the SwiftUI content
/// grows or shrinks, and closes on any click outside it.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 330
    private static let gap: CGFloat = 6

    private let panel: KeyablePanel
    private let hosting: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    /// Top-left corner the panel hangs from, in screen coordinates.
    private var anchor = NSPoint.zero
    private var screen: NSScreen?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(rootView: Content) {
        hosting = NSHostingController(rootView: AnyView(rootView))
        // Only *report* the ideal size; the panel frame is set here, never by Auto Layout from SwiftUI
        // (letting a window follow SwiftUI's size crashed with an update-constraints loop).
        hosting.sizingOptions = [.preferredContentSize]
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        // Resize in the same run loop pass as the SwiftUI layout change. Deferring it (Task / async)
        // let one frame render the new content inside the old frame, which looked like a jump.
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.applySize() }
            } else {
                DispatchQueue.main.async { self?.applySize() }
            }
        }
    }

    /// Shows the panel under `itemFrame` (the status item in screen coordinates), or in the top right
    /// corner of the main screen when the item is hidden.
    func show(below itemFrame: NSRect?) {
        let targetScreen = itemFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }
        screen = targetScreen
        let visible = targetScreen.visibleFrame
        if let itemFrame {
            anchor = NSPoint(x: itemFrame.midX - Self.width / 2, y: itemFrame.minY - Self.gap)
        } else {
            anchor = NSPoint(x: visible.maxX - Self.width - 10, y: visible.maxY - Self.gap)
        }
        applySize()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        startOutsideClickMonitor()
        Log.debug("Panel shown at \(NSStringFromRect(panel.frame)) (\(itemFrame == nil ? "top right" : "under status item"))")
    }

    func close() {
        guard panel.isVisible else { return }
        stopOutsideClickMonitor()
        panel.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Another window took focus (an app was clicked, a modal opened): fold away like a menu.
        // Pop-up menus of pickers inside the panel do not resign key, so they keep working.
        if NSApp.modalWindow == nil { close() }
    }

    // MARK: - Private

    private func applySize() {
        let preferred = hosting.preferredContentSize
        guard preferred.height > 0 else { return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = min(preferred.height, visible.height - 2 * Self.gap)
        var x = anchor.x
        x = min(max(x, visible.minX + Self.gap), visible.maxX - Self.width - Self.gap)
        let frame = NSRect(x: x, y: anchor.y - height, width: Self.width, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        // Global monitors only see clicks that go to other apps, i.e. clicks outside the panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}
