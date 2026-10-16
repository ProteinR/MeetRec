import Accelerate
import AVFoundation

/// The mixed track every player plays: microphone + system audio in one, with the microphone brought
/// up to the level of the other side.
///
/// ScreenCaptureKit records the microphone raw, while the call app (Teams…) delivers the other side
/// already processed and loud: the user's own voice ends up ~10 dB quieter. The gain is one value per
/// recording (measured from the speech levels of both tracks), not a moving AGC, so nothing pumps;
/// a soft limiter keeps the rare loud peak from clipping. The separate tracks stay as recorded.
enum AudioMixer {
    static let sampleRate = 48_000.0
    static let maxGainDB: Float = 18
    /// Without the other side (a recording of oneself) the microphone is brought to this level.
    static let targetSpeechDB: Float = -20

    /// LPCM for reading: interleaved Float32.
    static func pcmSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// AAC for the mixed track, like the system audio track the recorder writes.
    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000,
    ]

    /// Gain (dB) for the microphone so its speech is as loud as the other side's.
    static func microphoneGain(asset: AVAsset, microphone: AVAssetTrack, system: AVAssetTrack) async throws -> Float {
        async let mic = speechLevel(asset: asset, track: microphone)
        async let sys = speechLevel(asset: asset, track: system)
        let (micLevel, sysLevel) = try await (mic, sys)
        guard let micLevel else { return 0 }
        return gain(microphone: micLevel, system: sysLevel)
    }

    static func gain(microphone: Float, system: Float?) -> Float {
        min(max((system ?? targetSpeechDB) - microphone, 0), maxGainDB)
    }

    /// Typical level of speech in a track (dB): the 90th percentile of 50 ms frames that are not
    /// silence. Nil when the track holds (almost) no sound.
    static func speechLevel(asset: AVAsset, track: AVAssetTrack) async throws -> Float? {
        let reader = try AVAssetReader(asset: asset)
        let rate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(sampleRate: rate, channels: 1))
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ChapterWriter.Failure.writer("cannot read audio") }
        let frame = Int(rate * 0.05)
        var levels: [Float] = []
        var pending: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            pending += floats(in: sample)
            var start = 0
            while pending.count - start >= frame {
                var rms: Float = 0
                pending.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + start, 1, &rms, vDSP_Length(frame)) }
                let db = 20 * log10(max(rms, 1e-9))
                if db > -55 { levels.append(db) }
                start += frame
            }
            pending.removeFirst(start)
        }
        // Less than 2 s of sound: nothing to measure.
        guard levels.count >= 40 else { return nil }
        levels.sort()
        return levels[Int(Double(levels.count - 1) * 0.9)]
    }

    /// Multiplies the mixed samples by the overall gain and limits peaks softly, in place.
    static func apply(gain: Float, to sample: CMSampleBuffer) {
        withSamples(of: sample) { pointer, count in
            var g = gain
            vDSP_vsmul(pointer, 1, &g, pointer, 1, vDSP_Length(count))
            for i in 0..<count { pointer[i] = limit(pointer[i]) }
        }
    }

    /// Unchanged below 0.9; above it bends smoothly towards 1.0 and never passes it.
    static func limit(_ x: Float) -> Float {
        let knee: Float = 0.9
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let bent = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
        return x < 0 ? -bent : bent
    }

    private static func floats(in sample: CMSampleBuffer) -> [Float] {
        var result: [Float] = []
        withSamples(of: sample) { pointer, count in result = Array(UnsafeBufferPointer(start: pointer, count: count)) }
        return result
    }

    private static func withSamples(of sample: CMSampleBuffer, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        body(data.assumingMemoryBound(to: Float.self), Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
    }
}
