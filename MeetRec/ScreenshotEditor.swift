import AppKit
import Carbon
import Combine
import SwiftUI

/// "Редактировать" on a screenshot: the picture under a small toolbar (arrow, rectangle, ellipse,
/// caption, numbered steps, blur, crop, text recognition, colours, undo, copy). Every mark stays an
/// object: click selects it, drag moves it, its handles reshape it (the arrow's middle point bends it),
/// Delete removes it. Marks are kept apart from the original pixels until saved, so undo works after a
/// save too; saving writes the result over the same file (also on closing with unsaved changes).
@MainActor
final class ScreenshotEditor: NSObject, NSWindowDelegate {
    private static var editors: [ScreenshotEditor] = []

    private let document: EditorDocument
    private let window: NSWindow
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?

    static func open(_ url: URL) {
        if let editor = editors.first(where: { $0.document.url == url }) {
            editor.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let loaded = ScreenshotFiles.load(url) else {
            RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Скриншот не открылся", detail: url.lastPathComponent))
            return
        }
        let editor = ScreenshotEditor(document: EditorDocument(url: url, image: loaded.image, scale: loaded.scale))
        editors.append(editor)
        editor.show()
    }

    private init(document: EditorDocument) {
        self.document = document
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = document.url.lastPathComponent
        window.representedURL = document.url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 840, height: 380)
        window.delegate = self
        let hosting = NSHostingView(rootView: EditorView(document: document) { [weak self] in self?.window.performClose(nil) })
        hosting.sizingOptions = []
        window.contentView = hosting
        document.$dirty
            .receive(on: RunLoop.main)
            .sink { [weak self] dirty in self?.window.isDocumentEdited = dirty }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Letters pick tools, 1–4 colours, Delete removes the selected mark, Esc deselects or closes,
    /// ⇧⌘Z redoes. Not while a caption is being typed: then the keys belong to the text field.
    private func handleKey(_ event: NSEvent) -> Bool {
        if window.firstResponder is NSTextView { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if flags == [.command, .shift], code == kVK_ANSI_Z {
            document.redo()
            return true
        }
        guard flags.isEmpty else { return false }
        switch code {
        case kVK_Escape:
            if document.selectedID != nil { document.selectedID = nil } else { window.performClose(nil) }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            document.deleteSelected()
            return true
        case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4:
            let index = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].firstIndex(of: code)!
            document.setColor(index)
            return true
        default:
            guard let tool = EditorTool.allCases.first(where: { $0.key.code == code }) else { return false }
            document.tool = tool
            return true
        }
    }

    /// At the screenshot's point size when it fits, else as large as the screen allows.
    private func show() {
        let image = CGSize(width: CGFloat(document.image.width) / document.scale,
                           height: CGFloat(document.image.height) / document.scale)
        let chrome = CGSize(width: 32, height: 32 + EditorView.toolbarHeight + EditorView.footerHeight)
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let width = min(max(image.width + chrome.width, window.minSize.width), visible.width * 0.85)
        let height = min(max(image.height + chrome.height, window.minSize.height), visible.height * 0.85)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Log.info("Screenshot editor opened: \(document.url.lastPathComponent) (\(document.image.width)×\(document.image.height) px)", "screenshots")
    }

    func windowWillClose(_ notification: Notification) {
        document.finishEditing?()
        // It holds the view's state, and the view holds the document: break the cycle, or every
        // closed editor keeps its picture in memory.
        document.finishEditing = nil
        // However the editor is left (Esc, ⌘W, the close button), the result is in the clipboard and
        // in the file. "Копировать" did it already.
        if !document.copiedOnClose { document.copyResult() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Self.editors.removeAll { $0 === self }
        // After this run loop pass the document and its picture are gone.
        DispatchQueue.main.async { ScreenshotFiles.releaseFreedMemory() }
        Log.info("Screenshot editor closed: \(document.url.lastPathComponent)", "screenshots")
    }
}

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

@MainActor
final class EditorDocument: ObservableObject {
    let url: URL
    let image: CGImage
    /// Image pixels per screen point: line widths and caption sizes look the same on any screenshot.
    let scale: CGFloat
    /// Same as `Annotation.blur`'s default. Squares this big leave about two per line of text: small
    /// ones can be turned back into readable text by depixelation tools.
    static let defaultBlur: CGFloat = 8
    static let blurRange: ClosedRange<CGFloat> = 6...16

    @Published private(set) var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    /// Image pixels; nil = whole image.
    @Published private(set) var crop: CGRect?
    @Published var tool: EditorTool = .arrow
    @Published private(set) var colorIndex = 0
    /// Square size for new blurs, screen points ("Пиксели" slider).
    @Published private(set) var blurSize = EditorDocument.defaultBlur
    /// The result of the last action ("Текст скопирован · 3 строки"), in the footer.
    @Published var status: String?
    @Published private(set) var dirty = false
    @Published private(set) var recognizing = false
    /// Set by the view: puts a caption still being typed into the picture (before closing).
    var finishEditing: (() -> Void)?
    private var history: [(annotations: [Annotation], crop: CGRect?)] = []
    private var future: [(annotations: [Annotation], crop: CGRect?)] = []

    var canUndo: Bool { !history.isEmpty }
    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }
    var nextStep: Int {
        annotations.reduce(0) { if case .step(let n) = $1.kind { return max($0, n) } else { return $0 } } + 1
    }

    init(url: URL, image: CGImage, scale: CGFloat) {
        self.url = url
        self.image = image
        self.scale = scale
    }

    /// The slider: sets the size for new blurs and changes the selected one. `record` once per drag.
    func setBlurSize(_ size: CGFloat, record: Bool) {
        blurSize = size
        guard var selected, selected.kind == .blur else { return }
        if record { recordUndo() }
        selected.blur = size
        replace(selected)
        dirty = true
    }

    /// Added and selected, so its handles are there to adjust it right away.
    func add(_ annotation: Annotation) {
        change { annotations.append(annotation) }
        selectedID = annotation.id
    }

    /// Before a drag starts changing a mark: one undo step for the whole drag.
    func recordUndo() {
        change {}
    }

    /// During a drag (after `recordUndo`).
    func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        change { annotations = AnnotationGeometry.renumbered(annotations.filter { $0.id != id }) }
        selectedID = nil
    }

    /// Also recolours the selected mark.
    func setColor(_ index: Int) {
        colorIndex = index
        if let selected, selected.color != index {
            var recoloured = selected
            recoloured.color = index
            change { replace(recoloured) }
        }
    }

    func setCrop(_ rect: CGRect) {
        let rect = rect.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 4, rect.height >= 4 else { return }
        change { crop = rect }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        future.append((annotations, crop))
        annotations = last.annotations
        crop = last.crop
        if selected == nil { selectedID = nil }
        dirty = true
        status = nil
    }

    /// ⌘⇧Z.
    func redo() {
        guard let next = future.popLast() else { return }
        history.append((annotations, crop))
        annotations = next.annotations
        crop = next.crop
        if selected == nil { selectedID = nil }
        dirty = true
        status = nil
    }

    private func change(_ body: () -> Void) {
        history.append((annotations, crop))
        future.removeAll()
        body()
        dirty = true
        status = nil
    }

    /// The image with all marks, cropped, at full resolution.
    func render() -> CGImage? {
        let size = imageSize
        let image = image, annotations = annotations, scale = scale
        let content = Canvas { context, _ in
            context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
            for annotation in annotations {
                AnnotationDrawing.draw(annotation, in: context, zoom: 1, scale: scale, source: image)
            }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let result = renderer.cgImage else {
            Log.error("Screenshot render failed: \(url.lastPathComponent)", "screenshots")
            return nil
        }
        if let crop, let cropped = result.cropping(to: crop) { return cropped }
        return result
    }

    @discardableResult
    func save() -> Bool {
        guard let result = render() else {
            status = "Не удалось сохранить"
            return false
        }
        do {
            try ScreenshotFiles.write(result, scale: scale, to: url)
            dirty = false
            status = "Сохранено"
            Log.info("Screenshot edited and saved: \(url.lastPathComponent) (\(annotations.count) marks\(crop != nil ? ", cropped" : ""))", "screenshots")
            Screenshotter.shared.edited(url)
            return true
        } catch {
            Log.error("Screenshot not saved: \(Log.describe(error))", "screenshots")
            status = "Не удалось сохранить"
            return false
        }
    }

    /// Copies the result and saves unsaved marks into the file; false when either failed (the
    /// editor then stays open with the reason in its footer).
    /// Set once "Копировать" copied and saved, so closing does not do it again.
    private(set) var copiedOnClose = false

    @discardableResult
    func copyResult() -> Bool {
        copiedOnClose = true
        guard let result = render() else { return false }
        ScreenshotFiles.copy(result, scale: scale)
        Log.info("Edited screenshot copied: \(url.lastPathComponent)", "screenshots")
        let hadChanges = dirty
        if dirty, !save() { return false }
        status = "Скопировано"
        RecorderModel.shared.showToast(Toast(kind: .screenshot, title: "Скриншот скопирован",
                                             detail: hadChanges ? "Пометки сохранены в «\(url.lastPathComponent)»" : nil))
        return true
    }

    /// Reads the original pixels (marks do not get in the way); `region` in image pixels.
    func recognize(region: CGRect?) {
        guard !recognizing else { return }
        recognizing = true
        status = "Распознаю текст…"
        let image = image
        Task {
            let text = await ScreenshotFiles.recognizeText(in: image, region: region)
            recognizing = false
            status = Screenshotter.copyRecognized(text, from: url.lastPathComponent)
        }
    }
}

/// Drawing shared by the editor view (zoomed to fit) and the saved result (`zoom` 1).
enum AnnotationDrawing {
    /// - Parameters:
    ///   - zoom: view points per image pixel.
    ///   - scale: image pixels per screen point.
    static func draw(_ annotation: Annotation, in context: GraphicsContext, zoom: CGFloat, scale: CGFloat,
                     source: CGImage) {
        let unit = scale * zoom
        let width = AnnotationGeometry.lineWidth(scale: scale) * zoom
        let outline = 1.2 * unit
        let color = EditorPalette.color(annotation.color)
        let halo = GraphicsContext.Shading.color(.white.opacity(0.85))
        let view = { (p: CGPoint) in CGPoint(x: p.x * zoom, y: p.y * zoom) }
        let rect = CGRect(x: annotation.rect.minX * zoom, y: annotation.rect.minY * zoom,
                          width: annotation.rect.width * zoom, height: annotation.rect.height * zoom)

        switch annotation.kind {
        case .arrow:
            let start = view(annotation.start), end = view(annotation.end)
            let control = view(AnnotationGeometry.control(annotation))
            let length = AnnotationGeometry.length(annotation) * zoom
            guard length > 1 else { return }
            // The head points along the curve's last bit.
            var tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
            if hypot(tangent.x, tangent.y) < 0.5 { tangent = CGPoint(x: end.x - start.x, y: end.y - start.y) }
            let tangentLength = max(hypot(tangent.x, tangent.y), 0.001)
            let direction = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let head = min(max(width * 4, 14 * unit), length * 0.7)
            let back = CGPoint(x: end.x - direction.x * head, y: end.y - direction.y * head)
            // The shaft stops inside the head, so its round cap does not poke out of the tip.
            let t = max(0, 1 - head * 0.7 / length)
            let shaftControl = CGPoint(x: start.x + (control.x - start.x) * t, y: start.y + (control.y - start.y) * t)
            let shaftEnd = view(AnnotationGeometry.point(annotation, at: t))
            var shaft = Path()
            shaft.move(to: start)
            shaft.addQuadCurve(to: shaftEnd, control: shaftControl)
            var tip = Path()
            tip.move(to: end)
            tip.addLine(to: CGPoint(x: back.x + normal.x * head * 0.5, y: back.y + normal.y * head * 0.5))
            tip.addLine(to: CGPoint(x: back.x - normal.x * head * 0.5, y: back.y - normal.y * head * 0.5))
            tip.closeSubpath()
            context.stroke(shaft, with: halo, style: StrokeStyle(lineWidth: width + 2 * outline, lineCap: .round))
            context.stroke(tip, with: halo, style: StrokeStyle(lineWidth: 2 * outline, lineJoin: .round))
            context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            context.fill(tip, with: .color(color))

        case .rectangle, .ellipse:
            guard rect.width > 0, rect.height > 0 else { return }
            let path = annotation.kind == .ellipse ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 2 * unit)
            context.stroke(path, with: halo, style: StrokeStyle(lineWidth: width + 2 * outline, lineJoin: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))

        case .blur:
            guard rect.width > 0, rect.height > 0,
                  let blocks = pixelated(annotation, source: source, scale: scale) else { return }
            var clipped = context
            clipped.clip(to: Path(rect))
            clipped.draw(Image(decorative: blocks.image, scale: 1).interpolation(.none),
                         in: CGRect(x: blocks.rect.minX * zoom, y: blocks.rect.minY * zoom,
                                    width: blocks.rect.width * zoom, height: blocks.rect.height * zoom))

        case .caption(let text):
            let size = AnnotationGeometry.captionSize(text, scale: scale)
            let padding = AnnotationGeometry.captionPadding(scale: scale)
            let plate = CGRect(x: annotation.start.x * zoom, y: annotation.start.y * zoom,
                               width: size.width * zoom, height: size.height * zoom)
            context.fill(Path(roundedRect: plate, cornerRadius: 5 * unit), with: .color(color))
            let resolved = context.resolve(Text(text)
                .font(.system(size: AnnotationGeometry.captionFont(scale: scale) * zoom, weight: .semibold))
                .foregroundColor(EditorPalette.textColor(annotation.color)))
            context.draw(resolved, at: CGPoint(x: plate.minX + padding.width * zoom, y: plate.minY + padding.height * zoom),
                         anchor: .topLeading)

        case .step(let number):
            let radius = AnnotationGeometry.stepRadius(scale: scale) * zoom
            let center = view(annotation.start)
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            context.fill(circle, with: .color(color))
            context.stroke(circle, with: halo, style: StrokeStyle(lineWidth: 2 * outline))
            let label = context.resolve(Text("\(number)")
                .font(.system(size: (number > 9 ? 13 : 15) * unit, weight: .bold).monospacedDigit())
                .foregroundColor(EditorPalette.textColor(annotation.color)))
            context.draw(label, at: center, anchor: .center)
        }
    }

    /// The blurred area as one pixel per square (averaged), drawn back stretched without smoothing.
    /// Only that area is read, so it costs little memory even on a 6K screenshot and while dragging.
    static func pixelated(_ annotation: Annotation, source: CGImage, scale: CGFloat) -> (image: CGImage, rect: CGRect)? {
        let region = annotation.rect.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !region.isNull, region.width >= 1, region.height >= 1, let crop = source.cropping(to: region) else { return nil }
        let block = CGFloat(AnnotationGeometry.blurBlock(annotation, scale: scale))
        let columns = max(1, Int((region.width / block).rounded(.up)))
        let rows = max(1, Int((region.height / block).rounded(.up)))
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let small = context.makeImage() else { return nil }
        return (small, region)
    }

    /// Selection: a dashed frame and round handles. Only in the editor, never saved.
    static func drawSelection(_ annotation: Annotation, in context: GraphicsContext, zoom: CGFloat, scale: CGFloat) {
        let accent = Color.accentColor
        let handles = AnnotationGeometry.handles(annotation)
        if handles.isEmpty || annotation.kind == .arrow {
            let bounds = AnnotationGeometry.bounds(annotation, scale: scale)
            let frame = CGRect(x: bounds.minX * zoom, y: bounds.minY * zoom, width: bounds.width * zoom, height: bounds.height * zoom)
                .insetBy(dx: -5, dy: -5)
            context.stroke(Path(roundedRect: frame, cornerRadius: 4), with: .color(accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for handle in handles {
            let p = AnnotationGeometry.point(of: handle, annotation)
            let size: CGFloat = handle == .bend ? 12 : 9
            let dot = Path(ellipseIn: CGRect(x: p.x * zoom - size / 2, y: p.y * zoom - size / 2, width: size, height: size))
            context.fill(dot, with: .color(handle == .bend ? accent : .white))
            context.stroke(dot, with: .color(handle == .bend ? .white : accent), lineWidth: 1.5)
        }
    }
}

struct EditorView: View {
    static let toolbarHeight: CGFloat = 44
    static let footerHeight: CGFloat = 26
    /// How close (view points) a click must be to a line or a handle to pick it.
    private static let reach: CGFloat = 7

    @ObservedObject var document: EditorDocument
    let close: () -> Void

    private enum DragMode {
        case draw, area, place
        case move(Annotation, from: CGPoint)
        case reshape(Annotation, AnnotationGeometry.Handle)
    }

    @State private var dragMode: DragMode?
    @State private var dragRecorded = false
    @State private var draft: Annotation?
    /// Crop or text-recognition area being dragged, image pixels.
    @State private var area: CGRect?
    @State private var captionAt: CGPoint?
    @State private var captionText = ""
    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: Self.toolbarHeight)
            Divider()
            GeometryReader { geometry in
                canvas(in: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .padding(16)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            footer
                .frame(height: Self.footerHeight)
        }
        .background {
            Button("", action: close).keyboardShortcut("w", modifiers: .command).hidden()
            // No button for it: copying and closing save too.
            Button("") {
                commitCaption()
                document.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .hidden()
        }
        .onChange(of: document.tool) { commitCaption() }
        .onAppear { document.finishEditing = { commitCaption() } }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    document.tool = tool
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tool.icon)
                        if let label = tool.label { Text(label) }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(document.tool == tool ? Color.accentColor.opacity(0.22) : Color.clear))
                    .foregroundStyle(document.tool == tool ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.help) (\(tool.key.letter))")
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            ForEach(EditorPalette.colors.indices, id: \.self) { index in
                Button {
                    document.setColor(index)
                } label: {
                    Circle()
                        .fill(EditorPalette.colors[index])
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(document.colorIndex == index ? 0.6 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(EditorPalette.names[index]) (\(index + 1))")
            }
            Spacer(minLength: 8)
            if document.tool == .blur || document.selected?.kind == .blur {
                blurSlider
            }
            if document.tool == .ocr {
                Button("Весь текст") { document.recognize(region: nil) }
                    .disabled(document.recognizing)
            }
            Button {
                cancelCaption()
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!document.canUndo)
            .help("Отменить (⌘Z), вернуть — ⇧⌘Z")
            Button {
                commitCaption()
                // Done: the result goes to the clipboard and over the file, the window goes away.
                if document.copyResult() { close() }
            } label: {
                Label("Копировать и сохранить", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(captionAt != nil)
            .help("Скопировать картинку с пометками в буфер, сохранить её в тот же файл и закрыть (⌘C). Закрытие окна тоже сохраняет")
        }
        .padding(.horizontal, 12)
    }

    /// Smaller squares still show that something was hidden, without the coarse look.
    private var blurSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { document.selected?.kind == .blur ? document.selected!.blur : document.blurSize },
                                  set: { document.setBlurSize($0.rounded(), record: false) }),
                   in: EditorDocument.blurRange, step: 1) { editing in
                if editing, document.selected?.kind == .blur { document.recordUndo() }
            }
            .frame(width: 90)
            Image(systemName: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
        }
        .help("Размер пикселей размытия")
    }

    private var footer: some View {
        HStack {
            Text(sizeText)
            Spacer(minLength: 8)
            Text(document.status ?? (document.selectedID != nil
                ? "Тяните — передвинуть, точки — изменить, Delete — удалить, Esc — снять выбор"
                : document.tool.hint))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    private var sizeText: String {
        var text = "\(document.image.width) × \(document.image.height) px"
        if document.scale > 1 { text += " · \(Int(document.scale))×" }
        if let crop = document.crop { text += " → \(Int(crop.width)) × \(Int(crop.height))" }
        return text
    }

    // MARK: - Canvas

    private func canvas(in available: CGSize) -> some View {
        let size = document.imageSize
        // Never larger than the screenshot's own point size.
        let zoom = min(available.width / size.width, available.height / size.height, 1 / document.scale)
        let shown = CGSize(width: size.width * zoom, height: size.height * zoom)
        let marks = document.annotations + (draft.map { [$0] } ?? [])
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                draw(marks, in: context, zoom: zoom)
            }
            .frame(width: shown.width, height: shown.height)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .gesture(dragGesture(zoom: zoom))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): cursor(at: imagePoint(location, zoom: zoom), zoom: zoom).set()
                case .ended: NSCursor.arrow.set()
                }
            }
            if let captionAt {
                TextField("Надпись", text: $captionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: AnnotationGeometry.captionFont(scale: document.scale) * zoom, weight: .semibold))
                    .foregroundStyle(EditorPalette.textColor(document.colorIndex))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(width: 240, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(EditorPalette.color(document.colorIndex)))
                    .offset(x: captionAt.x * zoom, y: captionAt.y * zoom)
                    .focused($captionFocused)
                    .onSubmit(commitCaption)
                    .onExitCommand(perform: cancelCaption)
            }
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draw(_ marks: [Annotation], in context: GraphicsContext, zoom: CGFloat) {
        let size = document.imageSize
        let shown = CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom)
        context.draw(Image(decorative: document.image, scale: 1), in: shown)
        for annotation in marks {
            AnnotationDrawing.draw(annotation, in: context, zoom: zoom, scale: document.scale, source: document.image)
        }
        if let selected = document.selected {
            AnnotationDrawing.drawSelection(selected, in: context, zoom: zoom, scale: document.scale)
        }
        let scaled = { (rect: CGRect) in
            CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        }
        // What the crop leaves out is dimmed; it is cut only in the saved or copied result.
        let cropShown = document.tool == .crop && area != nil ? area : document.crop
        if let crop = cropShown {
            var outside = Path(shown)
            outside.addRect(scaled(crop))
            context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            context.stroke(Path(scaled(crop)), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        if document.tool == .ocr, let area {
            let rect = Path(scaled(area))
            context.fill(rect, with: .color(.blue.opacity(0.12)))
            context.stroke(rect, with: .color(.blue), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    // MARK: - Mouse

    /// A handle of the selected mark, else the topmost mark under the point.
    private func target(at p: CGPoint, zoom: CGFloat) -> (Annotation, AnnotationGeometry.Handle?)? {
        let tolerance = Self.reach / zoom
        if let selected = document.selected,
           let handle = AnnotationGeometry.handles(selected).first(where: { handle in
               let h = AnnotationGeometry.point(of: handle, selected)
               return hypot(h.x - p.x, h.y - p.y) <= tolerance
           }) {
            return (selected, handle)
        }
        if let hit = document.annotations.reversed().first(where: {
            AnnotationGeometry.hits($0, p, tolerance: tolerance, scale: document.scale)
        }) {
            return (hit, nil)
        }
        return nil
    }

    private func cursor(at p: CGPoint, zoom: CGFloat) -> NSCursor {
        guard !document.tool.selectsArea, let (_, handle) = target(at: p, zoom: zoom) else { return .crosshair }
        return handle != nil ? .pointingHand : .openHand
    }

    private func beginDrag(at p: CGPoint, zoom: CGFloat) -> DragMode {
        if document.tool.selectsArea { return .area }
        if let (annotation, handle) = target(at: p, zoom: zoom) {
            commitCaption()
            document.selectedID = annotation.id
            if let handle { return .reshape(annotation, handle) }
            return .move(annotation, from: p)
        }
        document.selectedID = nil
        return document.tool == .caption || document.tool == .step ? .place : .draw
    }

    private func dragGesture(zoom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = imagePoint(value.startLocation, zoom: zoom)
                let end = imagePoint(value.location, zoom: zoom)
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) >= 2
                if dragMode == nil { dragMode = beginDrag(at: start, zoom: zoom) }
                switch dragMode {
                case .draw:
                    guard let kind = newKind else { return }
                    draft = Annotation(kind: kind, start: start, end: end, color: document.colorIndex, blur: document.blurSize)
                case .area:
                    area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                case .move(let original, let from):
                    guard moved else { return }
                    recordOnce()
                    document.replace(AnnotationGeometry.translated(original, by: CGSize(width: end.x - from.x, height: end.y - from.y)))
                case .reshape(let original, let handle):
                    guard moved else { return }
                    recordOnce()
                    document.replace(AnnotationGeometry.reshaped(original, handle, to: end, tolerance: Self.reach / zoom))
                case .place, nil:
                    break
                }
            }
            .onEnded { value in
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) >= 3
                let start = imagePoint(value.startLocation, zoom: zoom)
                switch dragMode {
                case .draw:
                    if moved, let draft { document.add(draft) }
                case .area:
                    if moved, let area {
                        if document.tool == .crop { document.setCrop(area) } else { document.recognize(region: area) }
                    }
                case .place:
                    if document.tool == .step {
                        document.add(Annotation(kind: .step(document.nextStep), start: start, end: start, color: document.colorIndex))
                    } else {
                        commitCaption()
                        captionAt = start
                        captionText = ""
                        DispatchQueue.main.async { captionFocused = true }
                    }
                case .move, .reshape, nil:
                    break
                }
                dragMode = nil
                dragRecorded = false
                draft = nil
                area = nil
            }
    }

    /// The mark a drag on empty space draws with the current tool.
    private var newKind: Annotation.Kind? {
        switch document.tool {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .blur: return .blur
        default: return nil
        }
    }

    private func recordOnce() {
        guard !dragRecorded else { return }
        dragRecorded = true
        document.recordUndo()
    }

    private func imagePoint(_ point: CGPoint, zoom: CGFloat) -> CGPoint {
        let size = document.imageSize
        return CGPoint(x: min(max(point.x / zoom, 0), size.width), y: min(max(point.y / zoom, 0), size.height))
    }

    private func commitCaption() {
        guard let at = captionAt else { return }
        let text = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        captionAt = nil
        captionText = ""
        guard !text.isEmpty else { return }
        document.add(Annotation(kind: .caption(text), start: at, end: at, color: document.colorIndex))
    }

    private func cancelCaption() {
        captionAt = nil
        captionText = ""
    }
}
