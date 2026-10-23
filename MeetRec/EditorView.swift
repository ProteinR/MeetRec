import AppKit
import SwiftUI

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
        /// The crop frame: a new one, moved by its inside, or one of its edges/corners dragged.
        case cropNew
        case cropMove(CGRect, from: CGPoint)
        case cropResize(CGRect, CropEdges)
    }

    /// Which sides of the crop frame a drag moves (two for a corner).
    private struct CropEdges: Equatable {
        var left = false, right = false, top = false, bottom = false
        var isEmpty: Bool { !(left || right || top || bottom) }
    }

    @State private var dragMode: DragMode?
    @State private var dragRecorded = false
    @State private var draft: Annotation?
    /// Text-recognition area being dragged, image pixels.
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
        .onChange(of: document.tool) { old, _ in
            commitCaption()
            // Leaving the crop tool keeps what the frame shows, as Copy and closing do.
            if old == .crop { document.applyPendingCrop() }
        }
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
            Divider().frame(height: 20).padding(.horizontal, 6)
            // What is searched is what would be copied: marks, blur and crop included.
            ImageSearchButtons(iconSize: 16) { provider in
                commitCaption()
                document.applyPendingCrop()
                guard let result = document.render() else { return }
                ImageSearch.search(result, scale: document.scale, name: document.url.lastPathComponent, with: provider)
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 8)
            if document.tool == .blur || document.selected?.kind == .blur {
                blurSlider
            }
            if document.tool == .ocr {
                Button("Весь текст") { document.recognize(region: nil) }
                    .disabled(document.recognizing)
            }
            if document.tool == .crop {
                if document.pendingCrop != nil {
                    Button("Отмена") { document.pendingCrop = nil }
                        .help("Убрать рамку (Esc)")
                    Button {
                        document.applyPendingCrop()
                    } label: {
                        Label("Обрезать", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Оставить только то, что в рамке (Enter)")
                } else if document.crop != nil {
                    Button("Вернуть всё") { document.resetCrop() }
                        .help("Снять обрезку: снова вся картинка")
                }
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
            if document.windowShot != nil { marginControl }
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

    /// Wallpaper around a window shot: a slider, or the number typed in.
    private var marginControl: some View {
        HStack(spacing: 6) {
            Divider().frame(height: 14)
            Text("Обои вокруг окна")
            Slider(value: Binding(get: { Double(document.margin) },
                                  set: { document.setMargin(CGFloat($0), record: false) }),
                   in: 0...Double(WindowShot.maxMargin), step: 1) { editing in
                if editing { document.recordUndo() }
            }
            .frame(width: 120)
            TextField("", value: Binding(get: { Int(document.margin) },
                                         set: { document.setMargin(CGFloat($0), record: true) }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 40)
            Text("px")
        }
        .controlSize(.mini)
        .help("Сколько обоев видно вокруг окна, 0–\(Int(WindowShot.maxMargin)); по умолчанию — из настроек «Скриншоты»")
    }

    private var sizeText: String {
        var text = "\(document.image.width) × \(document.image.height) px"
        if document.scale > 1 { text += " · \(Int(document.scale))×" }
        // The frame being adjusted, else the applied crop.
        if let crop = document.pendingCrop ?? document.crop {
            text += " → \(Int(crop.width.rounded())) × \(Int(crop.height.rounded()))"
        }
        return text
    }

    // MARK: - Canvas

    private func canvas(in available: CGSize) -> some View {
        let size = document.visibleRect.size
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
                    .offset(x: (captionAt.x - document.visibleRect.minX) * zoom,
                            y: (captionAt.y - document.visibleRect.minY) * zoom)
                    .focused($captionFocused)
                    .onSubmit(commitCaption)
                    .onExitCommand(perform: cancelCaption)
            }
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draw(_ marks: [Annotation], in canvas: GraphicsContext, zoom: CGFloat) {
        // Only the applied crop is shown: the image is drawn shifted by its origin and clipped.
        let visible = document.visibleRect
        var context = canvas
        context.clip(to: Path(CGRect(x: 0, y: 0, width: visible.width * zoom, height: visible.height * zoom)))
        context.translateBy(x: -visible.minX * zoom, y: -visible.minY * zoom)
        let size = document.imageSize
        context.draw(Image(decorative: document.image, scale: 1), in: CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom))
        for annotation in marks {
            AnnotationDrawing.draw(annotation, in: context, zoom: zoom, scale: document.scale, source: document.image)
        }
        if let selected = document.selected {
            AnnotationDrawing.drawSelection(selected, in: context, zoom: zoom, scale: document.scale)
        }
        let scaled = { (rect: CGRect) in
            CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        }
        // The crop frame: what it leaves out is dimmed, thirds and handles as in Photoshop.
        if let pending = document.pendingCrop {
            let frame = scaled(pending)
            var outside = Path(scaled(visible))
            outside.addRect(frame)
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            var thirds = Path()
            for i in 1...2 {
                let x = frame.minX + frame.width * CGFloat(i) / 3, y = frame.minY + frame.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: frame.minY))
                thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: y))
                thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            context.stroke(Path(frame), with: .color(.white), lineWidth: 1)
            for x in [frame.minX, frame.midX, frame.maxX] {
                for y in [frame.minY, frame.midY, frame.maxY] where !(x == frame.midX && y == frame.midY) {
                    let handle = Path(CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    context.fill(handle, with: .color(.white))
                    context.stroke(handle, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
                }
            }
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
        if document.tool == .crop, let pending = document.pendingCrop {
            let edges = cropEdges(at: p, of: pending, zoom: zoom)
            if !edges.isEmpty { return Self.resizeCursor(edges) }
            if pending.contains(p) { return .openHand }
            return .crosshair
        }
        guard !document.tool.selectsArea, let (_, handle) = target(at: p, zoom: zoom) else { return .crosshair }
        return handle != nil ? .pointingHand : .openHand
    }

    private func beginDrag(at p: CGPoint, zoom: CGFloat) -> DragMode {
        if document.tool == .crop {
            if let pending = document.pendingCrop {
                let edges = cropEdges(at: p, of: pending, zoom: zoom)
                if !edges.isEmpty { return .cropResize(pending, edges) }
                if pending.contains(p) { return .cropMove(pending, from: p) }
            }
            return .cropNew
        }
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
                case .cropNew:
                    guard moved else { return }
                    document.pendingCrop = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                case .cropMove(let original, let from):
                    let visible = document.visibleRect
                    var moved = original.offsetBy(dx: end.x - from.x, dy: end.y - from.y)
                    moved.origin.x = min(max(moved.minX, visible.minX), visible.maxX - moved.width)
                    moved.origin.y = min(max(moved.minY, visible.minY), visible.maxY - moved.height)
                    document.pendingCrop = moved
                case .cropResize(let original, let edges):
                    var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
                    if edges.left { minX = end.x }
                    if edges.right { maxX = end.x }
                    if edges.top { minY = end.y }
                    if edges.bottom { maxY = end.y }
                    document.pendingCrop = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                                                  width: abs(maxX - minX), height: abs(maxY - minY))
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
                    if moved, let area { document.recognize(region: area) }
                case .cropNew:
                    // A click without a drag drops the frame, as in Photoshop.
                    if !moved { document.pendingCrop = nil }
                case .cropMove, .cropResize:
                    break
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

    /// View point → image pixels, kept inside the part shown.
    private func imagePoint(_ point: CGPoint, zoom: CGFloat) -> CGPoint {
        let visible = document.visibleRect
        return CGPoint(x: min(max(point.x / zoom + visible.minX, visible.minX), visible.maxX),
                       y: min(max(point.y / zoom + visible.minY, visible.minY), visible.maxY))
    }

    /// The sides of the crop frame within reach of `p` (image pixels).
    private func cropEdges(at p: CGPoint, of frame: CGRect, zoom: CGFloat) -> CropEdges {
        let reach = Self.reach / zoom
        guard p.x >= frame.minX - reach, p.x <= frame.maxX + reach,
              p.y >= frame.minY - reach, p.y <= frame.maxY + reach else { return CropEdges() }
        return CropEdges(left: abs(p.x - frame.minX) <= reach, right: abs(p.x - frame.maxX) <= reach,
                         top: abs(p.y - frame.minY) <= reach, bottom: abs(p.y - frame.maxY) <= reach)
    }

    private static func resizeCursor(_ edges: CropEdges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch (edges.left, edges.right, edges.top, edges.bottom) {
        case (true, _, true, _): position = .topLeft
        case (_, true, true, _): position = .topRight
        case (true, _, _, true): position = .bottomLeft
        case (_, true, _, true): position = .bottomRight
        case (true, _, _, _): position = .left
        case (_, true, _, _): position = .right
        case (_, _, true, _): position = .top
        default: position = .bottom
        }
        return .frameResize(position: position, directions: .all)
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
