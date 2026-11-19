import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Small pictures for the panel's strips, kept on disk in `~/Library/Caches/MeetRec/Thumbnails`, so
/// a folder of thousands of screenshots or long recordings is decoded once and then shown at once.
///
/// An entry is keyed by the file itself (volume, inode, size, modification date), not by its name:
/// a renamed recording keeps its picture, an edited screenshot gets a new one. Only what the strip
/// shows is ever made; at most two are made at a time, in the background. Entries not used for
/// `maxAge` are removed at launch.
enum Thumbnails {
    /// Points of a recording tile; pictures are made at twice that for Retina screens.
    static let videoSize = CGSize(width: 124, height: 70)
    /// The same tile as a recording's, so both tabs look alike.
    static let screenshotSize = videoSize
    /// The preview in a recording's tip: frames from the whole video, shown in turn.
    static let previewSize = CGSize(width: 320, height: 180)
    static let hoverFrameCount = 10
    static let maxAge: TimeInterval = 60 * 24 * 3600

    struct Video {
        let poster: NSImage?
        /// Seconds; nil when the file could not be read.
        let duration: Double?
    }

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/Thumbnails", isDirectory: true)
    }

    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // A few strips' worth; a tile keeps its own picture while it is on screen.
        cache.countLimit = 120
        return cache
    }()
    private static let durations = NSCache<NSString, NSNumber>()
    private static let limiter = AsyncLimiter(2)

    // MARK: - Keys

    /// "<dev>-<inode>-<size>-<mtime>": the same file under another name or folder has the same key.
    static func key(for url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec / 1_000_000)
        return "\(info.st_dev)-\(info.st_ino)-\(info.st_size)-\(mtime)"
    }

    private static func file(_ key: String, _ suffix: String) -> URL {
        folder.appendingPathComponent("\(key)\(suffix)")
    }

    // MARK: - Screenshots

    /// Only from memory, without waiting: for a tile's first frame.
    static func cachedScreenshot(_ url: URL) -> NSImage? {
        key(for: url).flatMap { memory.object(forKey: "s\($0)" as NSString) }
    }

    /// Cached, else made from the file (a 5K PNG takes tens of ms to decode).
    static func screenshot(_ url: URL) async -> NSImage? {
        guard let key = key(for: url) else { return nil }
        if let image = memory.object(forKey: "s\(key)" as NSString) { return image }
        let image: NSImage? = await limiter.run {
            // "-s2": the tile grew in 0.15.0; the older, smaller "-s.jpg" files age out with `prune`.
            if let cached = readJPEG(file(key, "-s2.jpg")) { return cached }
            let pixels = Int(max(screenshotSize.width, screenshotSize.height) * 2 * 1.6)
            guard let made = ScreenshotFiles.thumbnail(url, maxPixels: pixels) else { return nil }
            writeJPEG(made, to: file(key, "-s2.jpg"))
            return made
        }
        if let image { memory.setObject(image, forKey: "s\(key)" as NSString) }
        return image
    }

    /// The bigger picture in a screenshot's tip (`previewSize`, fitted): made on hover only and
    /// kept on disk, not in memory, so a row of tiles does not hold big pictures.
    static func screenshotPreview(_ url: URL) async -> NSImage? {
        guard let key = key(for: url) else { return nil }
        return await limiter.run {
            if let cached = readJPEG(file(key, "-sp.jpg")) { return cached }
            let pixels = Int(max(previewSize.width, previewSize.height) * 2)
            guard let made = ScreenshotFiles.thumbnail(url, maxPixels: pixels) else { return nil }
            writeJPEG(made, to: file(key, "-sp.jpg"))
            return made
        }
    }

    // MARK: - Recordings

    /// Only from memory, without waiting: for a tile's first frame.
    static func cachedVideo(_ url: URL) -> Video? {
        guard let key = key(for: url), let poster = memory.object(forKey: "v\(key)" as NSString) else { return nil }
        return Video(poster: poster, duration: durations.object(forKey: key as NSString)?.doubleValue)
    }

    /// The frame from the middle of the recording (from a quarter or three quarters of it when the
    /// middle is black: a shared screen paused, a minimised window) and the duration.
    static func video(_ url: URL) async -> Video {
        guard let key = key(for: url) else { return Video(poster: nil, duration: nil) }
        if let image = memory.object(forKey: "v\(key)" as NSString) {
            return Video(poster: image, duration: durations.object(forKey: key as NSString)?.doubleValue)
        }
        let result: Video = await limiter.run {
            let durationFile = file(key, "-d.txt")
            if let poster = readJPEG(file(key, "-v.jpg")),
               let text = try? String(contentsOf: durationFile, encoding: .utf8), let seconds = Double(text) {
                return Video(poster: poster, duration: seconds)
            }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
                return Video(poster: nil, duration: nil)
            }
            try? String(duration).write(to: durationFile, atomically: true, encoding: .utf8)
            let generator = makeGenerator(asset)
            var poster: CGImage?
            for share in [0.5, 0.25, 0.75] {
                guard let frame = try? await generator.image(at: CMTime(seconds: duration * share, preferredTimescale: 600)).image else { continue }
                if poster == nil || !isDark(frame) { poster = frame }
                if !isDark(frame) { break }
            }
            guard let poster else { return Video(poster: nil, duration: duration) }
            let image = NSImage(cgImage: poster, size: NSSize(width: poster.width, height: poster.height))
            writeJPEG(image, to: file(key, "-v.jpg"))
            return Video(poster: image, duration: duration)
        }
        if let poster = result.poster { memory.setObject(poster, forKey: "v\(key)" as NSString) }
        if let duration = result.duration { durations.setObject(NSNumber(value: duration), forKey: key as NSString) }
        return result
    }

    /// `hoverFrameCount` frames spread over the recording, for the preview in its tip while the
    /// pointer is over its tile. Kept on disk as one strip picture; not kept in memory once the
    /// pointer leaves.
    static func hoverFrames(_ url: URL) async -> [NSImage] {
        guard let key = key(for: url) else { return [] }
        let stripFile = file(key, "-p.jpg")
        let width = Int(previewSize.width * 2), height = Int(previewSize.height * 2)
        if let strip = readCGImage(stripFile) { return split(strip, count: hoverFrameCount) }
        return await limiter.run {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return [] }
            let generator = makeGenerator(asset, size: previewSize)
            var frames: [CGImage] = []
            for index in 0..<hoverFrameCount {
                let time = duration * (Double(index) + 0.5) / Double(hoverFrameCount)
                if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                    frames.append(frame)
                }
            }
            guard !frames.isEmpty,
                  let context = CGContext(data: nil, width: width * frames.count, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            context.setFillColor(.black)
            context.fill(CGRect(x: 0, y: 0, width: width * frames.count, height: height))
            for (index, frame) in frames.enumerated() {
                context.draw(frame, in: aspectFill(frame, in: CGRect(x: index * width, y: 0, width: width, height: height)))
            }
            guard let strip = context.makeImage() else { return [] }
            writeJPEG(NSImage(cgImage: strip, size: NSSize(width: strip.width, height: strip.height)), to: stripFile)
            Log.debug("Hover frames made for \(url.lastPathComponent): \(frames.count)", "files")
            return split(strip, count: frames.count)
        }
    }

    private static func makeGenerator(_ asset: AVAsset, size: CGSize = videoSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        // The nearest keyframe is close enough for a preview and much faster than an exact frame.
        let tolerance = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    // MARK: - Pixels

    /// Mean brightness below ~6 %: a black frame (a stream that showed nothing).
    static func isDark(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var sum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
        }
        return Double(sum) / Double(64 * 3 * 255) < 0.06
    }

    private static func aspectFill(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func split(_ strip: CGImage, count: Int) -> [NSImage] {
        guard count > 0 else { return [] }
        let width = strip.width / count
        return (0..<count).compactMap { index in
            strip.cropping(to: CGRect(x: index * width, y: 0, width: width, height: strip.height))
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    private static func readCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func readJPEG(_ url: URL) -> NSImage? {
        readCGImage(url).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    private static func writeJPEG(_ image: NSImage, to url: URL) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    // MARK: - Cleanup

    /// Removes entries not made or used for `maxAge` (a read touches nothing, so this is by when
    /// they were made: an old one is simply made again).
    static func prune() {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            let cutoff = Date().addingTimeInterval(-maxAge)
            var removed = 0
            for file in files {
                let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if date < cutoff, (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
            if removed > 0 { Log.info("Thumbnails: \(removed) old cache files removed", "files") }
        }
    }
}

/// At most `limit` jobs at a time; the others wait their turn (decoding a few dozen pictures at once
/// when a strip appears would load every core and the disk).
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ job: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await job()
        release()
        return result
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
