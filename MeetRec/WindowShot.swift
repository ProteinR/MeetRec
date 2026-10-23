import AppKit
import UniformTypeIdentifiers

/// A clicked window on its wallpaper, with more wallpaper around it than the saved shot shows, so the
/// margin can be changed afterwards in the editor ("Обои вокруг окна").
struct WindowShot {
    /// The window on up to `maxMargin` points of wallpaper (less where the screen ends).
    let full: CGImage
    /// The window in `full`, pixels, top-left origin.
    let window: CGRect
    /// Pixels per point.
    let scale: CGFloat

    /// Points; the setting and the editor's slider go up to this.
    static let maxMargin: CGFloat = 80
    /// Points, as Shottr had it.
    static let defaultMargin: CGFloat = 12

    /// The part of `full` for a margin in points.
    func rect(margin: CGFloat) -> CGRect {
        let pixels = (min(max(margin, 0), Self.maxMargin) * scale).rounded()
        return window.insetBy(dx: -pixels, dy: -pixels).integral
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
    }

    /// Outer corners rounded like a window's (transparent outside, so the shot is always PNG): as
    /// the window's own with no margin, larger with more wallpaper, up to `maxCornerRadius`.
    func image(margin: CGFloat) -> CGImage? {
        let rect = rect(margin: margin)
        guard let cut = full.cropping(to: rect),
              let context = CGContext(data: nil, width: cut.width, height: cut.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cut.width, height: cut.height)
        let radius = min((FrozenScreen.windowCornerRadius + max(margin, 0)) * scale, Self.maxCornerRadius * scale,
                         bounds.width / 2, bounds.height / 2)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(cut, in: bounds)
        return context.makeImage()
    }

    /// Points: concentric with the window's corners for small margins, no rounder than this.
    static let maxCornerRadius: CGFloat = 24
}

/// Window shots kept for the editor, next to nothing the user sees: `~/Library/Caches/MeetRec/WindowShots`,
/// by the screenshot's file name, the newest `keep` only.
enum WindowShotCache {
    private static let keep = 30
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetRec/WindowShots", isDirectory: true)

    private struct Info: Codable {
        var window: [CGFloat]
        var scale: CGFloat
        /// What the saved file shows now, points.
        var margin: CGFloat
    }

    private static func files(for screenshot: URL) -> (image: URL, info: URL) {
        let name = screenshot.lastPathComponent
        return (folder.appendingPathComponent(name + ".png"), folder.appendingPathComponent(name + ".json"))
    }

    /// Off the main thread: a PNG of a large window takes a moment.
    static func store(_ shot: WindowShot, margin: CGFloat, for screenshot: URL) {
        let files = files(for: screenshot)
        let info = Info(window: [shot.window.minX, shot.window.minY, shot.window.width, shot.window.height],
                        scale: shot.scale, margin: margin)
        let full = shot.full
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let destination = CGImageDestinationCreateWithURL(files.image as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, full, nil)
                guard CGImageDestinationFinalize(destination) else { return }
                try JSONEncoder().encode(info).write(to: files.info)
                prune()
            } catch {
                Log.warning("Window shot not cached for \(screenshot.lastPathComponent): \(Log.describe(error))", "screenshots")
            }
        }
    }

    static func load(for screenshot: URL) -> (shot: WindowShot, margin: CGFloat)? {
        let files = files(for: screenshot)
        guard let data = try? Data(contentsOf: files.info), let info = try? JSONDecoder().decode(Info.self, from: data),
              info.window.count == 4,
              let source = CGImageSourceCreateWithURL(files.image as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let window = CGRect(x: info.window[0], y: info.window[1], width: info.window[2], height: info.window[3])
        return (WindowShot(full: full, window: window, scale: info.scale), info.margin)
    }

    /// The editor saved the shot with another margin.
    static func setMargin(_ margin: CGFloat, for screenshot: URL) {
        let url = files(for: screenshot).info
        guard let data = try? Data(contentsOf: url), var info = try? JSONDecoder().decode(Info.self, from: data) else { return }
        info.margin = margin
        try? JSONEncoder().encode(info).write(to: url)
    }

    static func remove(for screenshot: URL) {
        let files = files(for: screenshot)
        try? FileManager.default.removeItem(at: files.image)
        try? FileManager.default.removeItem(at: files.info)
    }

    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let images = items.filter { $0.pathExtension == "png" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        for image in images.dropFirst(keep) {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: image.deletingPathExtension().appendingPathExtension("json"))
        }
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
