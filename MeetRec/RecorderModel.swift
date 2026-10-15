import AppKit
import AVFoundation
import Carbon
import SwiftUI

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
}

struct MicrophoneInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case native, p1440, p1080, p720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "Как у монитора"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    static let autoDisplay = 0

    // Settings
    @AppStorage("displayID") var displayID = RecorderModel.autoDisplay
    @AppStorage("fps") var fps = 15
    @AppStorage("resolution") var resolution = ResolutionPreset.p1080.rawValue
    @AppStorage("codec") var codec = "h264"
    @AppStorage("systemAudio") var systemAudio = true
    @AppStorage("microphone") var microphone = true
    @AppStorage("microphoneID") var microphoneID = ""
    @AppStorage("folder") var folderPath = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetRec").path

    // State
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var microphones: [MicrophoneInfo] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastFile: URL?
    @Published var errorMessage: String?

    private let recorder = ScreenRecorder()
    private var startedAt: Date?
    private var timer: Timer?
    private var hotKey: HotKey?
    private var observers: [NSObjectProtocol] = []

    static let hotKeyHint = "⌃⌥⌘R"

    private var recordingDisplayID: CGDirectDisplayID?

    init() {
        Self.logLaunch()
        refreshDevices()
        recorder.onUnexpectedStop = { [weak self] error in
            Log.error("Recording stopped unexpectedly: \(Log.describe(error))")
            self?.didStop(file: nil)
            self?.errorMessage = "Запись остановлена: \(error.localizedDescription)"
        }
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            Log.info("Hotkey \(Self.hotKeyHint) pressed")
            Task { @MainActor in self?.toggle() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                Log.info("Audio device \(name == AVCaptureDevice.wasConnectedNotification ? "connected" : "disconnected"): \(device?.localizedName ?? "?") (\(device?.uniqueID ?? "?"))", "devices")
                Task { @MainActor in self?.refreshDevices() }
            })
        }
        // Sleep, wake and screen lock are the usual reasons a long recording goes wrong.
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "System will sleep"),
            (NSWorkspace.didWakeNotification, "System did wake"),
            (NSWorkspace.screensDidSleepNotification, "Screens did sleep"),
            (NSWorkspace.screensDidWakeNotification, "Screens did wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "User session resigned (fast user switch)"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "User session became active"),
            (NSWorkspace.willPowerOffNotification, "System will power off"),
        ]
        for (name, text) in workspaceEvents {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    let recording = self?.isRecording ?? false
                    if recording { Log.warning("\(text) while recording", "system") } else { Log.info(text, "system") }
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, text) in [("com.apple.screenIsLocked", "Screen locked"), ("com.apple.screenIsUnlocked", "Screen unlocked")] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    let recording = self?.isRecording ?? false
                    if recording { Log.warning("\(text) while recording", "system") } else { Log.info(text, "system") }
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Log.info("App will terminate")
        })
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    var elapsedText: String {
        let total = Int(elapsed)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// The display that will actually be recorded: the chosen one, or in "auto" mode an external
    /// monitor if one is connected, otherwise the built-in screen.
    var effectiveDisplay: DisplayInfo? {
        if displayID != Self.autoDisplay, let chosen = displays.first(where: { $0.id == CGDirectDisplayID(displayID) }) {
            return chosen
        }
        return displays.first(where: { !$0.isBuiltIn }) ?? displays.first
    }

    func refreshDevices() {
        let previousDisplays = displays
        let previousMics = microphones
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(id: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName) }

        if displays != previousDisplays {
            Log.info("Displays: " + displays.map { "\($0.id) \"\($0.name)\"\($0.isBuiltIn ? " built-in" : "")" }.joined(separator: ", ")
                     + " → effective: \(effectiveDisplay.map { "\($0.id) \($0.name)" } ?? "none")", "devices")
            if isRecording, let recordingDisplayID, !displays.contains(where: { $0.id == recordingDisplayID }) {
                Log.warning("Recorded display \(recordingDisplayID) disappeared during recording", "devices")
            }
        }
        if microphones != previousMics {
            Log.info("Microphones: " + microphones.map { "\"\($0.name)\" (\($0.id))" }.joined(separator: ", ")
                     + " → default: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")", "devices")
            if isRecording, microphone, !microphoneID.isEmpty, !microphones.contains(where: { $0.id == microphoneID }) {
                Log.warning("Selected microphone \(microphoneID) disappeared during recording", "devices")
            }
        }
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording, !isBusy else {
            Log.debug("start() ignored: isRecording=\(isRecording) isBusy=\(isBusy)")
            return
        }
        errorMessage = nil
        guard let display = effectiveDisplay else {
            errorMessage = "Нет доступных мониторов"
            Log.error("Start failed: no displays")
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            guard await ensurePermissions() else { return }
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                let options = RecordingOptions(
                    displayID: display.id,
                    fps: fps,
                    maxHeight: ResolutionPreset(rawValue: resolution)?.maxHeight,
                    codec: codec == "hevc" ? .hevc : .h264,
                    systemAudio: systemAudio,
                    microphone: microphone,
                    microphoneID: microphoneID.isEmpty ? nil : microphoneID,
                    outputURL: nextFileURL()
                )
                Log.info("Starting: display=\(display.id) \"\(display.name)\" (setting=\(displayID == Self.autoDisplay ? "auto" : String(displayID))) mic=\(microphones.first(where: { $0.id == microphoneID })?.name ?? "default: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")")
                try await recorder.start(options)
                recordingDisplayID = display.id
                didStart()
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Start failed: \(Log.describe(error))")
            }
        }
    }

    func stop() {
        guard isRecording, !isBusy else {
            Log.debug("stop() ignored: isRecording=\(isRecording) isBusy=\(isBusy)")
            return
        }
        isBusy = true
        Log.info("Stopping after \(elapsedText)")
        Task {
            let file = await recorder.stop()
            isBusy = false
            didStop(file: file)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            Log.info("Output folder changed to \(url.path)")
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    func revealLastFile() {
        guard let lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    // MARK: - Private

    private func didStart() {
        Log.info("Recording state: recording")
        isRecording = true
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func didStop(file: URL?) {
        isRecording = false
        timer?.invalidate()
        timer = nil
        startedAt = nil
        recordingDisplayID = nil
        if let file { lastFile = file }
        Log.info("Recording state: stopped, file=\(file?.path ?? "none")")
    }

    func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    private static func logLaunch() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        Log.info("──────── MeetRec \(version) launched, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(String(cString: model)), log: \(Log.fileURL.path)")
        Log.info("Permissions: screen=\(CGPreflightScreenCaptureAccess() ? "granted" : "not granted") microphone=\(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)))")
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    private func nextFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return folderURL.appendingPathComponent("\(formatter.string(from: Date())).mov")
    }

    private func ensurePermissions() async -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            Log.warning("Screen recording permission not granted, requesting", "permissions")
            CGRequestScreenCaptureAccess()
            errorMessage = "Разрешите запись экрана для MeetRec в Системных настройках → Конфиденциальность и безопасность → Запись экрана, затем перезапустите MeetRec."
            return false
        }
        if microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            Log.info("Microphone permission is \(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))), requesting", "permissions")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.info("Microphone permission \(granted ? "granted" : "denied")", "permissions")
            if !granted {
                errorMessage = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
                return false
            }
        }
        return true
    }
}
