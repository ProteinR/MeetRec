import AVFoundation
import CoreAudio
import Foundation

/// Live input level of the selected microphone while the settings are visible, so a dead or wrong
/// device is noticed before recording. Runs only while the panel is open and nothing is recording
/// (macOS shows its orange microphone dot during that time).
///
/// Bluetooth microphones are not opened by themselves: opening AirPods' microphone switches them to
/// the headset profile (HFP), which takes radio time from other Bluetooth devices, so a Bluetooth
/// mouse stutters and the cursor jumps each time the panel opens. They are checked on request.
@MainActor
final class MicrophoneMonitor: ObservableObject {
    @Published private(set) var levelDB: Float = -60
    @Published private(set) var deviceName: String?
    /// True once the device has delivered audio; false means nothing arrives (wrong/dead device).
    @Published private(set) var receiving = false
    /// The device is Bluetooth and waits for `check()` instead of being opened by itself.
    @Published private(set) var waitingForCheck = false

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private var currentID: String?
    private var startedAt: Date?
    /// The Bluetooth device the user asked to check while the panel is open.
    private var checkedID: String?

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
        stopSession()
        deviceName = device.localizedName
        if Self.isBluetooth(device), checkedID != device.uniqueID {
            waitingForCheck = true
            Log.debug("Mic preview not opened by itself (Bluetooth): \(device.localizedName)", "devices")
            return
        }
        waitingForCheck = false

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

    /// Opens a Bluetooth microphone that `start` left closed.
    func check(deviceID: String) {
        let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: deviceID)
        checkedID = device?.uniqueID
        start(deviceID: deviceID)
    }

    /// Stops monitoring; a Bluetooth device is not opened again until the next `check()`.
    func stop() {
        checkedID = nil
        waitingForCheck = false
        stopSession()
    }

    private func stopSession() {
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

    private static func isBluetooth(_ device: AVCaptureDevice) -> Bool {
        let transport = UInt32(bitPattern: device.transportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
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
