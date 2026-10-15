import Accelerate
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Live signal information for the "recording status" panel. Peaks are linear (0…1) and are reset
/// each time a snapshot is taken, so they hold the loudest moment since the previous UI tick.
struct LiveStatus {
    var micPeak: Float = 0
    var systemPeak: Float = 0
    var lastMicBuffer: Date?
    var lastSystemBuffer: Date?
    /// Any screen sample, including "idle" ones: proves the stream is alive even on a static screen.
    var lastScreenSample: Date?
    var videoFrames = 0
    var width = 0
    var height = 0
    var fileURL: URL?
    /// When the first video frame started the file: marker times are counted from here.
    var sessionStartedAt: Date?
    /// Brightest sampled luma (0…255) of the latest checked frame; nil before the first check.
    var frameMaxLuma: Int?
}

/// A window that can be recorded instead of the whole display.
struct CaptureWindow: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    let bundleID: String

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

struct RecordingOptions {
    var displayID: CGDirectDisplayID
    var fps: Int
    /// Output height limit in pixels; nil keeps the display's native resolution.
    var maxHeight: Int?
    var codec: AVVideoCodecType
    var systemAudio: Bool
    var microphone: Bool
    /// `AVCaptureDevice.uniqueID`; nil uses the system default microphone.
    var microphoneID: String?
    var outputURL: URL
}

enum RecorderError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case notRecording
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Монитор не найден"
        case .windowNotFound: return "Окно не найдено — возможно, оно закрыто"
        case .notRecording: return "Запись не идёт"
        case .writer(let message): return "Не удалось начать запись: \(message)"
        }
    }
}

/// Per-recording counters, logged every 10 seconds and at the end. They are what tells a healthy
/// recording from one that silently lost video or a microphone.
private struct Stats {
    var videoAppended = 0
    var videoIdle = 0
    var videoNotReady = 0
    var videoAppendFailed = 0
    var systemAudioAppended = 0
    var systemAudioNotReady = 0
    var micAppended = 0
    var micNotReady = 0
    var audioBeforeSession = 0
    var appendFailed = 0
    var firstVideoPTS: CMTime = .invalid
    var lastVideoPTS: CMTime = .invalid
    var lastSystemAudioPTS: CMTime = .invalid
    var lastMicPTS: CMTime = .invalid
    var lastVideoArrival: Date?
    var systemAudioFormat: String?
    var micFormat: String?

    func summary(since start: Date) -> String {
        let seconds = max(Date().timeIntervalSince(start), 0.001)
        let fps = Double(videoAppended) / seconds
        let span = (firstVideoPTS.isValid && lastVideoPTS.isValid) ? (lastVideoPTS - firstVideoPTS).seconds : 0
        let lastFrameAgo = lastVideoArrival.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "never"
        return String(format: "t=%.0fs video=%d (%.1f fps, idle=%d, notReady=%d, failed=%d, span=%.1fs, last frame %@) sysAudio=%d (notReady=%d) mic=%d (notReady=%d) audioBeforeSession=%d appendFailed=%d avSync(sys-video)=%@ avSync(mic-video)=%@",
                      seconds, videoAppended, fps, videoIdle, videoNotReady, videoAppendFailed, span, lastFrameAgo,
                      systemAudioAppended, systemAudioNotReady, micAppended, micNotReady,
                      audioBeforeSession, appendFailed,
                      Self.drift(lastSystemAudioPTS, lastVideoPTS), Self.drift(lastMicPTS, lastVideoPTS))
    }

    /// Difference between the newest audio and video timestamps. With a static screen video has no
    /// new frames, so a growing positive value is normal; a large negative one means audio stalled.
    private static func drift(_ audio: CMTime, _ video: CMTime) -> String {
        guard audio.isValid, video.isValid else { return "n/a" }
        return String(format: "%+.2fs", (audio - video).seconds)
    }
}

/// Records one display with system audio and microphone into a fragmented QuickTime movie.
///
/// Fragmented means the file is readable even if the app crashes or the Mac shuts down mid-recording:
/// at most the last few seconds are lost. Video, system audio and microphone are separate tracks, so
/// a later transcription step can tell "me" (microphone) from "them" (system audio).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main queue when capture stops on its own (display unplugged, permission revoked…).
    var onUnexpectedStop: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.dmemruk.MeetRec.capture")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var finishing = false
    private var stats = Stats()
    private var startedAt = Date()
    private var statsTimer: DispatchSourceTimer?
    private var live = LiveStatus()
    /// The display the recording started on; full-screen capture returns to it.
    private var displayID: CGDirectDisplayID?

    /// Normal windows of other apps that can be recorded on their own.
    static func shareableWindows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window -> CaptureWindow? in
            guard window.windowLayer == 0, window.frame.width >= 200, window.frame.height >= 150,
                  let app = window.owningApplication, app.bundleIdentifier != own,
                  !app.applicationName.isEmpty else { return nil }
            return CaptureWindow(id: window.windowID, appName: app.applicationName,
                                 title: window.title ?? "", bundleID: app.bundleIdentifier)
        }
        .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
    }

    /// Switches a running recording between the whole display (`windowID` nil) and a single window,
    /// or to another display (`displayID`). The output size stays the same (another display's picture
    /// is fitted in); a window is shown where it is on its display, with everything else (other
    /// windows, notifications) left out. Returns the name of the display now captured.
    @discardableResult
    func setTarget(windowID: CGWindowID?, displayID newDisplayID: CGDirectDisplayID? = nil) async throws -> String {
        guard let stream, self.displayID != nil else { throw RecorderError.notRecording }
        if let newDisplayID { self.displayID = newDisplayID }
        guard let displayID = self.displayID else { throw RecorderError.notRecording }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let display: SCDisplay
        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.windowNotFound
            }
            // The display showing most of the window; usually the one being recorded.
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let found = content.displays.first(where: { $0.frame.contains(center) })
                    ?? content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayNotFound
            }
            display = found
            filter = SCContentFilter(display: display, including: [window])
            Log.info("Capture target → window \(windowID) \"\(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "")\" frame=\(NSStringFromRect(window.frame)) on display \(display.displayID)", "recorder")
        } else {
            guard let found = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                throw RecorderError.displayNotFound
            }
            display = found
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            Log.info("Capture target → whole display \(display.displayID)", "recorder")
        }
        try await stream.updateContentFilter(filter)
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName ?? "монитор \(display.displayID)"
    }

    /// Returns the current live status and resets the peak meters. Safe to call from any thread.
    func snapshot() -> LiveStatus {
        queue.sync {
            let current = live
            live.micPeak = 0
            live.systemPeak = 0
            return current
        }
    }

    /// The file being written and when its first frame arrived, without touching the level meters.
    func currentFile() -> (url: URL?, sessionStartedAt: Date?) {
        queue.sync { (live.fileURL, live.sessionStartedAt) }
    }

    func start(_ options: RecordingOptions) async throws {
        Log.info("Start requested: displayID=\(options.displayID) fps=\(options.fps) maxHeight=\(options.maxHeight.map(String.init) ?? "native") codec=\(options.codec.rawValue) systemAudio=\(options.systemAudio) microphone=\(options.microphone) micID=\(options.microphoneID ?? "default") file=\(options.outputURL.path)", "recorder")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.error("SCShareableContent failed: \(Log.describe(error))", "recorder")
            throw error
        }
        Log.debug("Shareable displays: " + content.displays.map { "\($0.displayID) \($0.width)x\($0.height)pt frame=\(NSStringFromRect($0.frame))" }.joined(separator: "; "), "recorder")

        guard let display = content.displays.first(where: { $0.displayID == options.displayID })
                ?? content.displays.first else {
            Log.error("No display available (requested \(options.displayID))", "recorder")
            throw RecorderError.displayNotFound
        }
        if display.displayID != options.displayID {
            Log.warning("Requested display \(options.displayID) not found, falling back to \(display.displayID)", "recorder")
        }
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let (width, height) = Self.outputSize(filter: filter, maxHeight: options.maxHeight)
        let bitrate = Self.bitrate(width: width, height: height, fps: options.fps, codec: options.codec)
        Log.info("Display \(display.displayID): contentRect=\(NSStringFromRect(filter.contentRect)) scale=\(filter.pointPixelScale) → output \(width)x\(height), bitrate=\(bitrate / 1000) kbps", "recorder")

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        if options.microphone, let id = options.microphoneID {
            config.microphoneCaptureDeviceID = id
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mov)
        } catch {
            Log.error("AVAssetWriter init failed: \(Log.describe(error))", "recorder")
            throw error
        }
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        try add(video, to: writer)

        var systemAudio: AVAssetWriterInput?
        if options.systemAudio {
            let input = Self.audioInput(channels: 2)
            try add(input, to: writer)
            systemAudio = input
        }
        var microphone: AVAssetWriterInput?
        if options.microphone {
            let input = Self.audioInput(channels: 1)
            try add(input, to: writer)
            microphone = input
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.systemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            if options.microphone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
        } catch {
            Log.error("addStreamOutput failed: \(Log.describe(error))", "recorder")
            throw error
        }

        guard writer.startWriting() else {
            Log.error("startWriting failed: status=\(writer.status.rawValue) error=\(Log.describe(writer.error))", "recorder")
            throw RecorderError.writer(writer.error?.localizedDescription ?? "unknown")
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.systemAudioInput = systemAudio
            self.microphoneInput = microphone
            self.sessionStarted = false
            self.finishing = false
            self.stats = Stats()
            self.startedAt = Date()
            self.live = LiveStatus(width: width, height: height, fileURL: options.outputURL)
        }
        self.stream = stream
        self.displayID = display.displayID

        do {
            try await stream.startCapture()
        } catch {
            Log.error("startCapture failed: \(Log.describe(error))", "recorder")
            await finish()
            throw error
        }
        startStatsTimer()
        Log.info("Capture started", "recorder")
    }

    /// Stops capture and closes the file. Returns the file URL if anything was recorded.
    @discardableResult
    func stop() async -> URL? {
        Log.info("Stop requested", "recorder")
        if let stream {
            do {
                try await stream.stopCapture()
                Log.debug("stopCapture ok", "recorder")
            } catch {
                Log.warning("stopCapture failed: \(Log.describe(error))", "recorder")
            }
        }
        return await finish()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else {
            Log.warning("Invalid sample buffer of type \(type.rawValue)", "capture")
            return
        }
        guard !finishing, let writer else { return }
        guard writer.status == .writing else {
            if stats.appendFailed == 0 {
                Log.error("Writer not writing: status=\(writer.status.rawValue) error=\(Log.describe(writer.error))", "capture")
            }
            stats.appendFailed += 1
            return
        }

        switch type {
        case .screen:
            live.lastScreenSample = Date()
            guard Self.isCompleteFrame(sampleBuffer) else {
                stats.videoIdle += 1
                return
            }
            guard let videoInput else { return }
            let pts = sampleBuffer.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                live.sessionStartedAt = Date()
                stats.firstVideoPTS = pts
                Log.info("Session started at first video frame, pts=\(pts.seconds)", "capture")
            }
            guard videoInput.isReadyForMoreMediaData else {
                stats.videoNotReady += 1
                if stats.videoNotReady == 1 || stats.videoNotReady % 100 == 0 {
                    Log.warning("Video input not ready, dropped \(stats.videoNotReady) frames so far (encoder can't keep up?)", "capture")
                }
                return
            }
            if live.videoFrames % 30 == 0 {
                live.frameMaxLuma = Self.maxLuma(sampleBuffer) ?? live.frameMaxLuma
            }
            if videoInput.append(sampleBuffer) {
                live.videoFrames += 1
                stats.videoAppended += 1
                stats.lastVideoPTS = pts
                stats.lastVideoArrival = Date()
            } else {
                stats.videoAppendFailed += 1
                Log.error("Video append failed: writer status=\(writer.status.rawValue) error=\(Log.describe(writer.error))", "capture")
            }
        case .audio:
            if stats.systemAudioFormat == nil {
                stats.systemAudioFormat = Self.describeAudioFormat(sampleBuffer)
                Log.info("First system audio buffer: \(stats.systemAudioFormat ?? "?")", "capture")
            }
            live.lastSystemBuffer = Date()
            if let peak = Self.peakLevel(sampleBuffer) { live.systemPeak = max(live.systemPeak, peak) }
            if append(sampleBuffer, to: systemAudioInput, track: "system audio") {
                stats.systemAudioAppended += 1
                stats.lastSystemAudioPTS = sampleBuffer.presentationTimeStamp
            } else if sessionStarted {
                stats.systemAudioNotReady += 1
            }
        case .microphone:
            if stats.micFormat == nil {
                stats.micFormat = Self.describeAudioFormat(sampleBuffer)
                Log.info("First microphone buffer: \(stats.micFormat ?? "?")", "capture")
            }
            live.lastMicBuffer = Date()
            if let peak = Self.peakLevel(sampleBuffer) { live.micPeak = max(live.micPeak, peak) }
            if append(sampleBuffer, to: microphoneInput, track: "microphone") {
                stats.micAppended += 1
                stats.lastMicPTS = sampleBuffer.presentationTimeStamp
            } else if sessionStarted {
                stats.micNotReady += 1
            }
        @unknown default:
            Log.warning("Unknown stream output type \(type.rawValue)", "capture")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Stream stopped with error: \(Log.describe(error))", "recorder")
        Task {
            await finish()
            await MainActor.run { onUnexpectedStop?(error) }
        }
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        Log.info("Presenter overlay / video effect started", "recorder")
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        Log.info("Presenter overlay / video effect stopped", "recorder")
    }

    // MARK: - Private

    /// Returns true when the buffer was written.
    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, track: String) -> Bool {
        guard let input else { return false }
        // Audio before the first video frame has no session to land in.
        guard sessionStarted else {
            stats.audioBeforeSession += 1
            return false
        }
        guard input.isReadyForMoreMediaData else {
            Log.debug("\(track) input not ready, buffer dropped", "capture")
            return false
        }
        if input.append(sampleBuffer) { return true }
        stats.appendFailed += 1
        Log.error("\(track) append failed: writer status=\(writer?.status.rawValue ?? -1) error=\(Log.describe(writer?.error))", "capture")
        return false
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.writer != nil else { return }
            let size = Self.fileSize(self.writer?.outputURL)
            Log.info("Stats: \(self.stats.summary(since: self.startedAt)) file=\(size)", "stats")
            if self.sessionStarted == false {
                Log.warning("No video frame received yet — is the screen locked or the display asleep?", "stats")
            }
        }
        timer.resume()
        statsTimer = timer
    }

    @discardableResult
    private func finish() async -> URL? {
        let state: (AVAssetWriter, Bool, [AVAssetWriterInput], String)? = queue.sync {
            guard let writer, !finishing else { return nil }
            finishing = true
            statsTimer?.cancel()
            statsTimer = nil
            let inputs = [videoInput, systemAudioInput, microphoneInput].compactMap { $0 }
            return (writer, sessionStarted, inputs, stats.summary(since: startedAt))
        }
        stream = nil
        displayID = nil
        guard let (writer, started, inputs, summary) = state else {
            Log.debug("finish() called with nothing to finish", "recorder")
            return nil
        }
        Log.info("Final stats: \(summary)", "recorder")

        var result: URL?
        if started, writer.status == .writing {
            inputs.forEach { $0.markAsFinished() }
            let begin = Date()
            await writer.finishWriting()
            let took = String(format: "%.2fs", Date().timeIntervalSince(begin))
            if writer.status == .completed {
                result = writer.outputURL
                Log.info("File finished in \(took): \(writer.outputURL.path) size=\(Self.fileSize(writer.outputURL))", "recorder")
                Self.logAssetInfo(writer.outputURL)
            } else {
                Log.error("finishWriting failed after \(took): status=\(writer.status.rawValue) error=\(Log.describe(writer.error)). Fragmented file may still be playable: \(writer.outputURL.path)", "recorder")
            }
        } else {
            Log.warning("No video was recorded (sessionStarted=\(started), status=\(writer.status.rawValue), error=\(Log.describe(writer.error))); removing empty file", "recorder")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
        }

        queue.sync {
            self.writer = nil
            self.videoInput = nil
            self.systemAudioInput = nil
            self.microphoneInput = nil
            self.sessionStarted = false
            self.finishing = false
        }
        return result
    }

    private func add(_ input: AVAssetWriterInput, to writer: AVAssetWriter) throws {
        guard writer.canAdd(input) else {
            Log.error("Writer cannot add \(input.mediaType.rawValue) input with settings \(String(describing: input.outputSettings))", "recorder")
            throw RecorderError.writer("cannot add \(input.mediaType.rawValue) track")
        }
        writer.add(input)
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// ScreenCaptureKit also delivers "idle" frames when nothing changed; only complete ones carry pixels.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    /// Brightest luma in a sparse grid of the frame's Y plane (420v: black is 16). A whole frame at
    /// black level means the screen is black: locked, asleep, or protected content.
    private static func maxLuma(_ sampleBuffer: CMSampleBuffer) -> Int? {
        guard let pixelBuffer = sampleBuffer.imageBuffer, CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var maximum: UInt8 = 0
        for y in Swift.stride(from: 0, to: height, by: 8) {
            let row = bytes + y * stride
            for x in Swift.stride(from: 0, to: width, by: 8) where row[x] > maximum {
                maximum = row[x]
            }
        }
        return Int(maximum)
    }

    /// Peak absolute sample value of a 32-bit float PCM buffer (what ScreenCaptureKit delivers).
    private static func peakLevel(_ sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return nil }
        do {
            return try sampleBuffer.withAudioBufferList { list, _ in
                var peak: Float = 0
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    var bufferPeak: Float = 0
                    vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
                    peak = max(peak, bufferPeak)
                }
                return peak
            }
        } catch {
            return nil
        }
    }

    private static func describeAudioFormat(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return "unknown" }
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel) bit, formatID=\(asbd.mFormatID), flags=\(asbd.mFormatFlags), frames=\(sampleBuffer.numSamples)"
    }

    private static func fileSize(_ url: URL?) -> String {
        guard let url, let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Reads the finished file back and logs its tracks, so a broken file shows up in the log right away.
    private static func logAssetInfo(_ url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)
                var parts: [String] = []
                for track in tracks {
                    let range = try await track.load(.timeRange)
                    let rate = try await track.load(.estimatedDataRate)
                    var part = "\(track.mediaType.rawValue)#\(track.trackID) start=\(String(format: "%.2f", range.start.seconds)) dur=\(String(format: "%.2f", range.duration.seconds))s \(Int(rate / 1000)) kbps"
                    if track.mediaType == .video {
                        let size = try await track.load(.naturalSize)
                        let fps = try await track.load(.nominalFrameRate)
                        part += " \(Int(size.width))x\(Int(size.height)) \(String(format: "%.1f", fps)) fps"
                    }
                    parts.append(part)
                }
                Log.info("Verified file: duration=\(String(format: "%.2f", duration.seconds))s tracks=[\(parts.joined(separator: "; "))]", "recorder")
            } catch {
                Log.error("Could not read back finished file: \(Log.describe(error))", "recorder")
            }
        }
    }

    private static func outputSize(filter: SCContentFilter, maxHeight: Int?) -> (Int, Int) {
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        if let maxHeight, height > CGFloat(maxHeight) {
            width = width * CGFloat(maxHeight) / height
            height = CGFloat(maxHeight)
        }
        // Encoders want even dimensions.
        return (Int(width) / 2 * 2, Int(height) / 2 * 2)
    }

    /// Screen content compresses well; this keeps text sharp without huge files.
    private static func bitrate(width: Int, height: Int, fps: Int, codec: AVVideoCodecType) -> Int {
        let bitsPerPixel = codec == .hevc ? 0.05 : 0.08
        let value = Double(width * height * fps) * bitsPerPixel
        return Int(min(max(value, 1_500_000), 20_000_000))
    }
}
