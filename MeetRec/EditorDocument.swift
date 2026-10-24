import AppKit
import SwiftUI

@MainActor
final class EditorDocument: ObservableObject {
    let url: URL
    /// The picture being edited; for a window shot it changes with the margin.
    @Published private(set) var image: CGImage
    /// A window shot with spare wallpaper: the margin can be changed ("Обои вокруг окна").
    let windowShot: WindowShot?
    /// Points of wallpaper around the window now (window shots only).
    @Published private(set) var margin: CGFloat
    /// Image pixels per screen point: line widths and caption sizes look the same on any screenshot.
    let scale: CGFloat
    /// Same as `Annotation.blur`'s default. Squares this big leave about two per line of text: small
    /// ones can be turned back into readable text by depixelation tools.
    static let defaultBlur: CGFloat = 8
    static let blurRange: ClosedRange<CGFloat> = 6...16

    @Published private(set) var annotations: [Annotation] = []
    @Published var selectedID: UUID?
    /// Image pixels; nil = whole image. Applied: the editor shows only this part.
    @Published private(set) var crop: CGRect?
    /// The crop frame being adjusted (Enter applies it, Esc drops it), image pixels.
    @Published var pendingCrop: CGRect?
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
    private struct Snapshot {
        let annotations: [Annotation]
        let crop: CGRect?
        let margin: CGFloat
    }
    private var history: [Snapshot] = []
    private var future: [Snapshot] = []
    private var snapshot: Snapshot { Snapshot(annotations: annotations, crop: crop, margin: margin) }

    var canUndo: Bool { !history.isEmpty }
    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    /// The part of the image the editor shows: the applied crop, else all of it.
    var visibleRect: CGRect { crop ?? bounds }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }
    var nextStep: Int {
        annotations.reduce(0) { if case .step(let n) = $1.kind { return max($0, n) } else { return $0 } } + 1
    }

    init(url: URL, image: CGImage, scale: CGFloat, windowShot: (shot: WindowShot, margin: CGFloat)? = nil) {
        self.url = url
        self.image = image
        self.scale = scale
        // Only while the file is still the shot cut from it (not cropped or resized since).
        if let windowShot, windowShot.shot.rect(margin: windowShot.margin).size == CGSize(width: image.width, height: image.height) {
            self.windowShot = windowShot.shot
            margin = windowShot.margin
        } else {
            self.windowShot = nil
            margin = 0
        }
    }

    /// The margin slider: the picture is cut again from the window shot, and marks and the crop move
    /// with the window so they stay where they were drawn. `record` once per drag.
    func setMargin(_ value: CGFloat, record: Bool) {
        let value = min(max(value.rounded(), 0), WindowShot.maxMargin)
        guard windowShot != nil, value != margin else { return }
        if record { recordUndo() }
        applyMargin(value)
        dirty = true
        status = nil
    }

    private func applyMargin(_ value: CGFloat) {
        guard let windowShot, value != margin, let cut = windowShot.image(margin: value) else { return }
        let old = windowShot.rect(margin: margin).origin, new = windowShot.rect(margin: value).origin
        let shift = CGSize(width: old.x - new.x, height: old.y - new.y)
        annotations = annotations.map { AnnotationGeometry.translated($0, by: shift) }
        crop = crop?.offsetBy(dx: shift.width, dy: shift.height)
            .intersection(CGRect(x: 0, y: 0, width: cut.width, height: cut.height))
        pendingCrop = nil
        image = cut
        margin = value
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

    /// Cuts the picture to the crop frame (undoable); a frame too small to mean anything is dropped.
    func applyPendingCrop() {
        guard let pending = pendingCrop else { return }
        pendingCrop = nil
        let rect = pending.integral.intersection(visibleRect)
        guard !rect.isNull, rect.width >= 4, rect.height >= 4, rect != visibleRect else { return }
        change { crop = rect }
        Log.info("Screenshot cropped to \(Int(rect.width))×\(Int(rect.height)) px", "screenshots")
    }

    /// "Вернуть всё": the whole picture again (undoable).
    func resetCrop() {
        pendingCrop = nil
        guard crop != nil else { return }
        change { crop = nil }
    }

    func undo() {
        if pendingCrop != nil {
            pendingCrop = nil
            return
        }
        guard let last = history.popLast() else { return }
        future.append(snapshot)
        restore(last)
        if selected == nil { selectedID = nil }
        dirty = true
        status = nil
    }

    /// ⌘⇧Z.
    func redo() {
        guard let next = future.popLast() else { return }
        history.append(snapshot)
        restore(next)
        if selected == nil { selectedID = nil }
        dirty = true
        status = nil
    }

    /// The margin first: it moves marks, which the snapshot then sets as they were.
    private func restore(_ state: Snapshot) {
        applyMargin(state.margin)
        annotations = state.annotations
        crop = state.crop
    }

    private func change(_ body: () -> Void) {
        history.append(snapshot)
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
        // What the frame shows is what is kept, as when it is applied by hand.
        applyPendingCrop()
        guard let result = render() else {
            status = String(localized: "Не удалось сохранить")
            return false
        }
        do {
            try ScreenshotFiles.write(result, scale: scale, to: url)
            // The file shows this margin now. With marks or a crop it is no longer the plain shot: the
            // next editor would cut it again from the window shot and lose them, so no slider then.
            if windowShot != nil {
                if annotations.isEmpty, crop == nil {
                    WindowShotCache.setMargin(margin, for: url)
                } else {
                    WindowShotCache.remove(for: url)
                }
            }
            dirty = false
            status = String(localized: "Сохранено")
            Log.info("Screenshot edited and saved: \(url.lastPathComponent) (\(annotations.count) marks\(crop != nil ? ", cropped" : ""))", "screenshots")
            Screenshotter.shared.edited(url)
            return true
        } catch {
            Log.error("Screenshot not saved: \(Log.describe(error))", "screenshots")
            status = String(localized: "Не удалось сохранить")
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
        applyPendingCrop()
        guard let result = render() else { return false }
        ScreenshotFiles.copy(result, scale: scale)
        Log.info("Edited screenshot copied: \(url.lastPathComponent)", "screenshots")
        let hadChanges = dirty
        if dirty, !save() { return false }
        status = String(localized: "Скопировано")
        RecorderModel.shared.showToast(Toast(kind: .screenshot, title: String(localized: "Скриншот скопирован"),
                                             detail: hadChanges ? String(localized: "Пометки сохранены в «\(url.lastPathComponent)»") : nil))
        return true
    }

    /// Reads the original pixels (marks do not get in the way); `region` in image pixels.
    func recognize(region: CGRect?) {
        guard !recognizing else { return }
        recognizing = true
        status = String(localized: "Распознаю текст…")
        let image = image
        Task {
            let text = await ScreenshotFiles.recognizeText(in: image, region: region)
            recognizing = false
            status = Screenshotter.copyRecognized(text, from: url.lastPathComponent)
        }
    }
}
