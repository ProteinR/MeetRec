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

/// A window that can be recorded on its own, with a small picture of it.
struct WindowTile: Identifiable {
    let window: CaptureWindow
    /// Global, top-left origin (ScreenCaptureKit's), for the red frame on screen.
    let frame: CGRect
    var image: CGImage?
    var id: CGWindowID { window.id }
}

/// The normal windows on one display, front to back, at most `limit`, with small pictures refreshed
/// every 5 s while the monitor section is open (each picture is a capture; there can be dozens of
/// windows, so few and seldom).
@MainActor
final class WindowPreview: ObservableObject {
    static let limit = 10
    @Published private(set) var tiles: [WindowTile] = []
    /// Windows on the display beyond `limit`.
    @Published private(set) var more = 0

    private var task: Task<Void, Never>?
    private var displayID: CGDirectDisplayID?

    func start(displayID: CGDirectDisplayID) {
        guard CGPreflightScreenCaptureAccess() else { return }
        if task != nil, self.displayID == displayID { return }
        stop()
        self.displayID = displayID
        task = Task { [weak self] in
            while !Task.isCancelled {
                let (tiles, more) = await Self.capture(displayID: displayID)
                guard !Task.isCancelled, let self else { return }
                self.tiles = tiles
                self.more = more
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        displayID = nil
    }

    private static func capture(displayID: CGDirectDisplayID) async -> ([WindowTile], Int) {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return ([], 0) }
            let own = Bundle.main.bundleIdentifier
            let windows = content.windows.filter { window in
                guard window.windowLayer == 0, window.isOnScreen, window.frame.width >= 200, window.frame.height >= 150,
                      let app = window.owningApplication, app.bundleIdentifier != own, !app.applicationName.isEmpty else { return false }
                return display.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
            }
            var tiles: [WindowTile] = []
            for window in windows.prefix(limit) {
                guard let app = window.owningApplication else { continue }
                let config = SCStreamConfiguration()
                config.width = 240
                config.height = max(1, Int(240 * window.frame.height / max(window.frame.width, 1)))
                config.showsCursor = false
                let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                         configuration: config)
                tiles.append(WindowTile(window: CaptureWindow(id: window.windowID, appName: app.applicationName,
                                                              title: window.title ?? "", bundleID: app.bundleIdentifier),
                                        frame: window.frame, image: image))
            }
            return (tiles, max(0, windows.count - limit))
        } catch {
            Log.debug("Window preview failed: \(Log.describe(error))")
            return ([], 0)
        }
    }
}

/// The monitor section's content: a tile per display (the one to be recorded framed in red, like the
/// frame drawn on that screen) and the "Авто" switch.
struct DisplayChooser: View {
    @EnvironmentObject private var model: RecorderModel
    @ObservedObject var preview: DisplayPreview
    @ObservedObject var windows: WindowPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.displays) { display in
                    tile(display)
                }
            }
            if !windows.tiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.chosenWindow == nil ? "Или только одно окно этого монитора:" : "Записывается только окно — клик по нему или по монитору вернёт весь экран")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(windows.tiles) { tile in
                            windowTile(tile)
                        }
                    }
                    if windows.more > 0 {
                        Text("и ещё \(windows.more) — их можно выбрать во время записи")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
        let selected = display.id == model.effectiveDisplay?.id && model.chosenWindow == nil
        let bounds = CGDisplayBounds(display.id)
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 16 / 9
        return Button {
            model.displayID = Int(display.id)
            model.chosenWindow = nil
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

extension DisplayChooser {
    /// Like the screenshot thumbnails: the app's icon in the corner, the title in the tooltip, a red
    /// frame when chosen.
    fileprivate func windowTile(_ tile: WindowTile) -> some View {
        let selected = model.chosenWindow?.id == tile.id
        return Button {
            model.chosenWindow = selected ? nil : tile.window
        } label: {
            Color.primary.opacity(0.06)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .overlay {
                    if let image = tile.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: tile.window.bundleID).first?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16).padding(3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.red : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 0.5))
                .zIndex(selected ? 1 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Записывается только «\(tile.window.label)»; клик — весь экран" : "Записывать только «\(tile.window.label)»")
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
        window.level = Self.screenLevel
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// The same frame around one window that will be recorded alone (`frame`: global, top-left
    /// origin). It sits right above that window, among normal windows, so whatever covers the window
    /// covers the frame too, instead of the frame showing over everything.
    func show(windowFrame frame: CGRect, windowID: CGWindowID) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height).insetBy(dx: -4, dy: -4)
        let window = window ?? Self.makeWindow()
        self.window = window
        window.level = .normal
        if window.frame != rect { window.setFrame(rect, display: true) }
        window.alphaValue = 1
        window.order(.above, relativeTo: Int(windowID))
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

    /// Above the menu bar and the Dock, so a screen's frame runs along its very edge.
    private static let screenLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = screenLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        let hosting = NSHostingView(rootView: Rectangle().strokeBorder(Color.red, lineWidth: 6).ignoresSafeArea())
        hosting.sizingOptions = []
        window.contentView = hosting
        return window
    }
}
