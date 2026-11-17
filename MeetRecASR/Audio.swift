// The recording's audio tracks as 16 kHz mono samples, with AVFoundation (no ffmpeg), and WAV files
// for the models.
import AVFoundation

struct AudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The audio tracks of a recording in file order, each with whether it is the default (enabled,
/// played) one. A track holds its asset weakly: keep the asset while reading.
func audioTracks(_ asset: AVAsset) async throws -> [(track: AVAssetTrack, isDefault: Bool)] {
    var result: [(AVAssetTrack, Bool)] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
        result.append((track, try await track.load(.isEnabled)))
    }
    return result
}

/// One track as 16 kHz mono samples (channels averaged), each piece placed at its time in the
/// recording, so tracks that start later or have gaps stay in step with the others.
func decode(_ track: AVAssetTrack, of asset: AVAsset) async throws -> [Float] {
    let descriptions = try await track.load(.formatDescriptions)
    let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        .map(Int.init) ?? 1
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVSampleRateConverterAlgorithmKey: AVSampleRateConverterAlgorithm_Mastering,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? AudioError(message: "cannot read audio") }
    var samples: [Float] = []
    var interleaved: [Float] = []
    // Pieces closer than this to where the previous one ended follow it directly: sample times are
    // rounded, and a gap or overlap of a few samples is not a real gap.
    let slack = sampleRate / 100
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { continue }
        interleaved = [Float](repeating: 0, count: frames * channels)
        let status = interleaved.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr else { throw AudioError(message: "audio buffer \(status)") }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        var at = time.isNumeric ? max(Int((time.seconds * Double(sampleRate)).rounded()), 0) : samples.count
        if abs(at - samples.count) <= slack { at = samples.count }
        if samples.count < at + frames {
            samples.append(contentsOf: repeatElement(0, count: at + frames - samples.count))
        }
        if channels == 1 {
            for i in 0..<frames { samples[at + i] = interleaved[i] }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[i * channels + c] }
                samples[at + i] = sum * scale
            }
        }
    }
    if reader.status == .failed { throw reader.error ?? AudioError(message: "cannot read audio") }
    return samples
}

/// Adds `other` into `audio` sample by sample (no gain: louder parts may clip in the WAV, as before).
func mix(_ audio: inout [Float], _ other: [Float]) {
    if audio.count < other.count { audio.append(contentsOf: repeatElement(0, count: other.count - audio.count)) }
    for i in other.indices { audio[i] += other[i] }
}

/// A 16-bit 16 kHz mono WAV.
func writeWAV(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let block = 1 << 16
    var offset = 0
    while offset < samples.count {
        let count = min(block, samples.count - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = buffer.floatChannelData![0]
        for i in 0..<count { channel[i] = min(max(samples[offset + i], -1), 1) }
        try file.write(from: buffer)
        offset += count
    }
}
