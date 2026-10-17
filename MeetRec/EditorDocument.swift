import AppKit
import SwiftUI

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
