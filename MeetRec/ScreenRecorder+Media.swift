import Accelerate
import AVFoundation
import ScreenCaptureKit

/// Stateless helpers of the recorder: frame and audio inspection, output size and bitrate, the file's
/// tracks for the log.
extension ScreenRecorder {
    /// The largest rectangle of the content's proportions centred in a width × height frame.
    static func centeredRect(content: CGRect, width: Int, height: Int) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let frameW = CGFloat(width), frameH = CGFloat(height)
        let scale = min(frameW / content.width, frameH / content.height)
        let w = (content.width * scale).rounded(), h = (content.height * scale).rounded()
        return CGRect(x: ((frameW - w) / 2).rounded(), y: ((frameH - h) / 2).rounded(), width: w, height: h)
    }

    static func audioInput(channels: Int) -> AVAssetWriterInput {
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
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    /// Brightest luma in a sparse grid of the frame's Y plane (420v: black is 16). A whole frame at
    /// black level means the screen is black: locked, asleep, or protected content.
    static func maxLuma(_ sampleBuffer: CMSampleBuffer) -> Int? {
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
    static func peakLevel(_ sampleBuffer: CMSampleBuffer) -> Float? {
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

    static func describeAudioFormat(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return "unknown" }
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel) bit, formatID=\(asbd.mFormatID), flags=\(asbd.mFormatFlags), frames=\(sampleBuffer.numSamples)"
    }

    static func fileSize(_ url: URL?) -> String {
        guard let url, let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Reads the finished file back and logs its tracks, so a broken file shows up in the log right away.
    /// Awaited before the file is handed on: the model renames it right after the stop.
    static func logAssetInfo(_ url: URL) async {
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

    static func outputSize(filter: SCContentFilter, maxHeight: Int?) -> (Int, Int) {
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
    static func bitrate(width: Int, height: Int, fps: Int, codec: AVVideoCodecType) -> Int {
        let bitsPerPixel = codec == .hevc ? 0.05 : 0.08
        let value = Double(width * height * fps) * bitsPerPixel
        return Int(min(max(value, 1_500_000), 20_000_000))
    }
}
