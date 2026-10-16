import AppKit
import ScreenCaptureKit
import SwiftUI

/// Small, regularly refreshed pictures of all displays, for choosing the one to record. Runs only
/// while the monitor section of the panel is open; never asks for permission (without Screen
/// Recording access the tiles just show an icon).
@MainActor
final class DisplayPreview: ObservableObject {
    @Published private(set) var images: [CGDirectDisplayID: CGImage] = [:]

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil, CGPreflightScreenCaptureAccess() else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let images = await Self.capture()
                guard !Task.isCancelled, let self else { return }
                self.images = images
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func capture() async -> [CGDirectDisplayID: CGImage] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // Without MeetRec's own windows, like the recording itself (the panel and the red frame).
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            var images: [CGDirectDisplayID: CGImage] = [:]
            for display in content.displays {
                let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 400
                config.height = max(1, Int(400 * Double(display.height) / Double(max(display.width, 1))))
                config.showsCursor = false
                images[display.displayID] = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            return images
        } catch {
            Log.debug("Display preview failed: \(Log.describe(error))")
            return [:]
        }
    }
}

/// The monitor section's content: a tile per display (the one to be recorded framed in red, like the
/// frame drawn on that screen) and the "Авто" switch.
struct DisplayChooser: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject var preview: DisplayPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.displays) { display in
                    tile(display)
                }
            }
            Toggle("Авто: внешний монитор, если подключён", isOn: Binding(
                get: { model.displayID == RecorderModel.autoDisplay },
                set: { auto in
                    if auto {
                        model.displayID = RecorderModel.autoDisplay
                    } else if let display = model.effectiveDisplay {
                        model.displayID = Int(display.id)
                    }
                }))
            if !CGPreflightScreenCaptureAccess() {
                Text("Нет доступа к записи экрана — превью не показать").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
    }

    private func tile(_ display: DisplayInfo) -> some View {
        let selected = display.id == model.effectiveDisplay?.id
        let bounds = CGDisplayBounds(display.id)
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 16 / 9
        return Button {
            model.displayID = Int(display.id)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    if let image = preview.images[display.id] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "display").foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.red : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1)
                )
                Text(display.name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(display.isBuiltIn ? "встроенный" : "внешний")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
        .help(selected ? "Этот монитор будет записан" : "Записывать этот монитор")
    }
}

/// A red frame around the whole screen that will be recorded: steady while the monitor section is
/// open, and three soft blinks when a recording starts or moves to another screen, so the choice is
/// visible on the monitor itself. Click-through and left out of the recording and previews (MeetRec's
/// own windows are excluded).
@MainActor
final class DisplayHighlight {
    static let shared = DisplayHighlight()

    private var window: NSWindow?
    private var flashWindow: NSWindow?
    private var flashTask: Task<Void, Never>?

    func show(displayID: CGDirectDisplayID) {
        guard let screen = Self.screen(displayID) else { hide(); return }
        let window = window ?? Self.makeWindow()
        self.window = window
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Three smooth blinks on the recorded screen. Not in the discreet style, which shows nothing.
    func flash(displayID: CGDirectDisplayID) {
        guard MenuBarStyle.current != .discreet, let screen = Self.screen(displayID) else { return }
        flashTask?.cancel()
        let window = flashWindow ?? Self.makeWindow()
        flashWindow = window
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        Log.debug("Flashing the frame on display \(displayID)")
        flashTask = Task { [weak self] in
            for _ in 0..<3 {
                await Self.fade(window, to: 1, duration: 0.35)
                try? await Task.sleep(for: .seconds(0.15))
                await Self.fade(window, to: 0, duration: 0.45)
                try? await Task.sleep(for: .seconds(0.1))
                if Task.isCancelled { return }
            }
            window.orderOut(nil)
            self?.flashTask = nil
        }
    }

    private static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = alpha
            }, completionHandler: { continuation.resume() })
        }
    }

    private static func screen(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above the menu bar and the Dock, so the frame runs along the very edge of the screen.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        let hosting = NSHostingView(rootView: Rectangle().strokeBorder(Color.red, lineWidth: 6).ignoresSafeArea())
        hosting.sizingOptions = []
        window.contentView = hosting
        return window
    }
}
