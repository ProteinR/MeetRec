import AVFoundation
import Foundation

/// Live input level of the selected microphone while the settings are visible, so a dead or wrong
/// device is noticed before recording. Runs only while the panel is open and nothing is recording
/// (macOS shows its orange microphone dot during that time).
@MainActor
final class MicrophoneMonitor: ObservableObject {
    @Published private(set) var levelDB: Float = -60
    @Published private(set) var deviceName: String?
    /// True once the device has delivered audio; false means nothing arrives (wrong/dead device).
    @Published private(set) var receiving = false

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private var currentID: String?
    private var startedAt: Date?

    /// Starts (or switches) monitoring; `deviceID` empty means the system default input.
    func start(deviceID: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let device = deviceID.isEmpty
            ? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice(uniqueID: deviceID)
        guard let device else {
            stop()
            deviceName = nil
            return
        }
        if session != nil, currentID == device.uniqueID { return }
        stop()

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
        } catch {
            Log.warning("Mic preview: cannot open \(device.localizedName): \(Log.describe(error))", "devices")
            return
        }
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        self.session = session
        self.output = output
        currentID = device.uniqueID
        deviceName = device.localizedName
        receiving = false
        startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Log.debug("Mic preview started: \(device.localizedName)", "devices")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let session {
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
            Log.debug("Mic preview stopped", "devices")
        }
        session = nil
        output = nil
        currentID = nil
        levelDB = -60
        receiving = false
    }

    private func tick() {
        guard let channels = output?.connections.first?.audioChannels, !channels.isEmpty else { return }
        let peak = channels.map(\.peakHoldLevel).max() ?? -160
        if peak > -150 { receiving = true }
        let level = max(peak, -60)
        // Instant attack, slow release.
        levelDB = level >= levelDB ? level : max(level, levelDB - 3)
    }
}
