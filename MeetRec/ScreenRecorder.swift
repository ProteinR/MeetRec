import AVFoundation
import CoreMedia
import ScreenCaptureKit

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
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Монитор не найден"
        case .writer(let message): return "Не удалось начать запись: \(message)"
        }
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

    func start(_ options: RecordingOptions) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID })
                ?? content.displays.first else {
            throw RecorderError.displayNotFound
        }
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let (width, height) = Self.outputSize(filter: filter, maxHeight: options.maxHeight)

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

        let writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate(width: width, height: height, fps: options.fps, codec: options.codec),
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
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }

        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "unknown")
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.systemAudioInput = systemAudio
            self.microphoneInput = microphone
            self.sessionStarted = false
            self.finishing = false
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            await finish()
            throw error
        }
    }

    /// Stops capture and closes the file. Returns the file URL if anything was recorded.
    @discardableResult
    func stop() async -> URL? {
        if let stream {
            try? await stream.stopCapture()
        }
        return await finish()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !finishing, let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer), let videoInput else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            append(sampleBuffer, to: systemAudioInput)
        case .microphone:
            append(sampleBuffer, to: microphoneInput)
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await finish()
            await MainActor.run { onUnexpectedStop?(error) }
        }
    }

    // MARK: - Private

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Audio before the first video frame has no session to land in.
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    @discardableResult
    private func finish() async -> URL? {
        let state: (AVAssetWriter, Bool, [AVAssetWriterInput])? = queue.sync {
            guard let writer, !finishing else { return nil }
            finishing = true
            let inputs = [videoInput, systemAudioInput, microphoneInput].compactMap { $0 }
            return (writer, sessionStarted, inputs)
        }
        stream = nil
        guard let (writer, started, inputs) = state else { return nil }

        var result: URL?
        if started, writer.status == .writing {
            inputs.forEach { $0.markAsFinished() }
            await writer.finishWriting()
            result = writer.status == .completed ? writer.outputURL : nil
        } else {
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
