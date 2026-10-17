import SwiftUI

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
