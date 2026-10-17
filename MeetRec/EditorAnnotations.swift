import AppKit
import Carbon
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, caption, step, blur, crop, ocr
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .caption: return "textformat"
        case .step: return "1.circle"
        case .blur: return "checkerboard.rectangle"
        case .crop: return "crop"
        case .ocr: return "text.viewfinder"
        }
    }

    /// Shown next to the icon for the ones that are not obvious from it.
    var label: String? {
        switch self {
        case .step: return "Шаги"
        case .blur: return "Размыть"
        case .ocr: return "OCR"
        default: return nil
        }
    }

    var help: String {
        switch self {
        case .arrow: return "Стрелка"
        case .rectangle: return "Рамка"
        case .ellipse: return "Овал"
        case .caption: return "Надпись"
        case .step: return "Шаги: кружки с номерами 1, 2, 3… — куда кликать по порядку"
        case .blur: return "Размыть: скрыть пароль, почту, лишнее"
        case .crop: return "Обрезать"
        case .ocr: return "Скопировать текст с картинки (OCR)"
        }
    }

    var hint: String {
        switch self {
        case .arrow: return "Тяните от начала к острию; точка посередине изгибает"
        case .rectangle, .ellipse: return "Тяните, чтобы обвести"
        case .caption: return "Кликните, где поставить надпись; Enter — готово"
        case .step: return "Кликай по порядку: 1, 2, 3…"
        case .blur: return "Выделите, что скрыть"
        case .crop: return "Выделите, что оставить"
        case .ocr: return "Выделите область с текстом — он скопируется. Или «Весь текст»"
        }
    }

    /// Single-key shortcut (by key position, so it works in the Russian layout too).
    var key: (code: Int, letter: String) {
        switch self {
        case .arrow: return (kVK_ANSI_A, "A")
        case .rectangle: return (kVK_ANSI_R, "R")
        case .ellipse: return (kVK_ANSI_O, "O")
        case .caption: return (kVK_ANSI_T, "T")
        case .step: return (kVK_ANSI_N, "N")
        case .blur: return (kVK_ANSI_B, "B")
        case .crop: return (kVK_ANSI_C, "C")
        case .ocr: return (kVK_ANSI_X, "X")
        }
    }

    /// Crop and text recognition select an area of the picture; the rest make marks.
    var selectsArea: Bool { self == .crop || self == .ocr }
}

struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable { case arrow, rectangle, ellipse, blur, caption(String), step(Int) }

    var id = UUID()
    var kind: Kind
    /// Image pixels, top-left origin. Caption: its top left corner; step: the circle's centre.
    var start: CGPoint
    var end: CGPoint
    var color: Int
    /// Arrow only: the point the curve passes through halfway; nil = straight.
    var bend: CGPoint?
    /// Blur only: size of the squares, screen points.
    var blur: CGFloat = 8

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// Shapes of marks in image pixels: curves, hit testing, handles. `scale` is image pixels per screen
/// point (sizes are given in points, so marks look the same on any screenshot).
enum AnnotationGeometry {
    enum Handle: Equatable { case start, end, bend, corner(Int) }

    static func lineWidth(scale: CGFloat) -> CGFloat { 3 * scale }
    static func stepRadius(scale: CGFloat) -> CGFloat { 13 * scale }
    static func captionFont(scale: CGFloat) -> CGFloat { 16 * scale }
    static func captionPadding(scale: CGFloat) -> CGSize { CGSize(width: 7 * scale, height: 3 * scale) }

    /// Squares of a blur in image pixels.
    static func blurBlock(_ annotation: Annotation, scale: CGFloat) -> Int { max(2, Int((annotation.blur * scale).rounded())) }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    /// The quadratic curve's control point that makes it pass through `bend` at t = ½.
    static func control(_ arrow: Annotation) -> CGPoint {
        let mid = midpoint(arrow.start, arrow.end)
        guard let bend = arrow.bend else { return mid }
        return CGPoint(x: 2 * bend.x - mid.x, y: 2 * bend.y - mid.y)
    }

    static func point(_ arrow: Annotation, at t: CGFloat) -> CGPoint {
        let c = control(arrow), s = arrow.start, e = arrow.end
        let u = 1 - t
        return CGPoint(x: u * u * s.x + 2 * u * t * c.x + t * t * e.x,
                       y: u * u * s.y + 2 * u * t * c.y + t * t * e.y)
    }

    static func samples(_ arrow: Annotation, count: Int = 32) -> [CGPoint] {
        (0...count).map { point(arrow, at: CGFloat($0) / CGFloat(count)) }
    }

    static func length(_ arrow: Annotation) -> CGFloat {
        let points = samples(arrow)
        return zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(_ p: CGPoint, toArrow arrow: Annotation) -> CGFloat {
        let points = samples(arrow)
        return zip(points, points.dropFirst()).map { distance(p, toSegment: $0.0, $0.1) }.min() ?? .infinity
    }

    static func captionSize(_ text: String, scale: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: captionFont(scale: scale), weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let padding = captionPadding(scale: scale)
        return CGSize(width: ceil(size.width) + 2 * padding.width, height: ceil(size.height) + 2 * padding.height)
    }

    /// What the selection frame goes around.
    static func bounds(_ annotation: Annotation, scale: CGFloat) -> CGRect {
        switch annotation.kind {
        case .caption(let text):
            return CGRect(origin: annotation.start, size: captionSize(text, scale: scale))
        case .step:
            let r = stepRadius(scale: scale)
            return CGRect(x: annotation.start.x - r, y: annotation.start.y - r, width: 2 * r, height: 2 * r)
        case .arrow:
            let points = samples(annotation, count: 16)
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        default:
            return annotation.rect
        }
    }

    /// Lines are picked by their stroke (so one can still draw inside a frame); filled things anywhere.
    static func hits(_ annotation: Annotation, _ p: CGPoint, tolerance: CGFloat, scale: CGFloat) -> Bool {
        let reach = tolerance + lineWidth(scale: scale) / 2
        switch annotation.kind {
        case .arrow:
            return distance(p, toArrow: annotation) <= reach
        case .rectangle:
            let r = annotation.rect
            guard r.insetBy(dx: -reach, dy: -reach).contains(p) else { return false }
            return r.width < 2 * reach || r.height < 2 * reach || !r.insetBy(dx: reach, dy: reach).contains(p)
        case .ellipse:
            let r = annotation.rect
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let dx = (p.x - r.midX) / rx, dy = (p.y - r.midY) / ry
            return abs(sqrt(dx * dx + dy * dy) - 1) * min(rx, ry) <= reach
        case .blur, .caption, .step:
            return bounds(annotation, scale: scale).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func handles(_ annotation: Annotation) -> [Handle] {
        switch annotation.kind {
        case .arrow: return [.start, .end, .bend]
        case .rectangle, .ellipse, .blur: return (0..<4).map(Handle.corner)
        case .caption, .step: return []
        }
    }

    /// Corners go clockwise from the top left.
    static func point(of handle: Handle, _ annotation: Annotation) -> CGPoint {
        let r = annotation.rect
        switch handle {
        case .start: return annotation.start
        case .end: return annotation.end
        case .bend: return annotation.bend ?? midpoint(annotation.start, annotation.end)
        case .corner(let i): return corners(r)[i]
        }
    }

    private static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// `original` with `handle` dragged to `p`. A bend dragged back onto the straight line snaps
    /// straight; a corner moves against the opposite one.
    static func reshaped(_ original: Annotation, _ handle: Handle, to p: CGPoint, tolerance: CGFloat) -> Annotation {
        var result = original
        switch handle {
        case .start: result.start = p
        case .end: result.end = p
        case .bend:
            let straight = distance(p, toSegment: original.start, original.end) <= tolerance
            result.bend = straight ? nil : p
        case .corner(let i):
            result.start = corners(original.rect)[(i + 2) % 4]
            result.end = p
        }
        return result
    }

    static func translated(_ annotation: Annotation, by d: CGSize) -> Annotation {
        var result = annotation
        result.start = CGPoint(x: annotation.start.x + d.width, y: annotation.start.y + d.height)
        result.end = CGPoint(x: annotation.end.x + d.width, y: annotation.end.y + d.height)
        result.bend = annotation.bend.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return result
    }

    /// Steps keep counting 1, 2, 3… in the order they were placed, also after one is deleted.
    static func renumbered(_ annotations: [Annotation]) -> [Annotation] {
        var number = 0
        return annotations.map { annotation in
            guard case .step = annotation.kind else { return annotation }
            number += 1
            var result = annotation
            result.kind = .step(number)
            return result
        }
    }
}

enum EditorPalette {
    static let colors: [Color] = [
        Color(red: 0.92, green: 0.22, blue: 0.21),
        Color(red: 1.0, green: 0.76, blue: 0.0),
        Color(red: 0.16, green: 0.5, blue: 0.96),
        Color(red: 0.12, green: 0.12, blue: 0.12),
    ]
    static let names = ["Красный", "Жёлтый", "Синий", "Чёрный"]

    static func color(_ index: Int) -> Color { colors[min(max(index, 0), colors.count - 1)] }
    /// Text on a caption plate or a step circle: dark on yellow, white on the rest.
    static func textColor(_ index: Int) -> Color { index == 1 ? .black : .white }
}
