import AVFoundation
import Foundation

/// Records a short solo voice sample from the default microphone (16 kHz mono WAV) for speaker
/// enrollment, with a countdown and a live level.
@MainActor
final class VoiceSampleRecorder: ObservableObject {
    static let duration: TimeInterval = 20

    @Published private(set) var isRecording = false
    @Published private(set) var remaining: Int = 0
    @Published private(set) var levelDB: Float = -60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var completion: ((URL?) -> Void)?

    func start(completion: @escaping (URL?) -> Void) {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetrec-voice-sample.wav")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.duration) else {
                Log.error("Voice sample: record() returned false", "voice")
                completion(nil)
                return
            }
            self.recorder = recorder
        } catch {
            Log.error("Voice sample: cannot start recorder: \(Log.describe(error))", "voice")
            completion(nil)
            return
        }
        Log.info("Voice sample recording started (\(Int(Self.duration)) s, default input \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"))", "voice")
        self.completion = completion
        isRecording = true
        startedAt = Date()
        remaining = Int(Self.duration)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func cancel() {
        guard isRecording else { return }
        Log.info("Voice sample recording cancelled", "voice")
        finish(success: false)
    }

    private func tick() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        levelDB = max(recorder.peakPower(forChannel: 0), -60)
        let elapsed = Date().timeIntervalSince(startedAt)
        remaining = max(0, Int((Self.duration - elapsed).rounded(.up)))
        if !recorder.isRecording || elapsed >= Self.duration + 0.3 {
            finish(success: true)
        }
    }

    private func finish(success: Bool) {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        let url = recorder?.url
        recorder = nil
        isRecording = false
        levelDB = -60
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        Log.info("Voice sample recording finished: success=\(success) size=\(size) bytes", "voice")
        completion?(success ? url : nil)
        completion = nil
    }
}
