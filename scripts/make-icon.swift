// Draws the MeetRec app icon (a monitor with a red record dot) and writes AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift MeetRec/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background: macOS-style rounded square with a dark graphite gradient, inset like system icons.
    let inset = 100 * s
    let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.29, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1))!
        .draw(in: bg, angle: -90)

    // Monitor: screen with a light frame, plus a stand.
    let screen = NSRect(x: 230 * s, y: 380 * s, width: 564 * s, height: 360 * s)
    let frame = NSBezierPath(roundedRect: screen, xRadius: 38 * s, yRadius: 38 * s)
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    frame.fill()
    let glass = NSBezierPath(roundedRect: screen.insetBy(dx: 26 * s, dy: 26 * s), xRadius: 20 * s, yRadius: 20 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1))!
        .draw(in: glass, angle: -90)
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 472 * s, y: 300 * s, width: 80 * s, height: 82 * s)).fill()
    NSBezierPath(roundedRect: NSRect(x: 372 * s, y: 270 * s, width: 280 * s, height: 44 * s),
                 xRadius: 22 * s, yRadius: 22 * s).fill()

    // Record dot with a soft glow, centred on the screen.
    let center = NSPoint(x: screen.midX, y: screen.midY)
    let glowRadius: CGFloat = 125 * s
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.25, blue: 0.22, alpha: 0.55),
                        NSColor(calibratedRed: 1, green: 0.25, blue: 0.22, alpha: 0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - glowRadius, y: center.y - glowRadius,
                                               width: 2 * glowRadius, height: 2 * glowRadius)),
              relativeCenterPosition: .zero)
    let dotRadius: CGFloat = 82 * s
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                          width: 2 * dotRadius, height: 2 * dotRadius))
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.38, blue: 0.33, alpha: 1),
               ending: NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.12, alpha: 1))!
        .draw(in: dot, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try data.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
