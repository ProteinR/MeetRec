import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Files and pixels: PNG with the screen's scale in its DPI (Preview shows it at point size), the
/// clipboard, the list for the panel, text recognition.
enum ScreenshotFiles {
    static let panelLimit = 5
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    /// In "Авто", JPEG is used when it is at most this share of the PNG: photos and gradients shrink a
    /// lot, while text and flat UI stay PNG and sharp.
    static let jpegShare = 0.4

    struct Item: Identifiable, Equatable {
        let url: URL
        let date: Date
        var id: String { url.path }
    }

    /// The newest PNGs in `folder` and how many there are in all.
    static func list(in folder: URL, limit: Int = panelLimit) -> (items: [Item], total: Int) {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let items = files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .map { url -> Item in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Item(url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
            }
            // By when the shot was taken: our names and Shottr's ("SCR-…") differ, so not by name.
            // Saving an edit keeps the creation date (`write`).
            .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
        return (Array(items.prefix(limit)), items.count)
    }

    /// "2026-10-16 14-03-22.png" (a second shot in the same second gets " (2)"); with `auto` it may be
    /// ".jpg" (see `encode`).
    static func save(_ image: CGImage, scale: CGFloat, in folder: URL, date: Date = Date(), auto: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (data, ext) = try encode(image, scale: scale, auto: auto)
        let stem = RecordingFiles.uniqueStem(RecordingFiles.timestamp(date), in: folder, ext: ext)
        let url = folder.appendingPathComponent(stem).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// PNG, or in "Авто" JPEG when it comes out at most `jpegShare` of the PNG's size.
    static func encode(_ image: CGImage, scale: CGFloat, auto: Bool) throws -> (Data, String) {
        guard let png = png(image, scale: scale) else {
            throw NSError(domain: "MeetRec", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        if auto, let jpeg = jpeg(image, scale: scale), Double(jpeg.count) <= Double(png.count) * jpegShare {
            return (jpeg, "jpg")
        }
        return (png, "png")
    }

    /// Writes atomically, so an interrupted save never leaves half a picture; the format follows the
    /// file's extension (an edited JPEG stays JPEG).
    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        guard let data = isJPEG ? jpeg(image, scale: scale) : png(image, scale: scale) else {
            throw NSError(domain: "MeetRec", code: 2, userInfo: [NSLocalizedDescriptionKey: "image encoding failed"])
        }
        // An atomic write makes a new file; keep the shot's creation date, so an edit does not move it
        // to the top of the list.
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        try data.write(to: url, options: .atomic)
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
    }

    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        encoded(image, type: .png, scale: scale, extra: [:])
    }

    static func jpeg(_ image: CGImage, scale: CGFloat) -> Data? {
        encoded(image, type: .jpeg, scale: scale, extra: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    private static func encoded(_ image: CGImage, type: UTType, scale: CGFloat, extra: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        properties.merge(extra) { $1 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Where shots that were not saved to the folder live while their toast can be dragged out.
    static var dragFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MeetRec Screenshots", isDirectory: true)
    }

    static func dragCopy(_ image: CGImage, scale: CGFloat) -> URL? {
        try? save(image, scale: scale, in: dragFolder)
    }

    static func clearDragCopies() {
        try? FileManager.default.removeItem(at: dragFolder)
    }

    /// The image and its pixels per point (from the DPI; 1 when missing).
    static func load(_ url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.error("Screenshot could not be read: \(url.path)", "screenshots")
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return (image, max(1, (dpi / 72).rounded()))
    }

    /// Big pictures (frozen screens, encoding, the editor's render) leave tens of MB of freed malloc
    /// blocks that the allocator keeps; give them back to the system after such work.
    static func releaseFreedMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    static func downscaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let factor = min(1, CGFloat(maxPixels) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func thumbnail(_ url: URL, maxPixels: Int = 240) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// PNG and TIFF, both at point size, so messengers and editors paste it sharp and not doubled.
    /// MeetRec keeps this data while the shot is in the clipboard: the TIFF is LZW-compressed
    /// (a 1440p screen: 14 MB → 2.5 MB, ~40 ms more).
    static func copy(_ image: CGImage, scale: CGFloat) {
        let item = NSPasteboardItem()
        if let png = png(image, scale: scale) { item.setData(png, forType: .png) }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Russian and English text, line by line, top to bottom. `region` is in image pixels
    /// (top-left origin); nil reads the whole image.
    static func recognizeText(in image: CGImage, region: CGRect? = nil) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                // Off: correction "fixes" code, identifiers and e-mail addresses.
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["ru-RU", "en-US"]
                if let region {
                    request.regionOfInterest = normalizedRegion(region, width: image.width, height: image.height)
                }
                let handler = VNImageRequestHandler(cgImage: image)
                do {
                    try handler.perform([request])
                } catch {
                    Log.error("OCR failed: \(Log.describe(error))", "screenshots")
                }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// Vision's region of interest: normalised, bottom-left origin, clamped to the image.
    static func normalizedRegion(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let clamped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !clamped.isNull, w > 0, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: clamped.minX / w, y: (h - clamped.maxY) / h, width: clamped.width / w, height: clamped.height / h)
    }
}
