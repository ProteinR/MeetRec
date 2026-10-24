import AppKit
import Carbon
import ScreenCaptureKit

/// A screen as it was when the shortcut was pressed: its picture and where the windows were. The
/// selection is drawn over this frozen picture, so menus, tooltips and hover states that close when
/// MeetRec takes focus are still in the shot, and a meeting's video does not move on meanwhile.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    /// Other apps' normal windows on this screen in overlay view coordinates (bottom-left origin),
    /// topmost first; a click without dragging takes the one under the cursor.
    let windows: [CGRect]
    /// What captures the desktop picture alone, for the margin around a window shot: only when a
    /// window is clicked (the wallpaper does not change meanwhile). nil when it was not found.
    let wallpaper: (filter: SCContentFilter, configuration: SCStreamConfiguration)?

    /// macOS window corners (points); outside them the wallpaper shows, not what was behind.
    static let windowCornerRadius: CGFloat = 12

    /// Every display without MeetRec's own windows (toast, panel, island), all at once.
    static func captureAll() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == getpid() }
        let windows = onScreenWindows()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var jobs: [(screen: NSScreen, filter: SCContentFilter, configuration: SCStreamConfiguration,
                    wallpaper: (filter: SCContentFilter, configuration: SCStreamConfiguration)?)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            // 8 bits per channel: the default format took 8 bytes per pixel (46 MB for one Retina screen).
            config.pixelFormat = kCVPixelFormatType_32BGRA
            // Desktop-level windows except Finder's icons: the wallpaper as it is shown.
            let desktop = content.windows.filter { window in
                window.windowLayer < 0 && window.isOnScreen && window.frame.intersects(display.frame)
                    && window.owningApplication?.bundleIdentifier != "com.apple.finder"
            }
            jobs.append((screen, SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), config,
                         desktop.isEmpty ? nil : (SCContentFilter(display: display, including: desktop), config)))
        }
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    (index, try await SCScreenshotManager.captureImage(contentFilter: job.filter, configuration: job.configuration))
                }
            }
            var images: [Int: CGImage] = [:]
            for try await (index, image) in group { images[index] = image }
            return images
        }
        let result = jobs.enumerated().compactMap { index, job -> FrozenScreen? in
            guard let image = images[index] else { return nil }
            let local = windows.compactMap { viewRect(ofGlobal: $0, screenFrame: job.screen.frame, mainHeight: mainHeight) }
            return FrozenScreen(screen: job.screen, image: image, scale: job.screen.backingScaleFactor, windows: local,
                                wallpaper: job.wallpaper)
        }
        Log.debug("Froze \(result.count) screen(s)", "screenshots")
        return result
    }

    /// Normal (layer 0) windows of other apps, front to back, in global top-left coordinates.
    private static func onScreenWindows() -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            return rect
        }
    }

    /// Global top-left rect (the main screen's top left is the origin) → the overlay view of the screen
    /// with `screenFrame` (AppKit global, bottom-left origin); nil when the window is not on it.
    static func viewRect(ofGlobal rect: CGRect, screenFrame: CGRect, mainHeight: CGFloat) -> CGRect? {
        let global = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        let local = global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            .intersection(CGRect(origin: .zero, size: screenFrame.size))
        return local.isNull || local.width < 1 || local.height < 1 ? nil : local
    }

    /// The pixels of a view rect (bottom-left origin) of this screen, copied out: a plain crop would
    /// keep the whole frozen screen alive for as long as the shot is (toast, clipboard, OCR).
    func crop(_ viewRect: CGRect) -> CGImage? {
        crop(viewRect, of: image).flatMap(Self.copied)
    }

    static func copied(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A view rect of `picture` (this screen or its wallpaper), sharing its memory.
    private func crop(_ viewRect: CGRect, of picture: CGImage) -> CGImage? {
        let rect = AreaSelection.displayRect(viewRect, viewHeight: screen.frame.height)
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return picture.cropping(to: pixels)
    }

    /// A window with its title bar on a strip of wallpaper, corners rounded like on screen. What was
    /// behind the window (other windows) does not show in the margin or the corners.
    /// Taken with the most wallpaper the margin can have (`WindowShot.maxMargin`); the shot itself is
    /// cut from it with the margin set.
    func windowShot(_ window: CGRect) async -> WindowShot? {
        let padded = window.insetBy(dx: -WindowShot.maxMargin, dy: -WindowShot.maxMargin)
            .intersection(CGRect(origin: .zero, size: screen.frame.size)).integral
        guard let frozen = crop(padded, of: image) else { return nil }
        // The window in the picture: pixels, top-left origin (the view's origin is at the bottom left).
        let windowPixels = CGRect(x: (window.minX - padded.minX) * scale, y: (padded.maxY - window.maxY) * scale,
                                  width: window.width * scale, height: window.height * scale)
        let shot = { (full: CGImage) in WindowShot(full: full, window: windowPixels, scale: scale) }
        var picture: CGImage?
        if let wallpaper {
            do {
                picture = try await SCScreenshotManager.captureImage(contentFilter: wallpaper.filter, configuration: wallpaper.configuration)
            } catch {
                Log.warning("Wallpaper not captured, window shot without it: \(Log.describe(error))", "screenshots")
            }
        }
        guard let picture, let wall = crop(padded, of: picture),
              let context = CGContext(data: nil, width: frozen.width, height: frozen.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Self.copied(frozen).map(shot) }
        let canvas = CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)
        context.draw(wall, in: canvas)
        // Both the view and a CGContext have the origin at the bottom left.
        let inside = CGRect(x: (window.minX - padded.minX) * scale, y: (window.minY - padded.minY) * scale,
                            width: window.width * scale, height: window.height * scale)
        let radius = Self.windowCornerRadius * scale
        context.addPath(CGPath(roundedRect: inside, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(frozen, in: canvas)
        return (context.makeImage() ?? Self.copied(frozen)).map(shot)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// The selected pixels.
struct AreaSelection {
    let image: CGImage
    /// Pixels per point of that display.
    let scale: CGFloat
    /// "area", "window", "screen", for the log.
    let kind: String
    /// A clicked window with spare wallpaper, so the editor can change the margin.
    var windowShot: WindowShot?

    /// A rect in a full-screen view (bottom-left origin) → display-local, top-left origin.
    static func displayRect(_ viewRect: CGRect, viewHeight: CGFloat) -> CGRect {
        let r = viewRect.standardized
        return CGRect(x: r.minX, y: viewHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// The crosshair over frozen screens. Dragging dims everything outside the selection and shows its
/// size in pixels; a click on a window's title bar takes that window (highlighted while hovering),
/// a click on the desktop the whole screen. Esc or right click cancels.
@MainActor
final class AreaSelector {
    /// What the selection is for: the hint at the top of the screen.
    enum Purpose { case screenshot, text }

    private var windows: [OverlayWindow] = []
    private let screens: [FrozenScreen]
    private let purpose: Purpose
    private let completion: (AreaSelection?) -> Void
    private var finished = false
    /// Mouse moves seen by the app as a whole: the guides follow the real pointer even if an overlay
    /// stops getting its own events (once they stayed behind while the crosshair moved on).
    private var moveMonitors: [Any] = []
    private var monitoredMoves = 0
    /// Esc as a system-wide key while selecting: activation is only a request macOS may turn down,
    /// and then the overlays never get the key (it seemed impossible to cancel).
    private var escapeKey: HotKey?

    /// How far down from a window's top edge a click takes the whole window. Only the title bar: most
    /// shots are a part of a window, and a window lit up under every press got in the way.
    static let titleBarHeight: CGFloat = 32

    /// The window a click at `point` takes (view coordinates, y up; `windows` front to back): the
    /// frontmost one under the point, only when the point is in its title bar.
    static func window(at point: CGPoint, in windows: [CGRect]) -> CGRect? {
        guard let window = windows.first(where: { $0.contains(point) }),
              point.y >= window.maxY - min(titleBarHeight, window.height) else { return nil }
        return window
    }

    init(screens: [FrozenScreen], purpose: Purpose, completion: @escaping (AreaSelection?) -> Void) {
        self.screens = screens
        self.purpose = purpose
        self.completion = completion
    }

    func begin() {
        for frozen in screens {
            let window = OverlayWindow(screen: frozen.screen)
            let bounds = NSRect(origin: .zero, size: frozen.screen.frame.size)
            // The frozen picture is a layer the GPU composites; the view above draws only the marks,
            // so moving the mouse does not redraw a 5K image each time.
            let picture = NSView(frame: bounds)
            picture.wantsLayer = true
            picture.layer?.contents = frozen.image
            picture.layer?.contentsGravity = .resize
            let view = OverlayView(frame: bounds)
            view.wantsLayer = true
            view.scale = frozen.scale
            view.windowRects = frozen.windows
            view.hint = purpose == .text ? String(localized: "Выделите текст — он скопируется · клик по окну — весь его текст · Esc — отмена") : nil
            view.onActivity = { [weak self, weak view] in self?.windows.forEach { if $0.overlay !== view { $0.overlay.reset() } } }
            view.onSelect = { [weak self] rect, kind in self?.select(rect, kind: kind, on: frozen) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            picture.addSubview(view)
            window.contentView = picture
            window.overlay = view
            windows.append(window)
        }
        // Keyboard focus for Esc, and the crosshair cursor, need MeetRec to be the active app. The
        // other app losing focus no longer matters: its picture is already frozen.
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKey()
        for window in windows { window.makeFirstResponder(window.overlay) }
        escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.cancel() }
        key?.overlay.hover(at: key.map { NSPoint(x: mouse.x - $0.frame.minX, y: mouse.y - $0.frame.minY) })
        key?.overlay.updateCursor()
        Log.info("Screen selection started on \(windows.count) frozen screen(s), active: \(NSApp.isActive), Esc key: \(escapeKey?.isRegistered == true)", "screenshots")
        let follow: (NSEvent) -> Void = { [weak self] _ in self?.followPointer() }
        moveMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { follow($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow),
        ].compactMap { $0 }
    }

    /// Guides through the pointer on its screen, none on the others. Drags are the overlay's own.
    private func followPointer() {
        guard !finished else { return }
        monitoredMoves += 1
        let mouse = NSEvent.mouseLocation
        for window in windows {
            let frame = window.frame
            window.overlay.hover(at: frame.contains(mouse) ? NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY) : nil)
        }
    }

    private func select(_ viewRect: CGRect, kind: String, on frozen: FrozenScreen) {
        guard kind == "window" else {
            finish(frozen.crop(viewRect).map { AreaSelection(image: $0, scale: frozen.scale, kind: kind) })
            return
        }
        Task {
            let shot = await frozen.windowShot(viewRect)
            let margin = CGFloat(Screenshotter.shared.windowMargin)
            finish(shot.flatMap { shot in
                shot.image(margin: margin)
                    .map { AreaSelection(image: $0, scale: frozen.scale, kind: kind, windowShot: shot) }
            })
        }
    }

    /// As Esc does.
    func cancel() { finish(nil) }

    private func finish(_ selection: AreaSelection?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors = []
        escapeKey = nil
        // If the overlays got far fewer moves than the app, their own events stopped coming.
        Log.debug("Selection pointer moves: overlays \(windows.map(\.overlay.ownMoves)), app \(monitoredMoves)", "screenshots")
        NSCursor.arrow.set()
        // Released only after the event that ended the selection is handled.
        DispatchQueue.main.async { [self] in
            // AppKit keeps the last key window after it is gone; without its content it does not
            // keep the frozen screen picture too.
            for window in windows { window.contentView = nil }
            windows.removeAll()
            completion(selection)
        }
    }
}

private final class OverlayWindow: NSWindow {
    var overlay: OverlayView!

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    var scale: CGFloat = 2
    var windowRects: [CGRect] = []
    var hint: String? { didSet { refresh() } }
    var onActivity: (() -> Void)?
    var onSelect: ((CGRect, String) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    /// The window a click would take.
    private var hovered: CGRect?
    /// Where the pointer is on this screen; the guides go through it.
    private var pointer: NSPoint?
    /// Mouse moves this view got itself (logged at the end, to compare with the app's).
    private(set) var ownMoves = 0

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private var dragging: Bool {
        guard let rect = selection else { return false }
        return rect.width >= 3 || rect.height >= 3
    }

    // Vector layers instead of draw(_:): a view that draws itself gets a full-screen backing store
    // (46 MB at 16 bits per channel on an XDR screen) that Core Animation keeps around afterwards.
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let highlight = CAShapeLayer()
    /// Thin lines from the crosshair to the screen's edges, so it is plain what the frame will take:
    /// white with a dark line beside it, visible on any background.
    private let guides = CAShapeLayer()
    private let guidesShade = CAShapeLayer()
    private let sizeBadge = Badge()
    private let hintBadge = Badge()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        border.lineWidth = 1
        highlight.fillColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        highlight.strokeColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        highlight.lineWidth = 2
        guides.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        guidesShade.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
        for sublayer in [highlight, dim, border, guidesShade, guides, sizeBadge.layer, hintBadge.layer] {
            layer?.addSublayer(sublayer)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reset() {
        guard start != nil || hovered != nil || pointer != nil else { return }
        start = nil
        current = nil
        hovered = nil
        pointer = nil
        refresh()
    }

    func updateCursor() { cursor.set() }

    func hover(at point: NSPoint?) {
        // A drag moves the guides itself (with the corner, kept on this screen).
        guard start == nil else { return }
        pointer = point
        let window = point.flatMap { AreaSelector.window(at: $0, in: windowRects) }
        if window != hovered {
            hovered = window
            refresh()
        } else {
            updateGuides()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// A camera over a window's title bar (a click takes it), the crosshair elsewhere and while dragging.
    private var cursor: NSCursor { hovered != nil && start == nil ? Self.camera : .crosshair }

    static let camera: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .crosshair }
        let tinted = { (color: NSColor) in
            symbol.withSymbolConfiguration(configuration.applying(.init(paletteColors: [color]))) ?? symbol
        }
        let black = tinted(.black), white = tinted(.white)
        let size = NSSize(width: symbol.size.width + 4, height: symbol.size.height + 4)
        // White with a dark outline, visible on any background.
        let image = NSImage(size: size, flipped: false) { _ in
            let base = NSRect(x: 2, y: 2, width: symbol.size.width, height: symbol.size.height)
            for (dx, dy) in [(-1.2, 0.0), (1.2, 0), (0, -1.2), (0, 1.2), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                black.draw(in: base.offsetBy(dx: dx, dy: dy))
            }
            white.draw(in: base)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseMoved(with event: NSEvent) {
        ownMoves += 1
        onActivity?()
        hover(at: convert(event.locationInWindow, from: nil))
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        onActivity?()
        start = clamped(convert(event.locationInWindow, from: nil))
        current = start
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        current = clamped(convert(event.locationInWindow, from: nil))
        pointer = current
        // A drag means an area, not the window under it.
        if dragging { NSCursor.crosshair.set() }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        current = clamped(convert(event.locationInWindow, from: nil))
        if dragging, let rect = selection, rect.width >= 3, rect.height >= 3 {
            onSelect?(rect.integral, "area")
        } else if !dragging {
            // A click: the window by its title bar, or the whole screen on the desktop. A click inside
            // a window does nothing, so a missed drag does not take the window.
            let point = current ?? .zero
            if let window = AreaSelector.window(at: point, in: windowRects) {
                onSelect?(window.integral, "window")
            } else if !windowRects.contains(where: { $0.contains(point) }) {
                onSelect?(bounds, "screen")
            } else {
                start = nil
                current = nil
                refresh()
            }
        } else {
            start = nil
            current = nil
            refresh()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// Puts the layers where the selection, the hovered window and the hints are.
    private func refresh() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [dim, border, highlight, guides, guidesShade] { sublayer.frame = layer.bounds }
        let scale = window?.backingScaleFactor ?? self.scale
        if dragging, let rect = selection {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(rect)
            dim.path = path
            border.path = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            highlight.path = nil
            let text = "\(Int((rect.width * self.scale).rounded())) × \(Int((rect.height * self.scale).rounded()))"
            let box = sizeBadge.set(text, padding: CGSize(width: 6, height: 3), scale: scale)
            // Under the selection; above it near the bottom of the screen.
            var origin = CGPoint(x: rect.midX - box.width / 2, y: rect.minY - box.height - 6)
            if origin.y < bounds.minY + 4 { origin.y = rect.maxY + 6 }
            if origin.y + box.height > bounds.maxY - 4 { origin.y = rect.minY + 6 }
            origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - box.width - 4)
            sizeBadge.layer.frame = CGRect(origin: origin, size: box)
            sizeBadge.layer.isHidden = false
        } else {
            dim.path = nil
            border.path = nil
            sizeBadge.layer.isHidden = true
            // Like macOS's window picker: a light tint over the window a click would take.
            highlight.path = hovered.map { CGPath(rect: $0.insetBy(dx: 1, dy: 1), transform: nil) }
        }
        if let hint {
            let box = hintBadge.set(hint, padding: CGSize(width: 10, height: 5), scale: scale)
            hintBadge.layer.frame = CGRect(x: bounds.midX - box.width / 2, y: bounds.maxY - box.height - 40,
                                           width: box.width, height: box.height)
            hintBadge.layer.isHidden = false
        } else {
            hintBadge.layer.isHidden = true
        }
        updateGuides()
        CATransaction.commit()
    }

    /// Moves only the guides: called on every mouse move, so nothing else is redrawn then.
    private func updateGuides() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Not over a title bar: a click there takes the whole window, not what the lines show.
        if let pointer, hovered == nil || start != nil {
            let scale = window?.backingScaleFactor ?? self.scale
            // On the middle of a device pixel, one pixel wide: sharp, not a blurred 2-pixel line.
            let x = ((pointer.x * scale).rounded(.down) + 0.5) / scale
            let y = ((pointer.y * scale).rounded(.down) + 0.5) / scale
            let bounds = bounds
            let lines = { (offset: CGFloat) -> CGPath in
                let path = CGMutablePath()
                path.move(to: CGPoint(x: bounds.minX, y: y - offset))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y - offset))
                path.move(to: CGPoint(x: x + offset, y: bounds.minY))
                path.addLine(to: CGPoint(x: x + offset, y: bounds.maxY))
                return path
            }
            guides.lineWidth = 1 / scale
            guidesShade.lineWidth = 1 / scale
            guides.path = lines(0)
            guidesShade.path = lines(1 / scale)
        } else {
            guides.path = nil
            guidesShade.path = nil
        }
        CATransaction.commit()
    }
}

/// White text on a dark rounded plate.
private final class Badge {
    let layer = CALayer()
    private let text = CATextLayer()

    init() {
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer.cornerRadius = 5
        layer.addSublayer(text)
        layer.isHidden = true
    }

    /// Returns the plate's size.
    func set(_ string: String, padding: CGSize, scale: CGFloat) -> CGSize {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        text.string = attributed
        text.contentsScale = scale
        text.frame = CGRect(x: padding.width, y: padding.height, width: ceil(size.width), height: ceil(size.height))
        return CGSize(width: ceil(size.width) + 2 * padding.width, height: ceil(size.height) + 2 * padding.height)
    }
}
