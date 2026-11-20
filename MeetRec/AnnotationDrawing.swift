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
            // A light, friendly arrow: the shaft swells from a thin round tail towards a head with
            // swept-back barbs and soft corners (the old one was an even stroke with a sharp triangle).
            let start = view(annotation.start), end = view(annotation.end)
            let control = view(AnnotationGeometry.control(annotation))
            let length = AnnotationGeometry.length(annotation) * zoom
            guard length > 1 else { return }
            let at = { (t: CGFloat) -> CGPoint in
                let u = 1 - t
                let a = u * u, b = 2 * u * t, c = t * t
                let x: CGFloat = a * start.x + b * control.x + c * end.x
                let y: CGFloat = a * start.y + b * control.y + c * end.y
                return CGPoint(x: x, y: y)
            }
            let unitTangent = { (t: CGFloat) -> CGPoint in
                let u: CGFloat = 2 * (1 - t), v: CGFloat = 2 * t
                var dx: CGFloat = u * (control.x - start.x) + v * (end.x - control.x)
                var dy: CGFloat = u * (control.y - start.y) + v * (end.y - control.y)
                if hypot(dx, dy) < 0.001 { dx = end.x - start.x; dy = end.y - start.y }
                let l = max(hypot(dx, dy), 0.001)
                return CGPoint(x: dx / l, y: dy / l)
            }
            let direction = unitTangent(1)
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let head = min(max(width * 4.2, 16 * unit), length * 0.75)
            let local = { (along: CGFloat, across: CGFloat) -> CGPoint in
                let a: CGFloat = along * head, c: CGFloat = across * head
                let x: CGFloat = end.x - direction.x * a + normal.x * c
                let y: CGFloat = end.y - direction.y * a + normal.y * c
                return CGPoint(x: x, y: y)
            }
            // Head: sides bulge a little, the back is notched, corners rounded by a stroke of its colour.
            var tip = Path()
            tip.move(to: end)
            tip.addQuadCurve(to: local(1, 0.55), control: local(0.5, 0.36))
            tip.addQuadCurve(to: local(0.62, 0), control: local(0.78, 0.12))
            tip.addQuadCurve(to: local(1, -0.55), control: local(0.78, -0.12))
            tip.addQuadCurve(to: end, control: local(0.5, -0.36))
            tip.closeSubpath()
            let corner = max(width * 0.55, 1.5 * unit)
            // Shaft: tapered outline up to inside the head, with a round tail.
            let t = max(0, 1 - head * 0.5 / length)
            let thin = max(width * 0.4, 1.2 * unit), thick = width * 1.2
            let steps = 24
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...steps {
                let f = CGFloat(i) / CGFloat(steps), s = t * f
                let p = at(s), d = unitTangent(s)
                let ease: CGFloat = f * f * (3 - 2 * f)
                let w: CGFloat = (thin + (thick - thin) * ease) / 2
                let ox: CGFloat = -d.y * w, oy: CGFloat = d.x * w
                left.append(CGPoint(x: p.x + ox, y: p.y + oy))
                right.append(CGPoint(x: p.x - ox, y: p.y - oy))
            }
            var shaft = Path()
            shaft.addLines(left + right.reversed())
            shaft.closeSubpath()
            let tail = Path(ellipseIn: CGRect(x: start.x - thin / 2, y: start.y - thin / 2, width: thin, height: thin))
            for part in [shaft, tail] {
                context.stroke(part, with: halo, style: StrokeStyle(lineWidth: 2 * outline, lineJoin: .round))
            }
            context.stroke(tip, with: halo, style: StrokeStyle(lineWidth: corner + 2 * outline, lineJoin: .round))
            for part in [shaft, tail] { context.fill(part, with: .color(color)) }
            context.fill(tip, with: .color(color))
            context.stroke(tip, with: .color(color), style: StrokeStyle(lineWidth: corner, lineJoin: .round))

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

    /// Selection: round handles; marks without handles (caption, step) get a thin outline that
    /// follows their own shape. No dashed frame. Only in the editor, never saved.
    static func drawSelection(_ annotation: Annotation, in context: GraphicsContext, zoom: CGFloat, scale: CGFloat) {
        let accent = Color.accentColor
        let handles = AnnotationGeometry.handles(annotation)
        if handles.isEmpty {
            let bounds = AnnotationGeometry.bounds(annotation, scale: scale)
            let frame = CGRect(x: bounds.minX * zoom, y: bounds.minY * zoom, width: bounds.width * zoom, height: bounds.height * zoom)
                .insetBy(dx: -3, dy: -3)
            let outline: Path
            if case .step = annotation.kind {
                outline = Path(ellipseIn: frame)
            } else {
                outline = Path(roundedRect: frame, cornerRadius: 5 * scale * zoom + 3, style: .continuous)
            }
            context.stroke(outline, with: .color(.white.opacity(0.9)), lineWidth: 3)
            context.stroke(outline, with: .color(accent), lineWidth: 1.5)
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
