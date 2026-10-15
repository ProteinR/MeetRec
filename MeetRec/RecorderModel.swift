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
    /// Relaunch MeetRec after a crash and continue an interrupted recording (see `Watchdog`).
    @AppStorage("crashWatchdog") var crashWatchdog = true
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
    /// Timer, level meters and CPU: published separately so the panel does not redraw on every tick.
    let live = LiveRecording()
    var health: RecordingHealth? { live.health }
    @Published private(set) var lastFile: URL?
    @Published var errorMessage: String?
    /// Detector state for the UI ("Жду встречу", "Идёт встреча в Teams"…); nil when detection is off.
    @Published private(set) var detectorStatus: String?
    /// Name of the app whose meeting started the current recording; nil for manual recordings.
    @Published private(set) var autoStartedBy: String?
    /// `MeetingApp.id` behind `autoStartedBy`, for the file tag.
    private var autoStartedAppID: String?
    /// Shown in the panel after a recording stops ("Запись остановлена · 34:12 · …") until the next start.
    @Published var stopNotice: String?
    /// Whether the menu panel is on screen; drives the microphone level preview and how often the
    /// recording status refreshes (5×/s for smooth meters while visible, once a second otherwise).
    @Published var panelVisible = false {
        didSet { if isRecording, panelVisible != oldValue { scheduleTick() } }
    }
    /// Moments marked in the current recording (⌃⌥⌘M or the button).
    @Published private(set) var markers: [Marker] = []
    /// The single window being recorded instead of the whole display; nil = whole display.
    @Published private(set) var captureWindow: CaptureWindow?
    /// Windows offered in the "what to record" menu while recording.
    @Published private(set) var windows: [CaptureWindow] = []
    /// Free space on the recordings volume, refreshed while recording.
    @Published private(set) var freeSpace: Int64?
    /// Set when the Teams meeting window is not on the recorded display (or hidden).
    @Published private(set) var meetingWindowWarning: String?
    /// The display showing the Teams meeting window, offered as "записывать этот монитор".
    @Published private(set) var meetingWindowDisplay: DisplayInfo?

    static let showPanelNotification = Notification.Name("MeetRecShowPanel")
    private let detector = MeetingDetector()

    private let recorder = ScreenRecorder()
    private var startedAt: Date?
    private var timer: Timer?
    private var healthTracker: HealthTracker?
    /// Alerts already sent in the current episode; cleared when the condition recovers.
    private var firedAlerts: Set<String> = []
    private var micMuted = false
    static let micSilenceAlertAfter: TimeInterval = 60
    static let systemSilenceAlertAfter: TimeInterval = 120
    private var recordingNames = (microphone: "", display: "")
    private var hotKey: HotKey?
    private var markerHotKey: HotKey?
    private var lastDiskCheck = Date.distantPast
    private var lastTitleCheck = Date.distantPast
    private var lastWindowCheck = Date.distantPast
    /// Best title for the file name, found while recording (chosen window or Teams meeting).
    private var meetingTitle: String?
    private var observers: [NSObjectProtocol] = []
    /// Keeps the Mac and its displays awake while recording.
    private var sleepActivity: NSObjectProtocol?
    private var lastMeetingWindowCheck = Date.distantPast
    private var meetingWindowProblemSince: Date?
    /// The user chose "Игнорировать" for the meeting window warning in this recording.
    private var meetingWindowIgnored = false
    /// The meeting for which "встреча идёт, а запись не ведётся" was already shown.
    private var remindedMeeting: String?
    private var permissionTimer: Timer?
    private var loadSampler = LoadSampler()
    private var idleLoadSampler = LoadSampler()
    private var idleLoadTimer: Timer?
    private var lastLoadSample = Date.distantPast
    private var lastLoadLog = Date.distantPast
    private var highCPUSince: Date?
    static let highCPUPercent: Double = 90
    static let highCPUAlertAfter: TimeInterval = 60
    private var permissionsMissing: Set<String> = []

    static let hotKeyHint = "⌃⌥⌘R"
    static let markerHotKeyHint = "⌃⌥⌘M"

    private var recordingDisplayID: CGDirectDisplayID?

    init() {
        Self.logLaunch()
        Notifier.shared.setUp()
        refreshDevices()
        detector.onStatus = { [weak self] status in
            guard let self else { return }
            // Assign only on change: every assignment redraws the whole panel, even when hidden.
            let newStatus = self.meetingDetection ? status : nil
            if newStatus != self.detectorStatus { self.detectorStatus = newStatus }
        }
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
        markerHotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
            Log.info("Hotkey \(Self.markerHotKeyHint) pressed")
            Task { @MainActor in self?.addMarker() }
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
            MainActor.assumeIsolated { Watchdog.appWillTerminate() }
        })
        observers.append(center.addObserver(forName: Notifier.actionNotification, object: nil, queue: .main) { [weak self] note in
            let action = note.userInfo?["action"] as? String ?? ""
            Task { @MainActor in self?.handleNotificationAction(action) }
        })

        // Idle footprint every 10 minutes, so the log shows what MeetRec costs when it only waits.
        _ = idleLoadSampler.sample()
        idleLoadTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording, let load = self.idleLoadSampler.sample() else { return }
                Log.info("Load (idle, 10 min average): \(load.logText)", "stats")
            }
        }

        let interrupted = Watchdog.appLaunched(enabled: crashWatchdog)
        checkPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPermissions() }
        }
        if let interrupted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.recoverInterrupted(interrupted) }
        }
    }

    // MARK: - Crash recovery

    func setCrashWatchdog(_ enabled: Bool) {
        crashWatchdog = enabled
        Watchdog.setAgent(enabled: enabled)
    }

    /// The previous run died while recording: report the saved file, transcribe it, and continue.
    /// A manual recording restarts in a new file right away; a meeting recording is restarted by the
    /// detector if the meeting is still going (so it also stops when the meeting ends).
    private func recoverInterrupted(_ state: Watchdog.InterruptedRecording) {
        let file = URL(fileURLWithPath: state.file)
        let exists = FileManager.default.fileExists(atPath: file.path)
        let savedUntil = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let time = savedUntil.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "?"
        Log.error("Recovered after a crash during recording: \(file.lastPathComponent) (exists=\(exists), saved until \(time), auto=\(state.autoAppID ?? "no"))")

        let lastRecovery = UserDefaults.standard.double(forKey: "lastCrashRecovery")
        let crashLoop = Date().timeIntervalSince1970 - lastRecovery < 180
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastCrashRecovery")

        var body = exists ? "Запись «\(file.lastPathComponent)» сохранена до \(time)." : "Файл записи не найден."
        if crashLoop {
            body += " Сбой повторился — запись не возобновлена, начните её вручную."
            Log.error("Second crash within 3 minutes: not resuming the recording")
        } else if state.autoAppID == nil {
            body += " Запись продолжается в новом файле."
            start()
        } else if meetingDetection {
            body += " Если встреча ещё идёт, запись продолжится в новом файле."
        }
        Notifier.shared.send(id: "meetrec-crash", title: "MeetRec перезапущен после сбоя", body: body)
        stopNotice = "Запись прервалась из-за сбоя MeetRec · сохранено до \(time)"
        NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
        if exists {
            lastFile = file
            Transcriber.shared.recordingFinished(file)
        }
    }

    // MARK: - Permissions

    /// Warns as soon as Screen Recording or Microphone access is missing, not when a meeting starts.
    /// macOS 15 periodically asks again for screen recording, and updates sometimes reset it.
    private func checkPermissions() {
        var missing: Set<String> = []
        if !CGPreflightScreenCaptureAccess() { missing.insert("screen") }
        if microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { missing.insert("microphone") }
        defer { permissionsMissing = missing }
        guard missing != permissionsMissing else { return }
        guard !missing.isEmpty else {
            Log.info("Permissions OK again", "permissions")
            return
        }
        let names = missing.sorted().map { $0 == "screen" ? "запись экрана" : "микрофон" }.joined(separator: " и ")
        Log.warning("Missing permissions: \(missing.sorted().joined(separator: ", "))", "permissions")
        Notifier.shared.send(id: "meetrec-permissions", title: "MeetRec не сможет записывать",
                             body: "Нет разрешения: \(names). Без него встреча не запишется.",
                             actions: [.init(id: "open-privacy:\(missing.contains("screen") ? "screen" : "microphone")", title: "Открыть настройки")])
    }

    // MARK: - Notification buttons

    private func handleNotificationAction(_ action: String) {
        if action == "ignore-window" {
            meetingWindowIgnored = true
            meetingWindowWarning = nil
            meetingWindowDisplay = nil
            Log.info("Meeting window warning ignored for this recording")
        } else if action.hasPrefix("switch-display:"), let id = UInt32(action.dropFirst("switch-display:".count)) {
            switchDisplay(to: CGDirectDisplayID(id))
        } else if action.hasPrefix("start-meeting:") {
            let app = MeetingApp.all.first { $0.id == String(action.dropFirst("start-meeting:".count)) }
            if !isRecording { start(autoApp: app) }
            NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
        } else if action.hasPrefix("open-privacy:") {
            let pane = action.hasSuffix("screen") ? "Privacy_ScreenCapture" : "Privacy_Microphone"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Meeting window on the recorded display

    func ignoreMeetingWindow() { handleNotificationAction("ignore-window") }

    /// Records another display from now on (same file, picture fitted into the same size).
    func switchDisplay(to displayID: CGDirectDisplayID) {
        guard isRecording, !isBusy else { return }
        Task {
            do {
                let name = try await recorder.setTarget(windowID: nil, displayID: displayID)
                recordingDisplayID = displayID
                captureWindow = nil
                recordingNames.display = name
                healthTracker?.displayName = name
                meetingWindowWarning = nil
                meetingWindowDisplay = nil
                meetingWindowProblemSince = nil
                Notifier.shared.remove(id: "meetrec-meeting-window")
                Log.info("Recording switched to display \(displayID) \"\(name)\"")
            } catch {
                errorMessage = "Не удалось переключить монитор: \(error.localizedDescription)"
                Log.error("Switching display failed: \(Log.describe(error))")
            }
        }
    }

    /// While a Teams meeting is recorded as a whole display, checks that its window is on that display.
    /// A wrong monitor (e.g. built-in instead of external) is otherwise noticed only afterwards.
    private func checkMeetingWindow() {
        guard Date().timeIntervalSince(lastMeetingWindowCheck) >= 5 else { return }
        lastMeetingWindowCheck = Date()
        let teamsMeeting = autoStartedAppID == "teams" || detector.currentMeeting?.id == "teams"
        guard captureWindow == nil, !meetingWindowIgnored, teamsMeeting, let displayID = recordingDisplayID else {
            clearMeetingWindowProblem()
            return
        }
        let windows = MeetingTitle.teamsMeetingWindows()
        // No recognisable meeting window (e.g. the meeting is inside the main window): nothing to check.
        guard !windows.isEmpty else {
            clearMeetingWindowProblem()
            return
        }
        let recorded = CGDisplayBounds(displayID)
        if windows.contains(where: { $0.onScreen && Self.overlap($0.bounds, recorded) >= 0.5 }) {
            clearMeetingWindowProblem()
            return
        }
        let elsewhere = displays.first { display in
            display.id != displayID && windows.contains { $0.onScreen && Self.overlap($0.bounds, CGDisplayBounds(display.id)) >= 0.5 }
        }
        let since = meetingWindowProblemSince ?? Date()
        if meetingWindowProblemSince == nil {
            meetingWindowProblemSince = since
            Log.warning("Teams meeting window not on recorded display \(displayID): " + windows.map {
                "\"\($0.title)\" \(NSStringFromRect($0.bounds)) onScreen=\($0.onScreen)" }.joined(separator: "; ")
                + " → elsewhere: \(elsewhere.map { "\($0.id) \($0.name)" } ?? "hidden")", "health")
        }
        guard Date().timeIntervalSince(since) >= 10, meetingWindowWarning == nil else { return }
        let recordedName = recordingNames.display
        let text = elsewhere.map { "Окно встречи Teams на мониторе «\($0.name)», а записывается «\(recordedName)»." }
            ?? "Окно встречи Teams не видно на записываемом мониторе «\(recordedName)» (свёрнуто или на другом рабочем столе)."
        meetingWindowWarning = text
        meetingWindowDisplay = elsewhere
        var actions: [Notifier.Action] = []
        if let elsewhere { actions.append(.init(id: "switch-display:\(elsewhere.id)", title: "Записывать «\(elsewhere.name)»")) }
        actions.append(.init(id: "ignore-window", title: "Игнорировать"))
        Log.warning("Alert: meeting window not recorded", "alerts")
        Notifier.shared.send(id: "meetrec-meeting-window", title: "Встреча не попадает в запись?", body: text, actions: actions)
    }

    private func clearMeetingWindowProblem() {
        if meetingWindowProblemSince != nil {
            Log.info("Teams meeting window is on the recorded display again (or check not needed)", "health")
            Notifier.shared.remove(id: "meetrec-meeting-window")
        }
        meetingWindowProblemSince = nil
        meetingWindowWarning = nil
        meetingWindowDisplay = nil
    }

    /// Share of `rect` that lies inside `area`.
    private static func overlap(_ rect: CGRect, _ area: CGRect) -> CGFloat {
        let common = rect.intersection(area)
        guard !common.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return (common.width * common.height) / (rect.width * rect.height)
    }

    // MARK: - Meeting without recording

    /// Shows "встреча идёт, а запись не ведётся" once per meeting if, after `delay`, the meeting is
    /// still on and nothing records: auto-recording off, its start failed, or it was stopped by hand.
    private func scheduleMeetingReminder(_ app: MeetingApp, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isRecording, !self.isBusy, self.detector.currentMeeting?.id == app.id,
                  self.remindedMeeting != app.id else { return }
            self.remindedMeeting = app.id
            let name = app.id == "teams" ? "Teams" : app.name
            Log.warning("Meeting in \(app.name) is going on without a recording", "alerts")
            Notifier.shared.send(id: "meetrec-not-recording", title: "Идёт встреча в \(name), запись не ведётся",
                                 body: "Нажмите «Начать запись», если встречу нужно записать.",
                                 actions: [.init(id: "start-meeting:\(app.id)", title: "Начать запись")])
        }
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    var elapsedText: String { live.elapsedText }

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
        ).devices.filter { !Self.isLoopback($0) }.map { MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName) }
        if !microphoneID.isEmpty, let device = AVCaptureDevice(uniqueID: microphoneID), Self.isLoopback(device) {
            Log.warning("Chosen microphone \"\(device.localizedName)\" is a loopback device, switching to the system default", "devices")
            microphoneID = ""
        }

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

    /// Virtual devices that carry an app's own output, not a voice: Teams' "Microsoft Teams Audio".
    /// Picking one by mistake records silence instead of the user.
    private static func isLoopback(_ device: AVCaptureDevice) -> Bool {
        device.uniqueID.hasPrefix("MSLoopbackDriverDevice") || device.localizedName == "Microsoft Teams Audio"
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
        // The detector also runs with auto-recording off: it then only reminds that a meeting is not recorded.
        let apps = MeetingApp.all.filter { $0.supported && selectedMeetingApps.contains($0.id) }
        if !apps.isEmpty {
            detector.start(apps: apps)
        } else {
            detector.stop()
        }
        if !meetingDetection { detectorStatus = nil }
    }

    private func meetingStarted(_ app: MeetingApp) {
        remindedMeeting = nil
        guard meetingDetection else {
            Log.info("Meeting in \(app.name) started; auto-recording is off", "meetings")
            scheduleMeetingReminder(app, after: 10)
            return
        }
        scheduleMeetingReminder(app, after: 30) // in case the start fails
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
        remindedMeeting = nil
        Notifier.shared.remove(id: "meetrec-not-recording")
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
        let free = DiskSpace.available(at: folderURL)
        Log.info("Free space on recordings volume: \(free.map(DiskSpace.format) ?? "unknown")")
        if let free, free < DiskSpace.refuseStartBelow {
            errorMessage = "На диске осталось \(DiskSpace.format(free)) — запись не начата. Освободите место или выберите другую папку."
            Log.error("Start refused: only \(DiskSpace.format(free)) free")
            if autoApp != nil {
                Notifier.shared.send(id: "meetrec-disk-full", title: "Запись встречи не началась",
                                     body: "На диске осталось \(DiskSpace.format(free)). Освободите место.")
            }
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
                if let autoApp {
                    // Decided now, while it is known: transcription may run much later.
                    RecordingTag.setMeetingApp(autoApp.id, on: options.outputURL)
                }
                recordingDisplayID = display.id
                autoStartedBy = autoApp?.name
                autoStartedAppID = autoApp?.id
                didStart()
                if let free, free < DiskSpace.warnBelow {
                    alert("disk-low", when: true, title: "Мало места на диске",
                          body: "Свободно \(DiskSpace.format(free)). Запись остановится сама, если останется меньше \(DiskSpace.format(DiskSpace.stopBelow)).")
                }
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Start failed: \(Log.describe(error))")
                if let autoApp {
                    Notifier.shared.send(id: "meetrec-start-failed", title: "Запись встречи в \(autoApp.name) не началась",
                                         body: error.localizedDescription)
                }
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
        if let meeting = detector.currentMeeting, reason == nil {
            // Stopped by hand while the meeting goes on: remind once in case it was a mistake.
            scheduleMeetingReminder(meeting, after: 60)
        }
        let duration = elapsedText
        let title = meetingTitle
        let appID = autoStartedAppID
        Task {
            var file = await recorder.stop()
            if let recorded = file, let appID, RecordingTag.meetingApp(of: recorded) == nil {
                RecordingTag.setMeetingApp(appID, on: recorded)
            }
            if let recorded = file, let title {
                file = renameWithTitle(recorded, title: title)
            }
            isBusy = false
            didStop(file: file)
            stopNotice = ["Запись остановлена · \(duration)", reason].compactMap { $0 }.joined(separator: " · ")
            if showPanel {
                NotificationCenter.default.post(name: Self.showPanelNotification, object: nil)
            }
        }
    }

    // MARK: - Markers

    /// Marks the current moment of the recording; it shows up in the transcript as "⭐ 12:34".
    func addMarker() {
        let current = recorder.currentFile()
        guard isRecording, let file = current.url else {
            Log.debug("Marker ignored: not recording")
            return
        }
        let origin = current.sessionStartedAt ?? startedAt ?? Date()
        let marker = Marker(time: max(0, Date().timeIntervalSince(origin)))
        markers.append(marker)
        do {
            try MarkerFile.save(markers, for: file)
            Log.info("Marker #\(markers.count) at \(marker.timeText)")
        } catch {
            Log.error("Could not save markers: \(Log.describe(error))")
        }
        NSSound(named: "Tink")?.play()
    }

    // MARK: - Window capture

    /// Reloads the windows offered for single-window recording.
    func refreshWindows() {
        Task {
            do {
                windows = try await ScreenRecorder.shareableWindows()
            } catch {
                Log.warning("Window list failed: \(Log.describe(error))", "recorder")
            }
        }
    }

    /// Records only `window` from now on, or the whole display again when nil. Works mid-recording.
    func record(window: CaptureWindow?) {
        guard isRecording, !isBusy else { return }
        Task {
            do {
                let displayName = try await recorder.setTarget(windowID: window?.id)
                captureWindow = window
                healthTracker?.displayName = window.map { "окно \($0.appName)" } ?? displayName
                if let window {
                    lastWindowCheck = Date()
                    updateMeetingTitle(force: true)
                    Log.info("Recording only window: \(window.label)")
                } else {
                    Log.info("Recording whole display again")
                }
            } catch {
                errorMessage = "Не удалось переключить запись: \(error.localizedDescription)"
                Log.error("Switching capture target failed: \(Log.describe(error))")
            }
        }
    }

    /// If the recorded window was closed, falls back to the whole display so nothing is lost.
    private func checkCaptureWindow() {
        guard let window = captureWindow, Date().timeIntervalSince(lastWindowCheck) >= 3 else { return }
        lastWindowCheck = Date()
        guard !MeetingTitle.exists(window.id) else { return }
        Log.warning("Recorded window \(window.id) (\(window.label)) is gone, switching back to the whole display")
        Notifier.shared.send(id: "meetrec-window-gone", title: "Окно закрыто",
                             body: "«\(window.label)» больше нет — записывается весь экран.")
        record(window: nil)
    }

    // MARK: - Load

    private func sampleLoad() {
        let now = Date()
        guard now.timeIntervalSince(lastLoadSample) >= 2 else { return }
        lastLoadSample = now
        guard let sample = loadSampler.sample() else { return }
        live.update(load: sample)
        if now.timeIntervalSince(lastLoadLog) >= 30 {
            lastLoadLog = now
            Log.info("Load: \(sample.logText)", "stats")
        }
        if sample.systemCPU >= Self.highCPUPercent {
            if highCPUSince == nil {
                highCPUSince = now
                Log.warning("System CPU high: \(sample.logText)", "health")
            }
        } else if highCPUSince != nil {
            highCPUSince = nil
            Log.info("System CPU back to normal: \(sample.logText)", "health")
        }
        alert("cpu-high", when: highCPUSince.map { now.timeIntervalSince($0) >= Self.highCPUAlertAfter } ?? false,
              title: "Mac перегружен",
              body: "Процессор занят на \(Int(sample.systemCPU))% больше минуты. Видео может терять кадры: закройте лишние программы.")
    }

    // MARK: - Disk space and title

    private func checkDiskSpace() {
        guard Date().timeIntervalSince(lastDiskCheck) >= 10 else { return }
        lastDiskCheck = Date()
        guard let free = DiskSpace.available(at: folderURL) else { return }
        freeSpace = free
        alert("disk-low", when: free < DiskSpace.warnBelow, title: "Мало места на диске",
              body: "Свободно \(DiskSpace.format(free)). Запись остановится сама, если останется меньше \(DiskSpace.format(DiskSpace.stopBelow)).")
        if free < DiskSpace.stopBelow {
            Log.error("Only \(DiskSpace.format(free)) free, stopping the recording to close the file safely")
            Notifier.shared.send(id: "meetrec-disk-stop", title: "Запись остановлена: диск заполнен",
                                 body: "Осталось \(DiskSpace.format(free)). Файл сохранён.")
            stop(reason: "на диске осталось \(DiskSpace.format(free))", showPanel: true)
        }
    }

    /// Remembers a title for the file name: the recorded window's, else an open Teams meeting's.
    private func updateMeetingTitle(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastTitleCheck) >= 15 else { return }
        lastTitleCheck = Date()
        let title = captureWindow.flatMap { MeetingTitle.title(ofWindow: $0.id) } ?? MeetingTitle.teamsMeeting()
        if let title, title != meetingTitle {
            Log.info("Recording title: \"\(title)\"")
            meetingTitle = title
        }
    }

    /// "2026-10-16 14-03-22.mov" → "Weekly sync 2026-10-16 14-03-22.mov"; keeps the old name on failure.
    private func renameWithTitle(_ file: URL, title: String) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let newStem = RecordingFiles.uniqueStem(RecordingFiles.sanitize(title) + " " + stem, in: file.deletingLastPathComponent(),
                                                ext: file.pathExtension)
        do {
            return try RecordingFiles.rename(file, to: newStem)
        } catch {
            Log.error("Could not rename recording to \"\(newStem)\": \(Log.describe(error))")
            return file
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

    /// The file being written right now; it must not be renamed or deleted.
    var recordingFile: URL? { isRecording ? recorder.currentFile().url : nil }

    /// Keeps "Последняя запись" pointing at a file renamed or deleted in the recordings list.
    func recordingMoved(from old: URL, to new: URL?) {
        if lastFile == old { lastFile = new }
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
        live.update(elapsed: 0)
        healthTracker = HealthTracker(startedAt: startedAt ?? Date(), microphoneOn: microphone, systemAudioOn: systemAudio,
                                      microphoneName: recordingNames.microphone, displayName: recordingNames.display)
        markers = []
        captureWindow = nil
        meetingTitle = nil
        live.update(load: nil)
        loadSampler = LoadSampler()
        _ = loadSampler.sample()
        lastLoadSample = Date()
        lastLoadLog = .distantPast
        highCPUSince = nil
        meetingWindowIgnored = false
        meetingWindowProblemSince = nil
        lastMeetingWindowCheck = Date() // give the meeting window time to open
        Notifier.shared.remove(id: "meetrec-not-recording")
        if let file = recorder.currentFile().url {
            Watchdog.recordingStarted(file: file, autoAppID: autoStartedAppID)
        }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "MeetRec is recording")
        Log.info("Sleep prevention on (system and display idle sleep disabled while recording)")
        lastDiskCheck = .distantPast
        lastTitleCheck = Date() // first look after 15 s, once a meeting window has its title
        freeSpace = DiskSpace.available(at: folderURL)
        scheduleTick()
    }

    /// Updates the timer and the live status panel; logs whenever a source changes state.
    private func scheduleTick() {
        timer?.invalidate()
        let interval = panelVisible ? 0.2 : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval / 5
    }

    private func tick() {
        guard let startedAt, var tracker = healthTracker else { return }
        live.update(elapsed: Date().timeIntervalSince(startedAt))
        let muted = microphone && InputMuteState.isMuted(uid: microphoneID.isEmpty ? nil : microphoneID)
        if muted != micMuted {
            micMuted = muted
            Log.info("Microphone \(muted ? "muted" : "unmuted") at system level", "health")
        }
        checkDiskSpace()
        checkCaptureWindow()
        checkMeetingWindow()
        sampleLoad()
        updateMeetingTitle()
        let newHealth = tracker.update(with: recorder.snapshot(), micMuted: muted, freeSpace: freeSpace)
        healthTracker = tracker
        if let old = health {
            logTransition(old.microphone, newHealth.microphone)
            logTransition(old.systemAudio, newHealth.systemAudio)
            logTransition(old.screen, newHealth.screen)
        }
        live.update(health: newHealth)
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
        alert("file-stalled", when: health.fileStalledFor >= HealthTracker.fileStalledAfter,
              title: "Файл записи перестал расти",
              body: "Данные не записываются уже \(Int(health.fileStalledFor)) с. Остановите и начните запись заново.")
        alert("screen-black", when: health.blackFor >= HealthTracker.blackAfter,
              title: "В записи чёрный экран",
              body: "Картинка полностью чёрная \(Int(health.blackFor)) с: экран заблокирован, монитор спит или выбран не тот монитор.")
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
        live.update(health: nil)
        timer = nil
        startedAt = nil
        recordingDisplayID = nil
        autoStartedBy = nil
        autoStartedAppID = nil
        captureWindow = nil
        Watchdog.recordingStopped()
        _ = idleLoadSampler.sample() // the next idle average starts now, without the recording
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            Log.info("Sleep prevention off")
        }
        sleepActivity = nil
        clearMeetingWindowProblem()
        windows = []
        if !markers.isEmpty { Log.info("Recording had \(markers.count) marker(s): " + markers.map(\.timeText).joined(separator: ", ")) }
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
        folderURL.appendingPathComponent(RecordingFiles.timestamp(Date())).appendingPathExtension("mov")
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
