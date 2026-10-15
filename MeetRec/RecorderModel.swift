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
    static let shared = RecorderModel()
    static let autoDisplay = 0

    // Settings
    @AppStorage("displayID") var displayID = RecorderModel.autoDisplay
    @AppStorage("fps") var fps = 15
    @AppStorage("resolution") var resolution = ResolutionPreset.p1080.rawValue
    @AppStorage("codec") var codec = "h264"
    @AppStorage("systemAudio") var systemAudio = true
    @AppStorage("microphone") var microphone = true
    @AppStorage("microphoneID") var microphoneID = ""
    @AppStorage("meetingDetection") var meetingDetection = false
    /// Comma-separated `MeetingApp.id`s chosen for detection.
    @AppStorage("meetingApps") var meetingAppsRaw = "teams"
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
    @Published private(set) var health: RecordingHealth?
    @Published var errorMessage: String?
    /// Detector state for the UI ("Жду встречу", "Идёт встреча в Teams"…); nil when detection is off.
    @Published private(set) var detectorStatus: String?
    /// Name of the app whose meeting started the current recording; nil for manual recordings.
    @Published private(set) var autoStartedBy: String?
    /// Shown in the panel after a recording stops ("Запись остановлена · 34:12 · …") until the next start.
    @Published var stopNotice: String?
    /// Whether the menu panel is on screen; drives the microphone level preview.
    @Published var panelVisible = false

    static let showPanelNotification = Notification.Name("MeetRecShowPanel")
    private let detector = MeetingDetector()

    private let recorder = ScreenRecorder()
    private var startedAt: Date?
    private var timer: Timer?
    private var healthTracker: HealthTracker?
    /// Alerts already sent in the current episode; cleared when the condition recovers.
    private var firedAlerts: Set<String> = []
    static let micSilenceAlertAfter: TimeInterval = 60
    static let systemSilenceAlertAfter: TimeInterval = 120
    private var recordingNames = (microphone: "", display: "")
    private var hotKey: HotKey?
    private var observers: [NSObjectProtocol] = []

    static let hotKeyHint = "⌃⌥⌘R"

    private var recordingDisplayID: CGDirectDisplayID?

    init() {
        Self.logLaunch()
        Notifier.shared.setUp()
        refreshDevices()
        detector.onStatus = { [weak self] status in self?.detectorStatus = status }
        detector.onMeetingStarted = { [weak self] app in self?.meetingStarted(app) }
        detector.onMeetingEnded = { [weak self] app in self?.meetingEnded(app) }
        configureDetector()
        recorder.onUnexpectedStop = { [weak self] error in
            Log.error("Recording stopped unexpectedly: \(Log.describe(error))")
            self?.stopNotice = "Запись прервалась: \(error.localizedDescription)"
            NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
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

    // MARK: - Meeting detection

    var selectedMeetingApps: Set<String> {
        Set(meetingAppsRaw.split(separator: ",").map(String.init))
    }

    func setMeetingApp(_ app: MeetingApp, enabled: Bool) {
        var ids = selectedMeetingApps
        if enabled { ids.insert(app.id) } else { ids.remove(app.id) }
        meetingAppsRaw = ids.sorted().joined(separator: ",")
        Log.info("Meeting app \(app.name) \(enabled ? "enabled" : "disabled")", "meetings")
        configureDetector()
    }

    /// (Re)starts the detector from the current settings.
    func configureDetector() {
        let apps = MeetingApp.all.filter { $0.supported && selectedMeetingApps.contains($0.id) }
        if meetingDetection, !apps.isEmpty {
            detector.start(apps: apps)
        } else {
            detector.stop()
            detectorStatus = nil
        }
    }

    private func meetingStarted(_ app: MeetingApp) {
        guard !isRecording, !isBusy else {
            Log.info("Meeting in \(app.name) started, but a recording is already running; leaving it as is", "meetings")
            return
        }
        Log.info("Auto-starting recording for \(app.name) meeting", "meetings")
        start(autoApp: app)
        // Show the panel so it is obvious that recording started; clicking outside folds it away.
        NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
    }

    private func meetingEnded(_ app: MeetingApp) {
        guard isRecording else { return }
        guard autoStartedBy != nil else {
            Log.info("Meeting in \(app.name) ended; the recording was started manually, so it keeps running", "meetings")
            return
        }
        Log.info("Auto-stopping recording: \(app.name) meeting ended", "meetings")
        // Show the panel again at the end, so it is obvious that recording stopped.
        stop(reason: "встреча в \(app.id == "teams" ? "Teams" : app.name) завершилась", showPanel: true)
    }

    func start(autoApp: MeetingApp? = nil) {
        guard !isRecording, !isBusy else {
            Log.debug("start() ignored: isRecording=\(isRecording) isBusy=\(isBusy)")
            return
        }
        errorMessage = nil
        stopNotice = nil
        firedAlerts = []
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
                recordingNames = (microphone: resolvedMicrophoneName(), display: display.name)
                try await recorder.start(options)
                recordingDisplayID = display.id
                autoStartedBy = autoApp?.name
                didStart()
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Start failed: \(Log.describe(error))")
            }
        }
    }

    func stop(reason: String? = nil, showPanel: Bool = false) {
        guard isRecording, !isBusy else {
            Log.debug("stop() ignored: isRecording=\(isRecording) isBusy=\(isBusy)")
            return
        }
        isBusy = true
        Log.info("Stopping after \(elapsedText)\(reason.map { " (\($0))" } ?? "")")
        let duration = elapsedText
        Task {
            let file = await recorder.stop()
            isBusy = false
            didStop(file: file)
            stopNotice = ["Запись остановлена · \(duration)", reason].compactMap { $0 }.joined(separator: " · ")
            if showPanel {
                NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
            }
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
        healthTracker = HealthTracker(startedAt: startedAt ?? Date(), microphoneOn: microphone, systemAudioOn: systemAudio,
                                      microphoneName: recordingNames.microphone, displayName: recordingNames.display)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Updates the timer and the live status panel; logs whenever a source changes state.
    private func tick() {
        guard let startedAt, var tracker = healthTracker else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        let newHealth = tracker.update(with: recorder.snapshot())
        healthTracker = tracker
        if let old = health {
            logTransition(old.microphone, newHealth.microphone)
            logTransition(old.systemAudio, newHealth.systemAudio)
            logTransition(old.screen, newHealth.screen)
        }
        health = newHealth
        checkAlerts(newHealth)
    }

    /// Notifies once per episode when a source dies or stays silent too long during a recording.
    private func checkAlerts(_ health: RecordingHealth) {
        let mic = recordingNames.microphone
        alert("mic-dead", when: microphone && health.microphone.state == .noSignal,
              title: "Микрофон не передаёт сигнал",
              body: "«\(mic)»: звук не приходит. Проверьте устройство или перезапустите запись.")
        alert("system-dead", when: systemAudio && health.systemAudio.state == .noSignal,
              title: "Звук системы не записывается",
              body: "Сигнал звука системы пропал. Голоса собеседников могут не попасть в запись.")
        alert("screen-dead", when: health.screen.state == .noSignal,
              title: "Экран не записывается",
              body: "Кадры не приходят: монитор отключён, заблокирован экран или Mac уснул.")
        alert("mic-quiet", when: microphone && health.microphone.state != .noSignal
                && health.micSilentFor >= Self.micSilenceAlertAfter,
              title: "Микрофон молчит больше минуты",
              body: "Если вы говорите, но полоска не двигается, выбран не тот микрофон («\(mic)»).")
        alert("system-quiet", when: systemAudio && health.systemAudio.state != .noSignal
                && health.systemSilentFor >= Self.systemSilenceAlertAfter,
              title: "Не слышно собеседников 2 минуты",
              body: "Звук системы тихий. Если собеседники говорят, их голоса не записываются.")
    }

    private func alert(_ key: String, when condition: Bool, title: String, body: String) {
        if condition {
            guard !firedAlerts.contains(key) else { return }
            firedAlerts.insert(key)
            Log.warning("Alert: \(title)", "alerts")
            Notifier.shared.send(id: "meetrec-\(key)", title: title, body: body)
        } else if firedAlerts.remove(key) != nil {
            Log.info("Alert cleared: \(key)", "alerts")
        }
    }

    private func logTransition(_ old: SignalHealth, _ new: SignalHealth) {
        guard old.state != new.state else { return }
        let text = "\(new.title): \(old.state) → \(new.state) (\(new.detail))"
        if new.state == .noSignal || (new.title == "Микрофон" && new.state == .quiet) {
            Log.warning(text, "health")
        } else {
            Log.info(text, "health")
        }
    }

    /// The device ScreenCaptureKit will actually use: the chosen one, or the system default input.
    private func resolvedMicrophoneName() -> String {
        if !microphoneID.isEmpty, let chosen = microphones.first(where: { $0.id == microphoneID }) {
            return chosen.name
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "по умолчанию"
    }

    private func didStop(file: URL?) {
        isRecording = false
        timer?.invalidate()
        healthTracker = nil
        health = nil
        timer = nil
        startedAt = nil
        recordingDisplayID = nil
        autoStartedBy = nil
        if let file {
            lastFile = file
            Transcriber.shared.recordingFinished(file)
        }
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
