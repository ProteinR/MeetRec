import AppKit

/// The menu bar icon's picture, chosen in settings → "Основные" (`menuBarIcon`): the record dot,
/// a camera on a tripod, or the app icon's monitor. Someone who does not know the dot may forget
/// what it is; a camera or the app's own picture says what the app does at a glance.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case dot, camera, monitor

    static let defaultsKey = "menuBarIcon"
    var id: String { rawValue }

    static var current: MenuBarIcon {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MenuBarIcon.init(rawValue:)) ?? .dot
    }

    var title: String {
        switch self {
        case .dot: String(localized: "Точка")
        case .camera: String(localized: "Камера")
        case .monitor: String(localized: "Монитор")
        }
    }

    /// What the icon shows besides the picture itself.
    enum Mark: Equatable {
        case none, record, pause, problem

        var tint: NSColor {
            switch self {
            case .none: .labelColor
            case .record: .systemRed
            case .pause: .systemOrange
            case .problem: .systemYellow
            }
        }
    }

    /// The image for the status item. `colored`: the mark in its colour (red, orange, yellow);
    /// otherwise a template image, drawn by macOS in the menu bar's colour like any monochrome
    /// menu bar icon (idle, and the discreet style while recording).
    func image(mark: Mark, colored: Bool) -> NSImage {
        if self == .dot { return dotImage(mark: mark, colored: colored) }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // The outline's strokes overlap (body and lens hood, the tripod's legs): drawn opaque
            // in one layer and faded as a whole, else the joins of the semi-transparent text colour
            // show darker.
            let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
            let ink = colored ? label.withAlphaComponent(1) : NSColor.black
            let context = NSGraphicsContext.current?.cgContext
            context?.setAlpha(colored ? label.alphaComponent : 1)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            self.drawOutline(ink: ink)
            context?.endTransparencyLayer()
            context?.setAlpha(1)
            self.drawMark(mark, ink: ink, color: colored ? mark.tint : NSColor.black)
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = "MeetRec"
        return image
    }

    /// The record dot as before: SF Symbols, pause and problem as their own symbols.
    private func dotImage(mark: Mark, colored: Bool) -> NSImage {
        let symbol = switch mark {
        case .none: "record.circle"
        case .record: "record.circle.fill"
        case .pause: colored ? "pause.circle.fill" : "pause.circle"
        case .problem: colored ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetRec") ?? NSImage()
        guard colored else {
            image.isTemplate = true
            return image
        }
        image.isTemplate = false
        return image.withSymbolConfiguration(.init(paletteColors: [mark.tint])) ?? image
    }

    // MARK: Drawings (18 × 18 pt, y down)

    private func drawOutline(ink: NSColor) {
        ink.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        switch self {
        case .dot:
            break
        case .camera:
            path.appendRoundedRect(Self.cameraBody, xRadius: 1.8, yRadius: 1.8)
            // Lens hood: a trapezoid opening to the right.
            path.move(to: NSPoint(x: 12.25, y: 5.25))
            path.line(to: NSPoint(x: 16.25, y: 3.25))
            path.line(to: NSPoint(x: 16.25, y: 9.75))
            path.line(to: NSPoint(x: 12.25, y: 7.75))
            // Tripod: the head, then three legs.
            path.move(to: NSPoint(x: 7, y: 10.25)); path.line(to: NSPoint(x: 7, y: 17))
            path.move(to: NSPoint(x: 7, y: 12)); path.line(to: NSPoint(x: 3, y: 17))
            path.move(to: NSPoint(x: 7, y: 12)); path.line(to: NSPoint(x: 11, y: 17))
        case .monitor:
            path.appendRoundedRect(Self.monitorScreen, xRadius: 1.8, yRadius: 1.8)
            path.move(to: NSPoint(x: 9, y: 12.75)); path.line(to: NSPoint(x: 9, y: 15.5))
            path.move(to: NSPoint(x: 5.5, y: 15.75)); path.line(to: NSPoint(x: 12.5, y: 15.75))
        }
        path.stroke()
    }

    private static let cameraBody = NSRect(x: 1.75, y: 2.75, width: 10.5, height: 7.5)
    private static let monitorScreen = NSRect(x: 1.25, y: 2.25, width: 15.5, height: 10.5)

    /// Where the mark sits: inside the camera's body, in the middle of the monitor's screen.
    private var markBox: NSRect {
        switch self {
        case .dot: NSRect(x: 4.5, y: 4.5, width: 9, height: 9)
        case .camera: NSRect(x: 4.25, y: 3.75, width: 5.5, height: 5.5)
        case .monitor: NSRect(x: 5.75, y: 4.25, width: 6.5, height: 6.5)
        }
    }

    private func drawMark(_ mark: Mark, ink: NSColor, color: NSColor) {
        let box = markBox
        switch mark {
        case .none:
            // The monitor keeps its small dot, as on the app icon; the camera stays empty.
            guard self == .monitor else { return }
            ink.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 1.25, dy: 1.25)).fill()
        case .record:
            color.setFill()
            NSBezierPath(ovalIn: box).fill()
        case .pause:
            color.setFill()
            let bar = box.width * 0.3
            for x in [box.minX + box.width * 0.12, box.maxX - box.width * 0.12 - bar] {
                NSBezierPath(roundedRect: NSRect(x: x, y: box.minY, width: bar, height: box.height), xRadius: 0.6, yRadius: 0.6).fill()
            }
        case .problem:
            color.setFill()
            let w = max(box.width * 0.26, 1.5)
            NSBezierPath(roundedRect: NSRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height * 0.62), xRadius: w / 2, yRadius: w / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: box.midX - w / 2, y: box.maxY - w, width: w, height: w)).fill()
        }
    }
}
