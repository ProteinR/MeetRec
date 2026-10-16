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
    /// JSON of `browserRules`.
    @AppStorage("browserAutoRules") private var browserRulesJSON = ""
    /// Relaunch MeetRec after a crash and continue an interrupted recording (see `Watchdog`).
    @AppStorage("crashWatchdog") var crashWatchdog = true
    /// Per-app mode overrides, "telegram:auto,browser:ask"; missing apps use `MeetingApp.asks`.
    @AppStorage("meetingAppModes") private var meetingAppModesRaw = ""
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
    /// A call noticed in an ask-first app (browser, Telegram), or a meeting going on unrecorded:
    /// the toast (and the panel) ask "Записать?".
    @Published private(set) var callPrompt: MeetingApp?
    /// The question is the "встреча идёт, а запись не ведётся" reminder.
    @Published private(set) var promptIsReminder = false
    /// A short message for a live moment (recording started / saved), shown by `ToastController`.
    @Published private(set) var toast: Toast?
    /// Name of the app whose meeting started the current recording; nil for manual recordings.
    @Published private(set) var autoStartedBy: String?
    /// `MeetingApp.id` behind `autoStartedBy`, for the file tag.
    private var autoStartedAppID: String?
    /// Shown in the panel after a recording stops ("Запись сохранена · 34:12 · …") until the next start.
    @Published var stopNotice: String?
    /// Bumped to open the settings page (quick menu "Настройки…").
    @Published private(set) var settingsRequest = 0
    func requestSettings() { settingsRequest += 1 }

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
    private var recordingNames = (microphone: "", display: "")
    private var hotKey: HotKey?
    private var markerHotKey: HotKey?
    private var lastDiskCheck = Date.distantPast
    private var lastTitleCheck = Date.distantPast
    private var lastWindowCheck = Date.distantPast
    /// Best title for the file name, found while recording (Teams meeting, or a browser rule).
    private var meetingTitle: String?
    /// Title from a browser rule, applied when the recording it starts begins.
    private var pendingTitle: String?
    /// The browser rule's title of the current recording ("Skyeng"), for the header badge.
    @Published private(set) var ruleTitle: String?

    /// "Teams", "Браузер" or the rule's "Skyeng" for an automatic recording; nil for a manual one.
    var autoBadge: String? {
        guard let app = autoStartedBy else { return nil }
        return ruleTitle ?? app.replacingOccurrences(of: "Microsoft ", with: "")
    }
    /// The browser rule that is starting a recording, tagged on its file.
    private var pendingRuleID: String?
    /// The microphone being recorded right now (CoreAudio UID).
    @Published private(set) var recordingMicUID: String?
    /// Picked by hand during this recording: MeetRec no longer switches it by itself.
    private var micOverridden = false
    /// A different microphone seen by the last check; switching needs it twice in a row.
    private var micCandidate: String?
    private var lastMicCheck = Date.distantPast
    /// Microphones already suggested in this recording (each at most once, so it never nags).
    private var suggestedMics: Set<String> = []
    /// "Запись сохранена · 34:12" for the last stop, shown when the panel is not in view.
    private var lastStopToast: Toast?
    private var observers: [NSObjectProtocol] = []
    /// Keeps the Mac and its displays awake while recording.
    private var sleepActivity: NSObjectProtocol?
    private var lastMeetingWindowCheck = Date.distantPast
    private var meetingWindowProblemSince: Date?
    /// The first seconds of a recording decide whether the meeting window is recorded; then no more checks.
    private var meetingWindowSettled = false
    private var meetingWindowElsewhere: DisplayInfo?
    static let meetingWindowCheckPeriod: TimeInterval = 30
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
    private var permissionsMissing: Set<String> = []

    static let hotKeyHint = "⌃⌥⌘R"
    static let markerHotKeyHint = "⌃⌥⌘M"

    /// The display being recorded (also while one window of it is recorded).
    @Published private(set) var recordingDisplayID: CGDirectDisplayID?

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
        detector.onPending = { [weak self] pending in self?.pendingChanged(pending) }
        detector.onEnding = { [weak self] ending in self?.endingChanged(ending) }
        configureDetector()
        recorder.onUnexpectedStop = { [weak self] error in
            Log.error("Recording stopped unexpectedly: \(Log.describe(error))")
            self?.stopNotice = "Запись прервалась: \(error.localizedDescription)"
            Notifier.shared.send(id: "meetrec-stopped-unexpectedly", title: "Запись прервалась",
                                 body: "\(error.localizedDescription). Записанное до этого момента сохранено.")
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
        } else if action == "dismiss-call" {
            dismissCallPrompt()
        } else if action.hasPrefix("start-meeting:") {
            let app = MeetingApp.all.first { $0.id == String(action.dropFirst("start-meeting:".count)) }
            if callPrompt != nil {
                acceptCallPrompt()
            } else if !isRecording {
                start(autoApp: app)
            }
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
    /// Only the first `meetingWindowCheckPeriod` of a recording: is the Teams meeting window on the
    /// recorded display? Seen there once → fine, checking stops (later the user may move Teams or
    /// share the screen, which minimises it). Never seen there but on another monitor → one silent
    /// warning. A minimised or hidden window is not a problem.
    private func checkMeetingWindow() {
        guard !meetingWindowSettled, Date().timeIntervalSince(lastMeetingWindowCheck) >= 3 else { return }
        lastMeetingWindowCheck = Date()
        let teamsMeeting = autoStartedAppID == "teams" || detector.currentMeeting?.id == "teams"
        guard captureWindow == nil, !meetingWindowIgnored, teamsMeeting, let displayID = recordingDisplayID,
              let startedAt else { return }
        let windows = MeetingTitle.teamsMeetingWindows().filter(\.onScreen)
        let recorded = CGDisplayBounds(displayID)
        if windows.contains(where: { Self.overlap($0.bounds, recorded) >= 0.5 }) {
            Log.info("Teams meeting window is on the recorded display; window check done", "health")
            meetingWindowSettled = true
            clearMeetingWindowProblem()
            return
        }
        if let display = displays.first(where: { display in
            display.id != displayID && windows.contains { Self.overlap($0.bounds, CGDisplayBounds(display.id)) >= 0.5 }
        }) {
            meetingWindowElsewhere = display
        }
        guard Date().timeIntervalSince(startedAt) >= Self.meetingWindowCheckPeriod else { return }
        meetingWindowSettled = true
        guard let elsewhere = meetingWindowElsewhere else {
            Log.info("Teams meeting window not seen on any monitor in the first \(Int(Self.meetingWindowCheckPeriod)) s; not warning", "health")
            return
        }
        let text = "Окно встречи Teams на мониторе «\(elsewhere.name)», а записывается «\(recordingNames.display)»."
        meetingWindowWarning = text
        meetingWindowDisplay = elsewhere
        Log.warning("Alert: Teams meeting window is on display \(elsewhere.id) \(elsewhere.name), recording \(displayID)", "alerts")
        Notifier.shared.send(id: "meetrec-meeting-window", title: "Встреча не попадает в запись?", body: text,
                             actions: [.init(id: "switch-display:\(elsewhere.id)", title: "Записывать «\(elsewhere.name)»"),
                                       .init(id: "ignore-window", title: "Оставить как есть")],
                             silent: true)
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

    // MARK: - Ask-first calls (browser, Telegram)

    /// Browsers and Telegram hold the microphone for more than calls, so MeetRec asks instead of
    /// recording on its own. "Записать" starts a meeting recording that stops when the call ends.
    private func askToRecord(_ app: MeetingApp) {
        guard meetingDetection else {
            Log.info("Call in \(app.name) noticed; meeting detection is off, not asking", "meetings")
            return
        }
        guard !isRecording, !isBusy else {
            Log.info("Call in \(app.name) noticed, but a recording is already running", "meetings")
            return
        }
        if app.id == "browser", let rule = matchingBrowserRule(for: app) {
            Log.info("Browser call matches rule \"\(rule.keyword)\": recording without asking", "meetings")
            startRuleRecording(app, rule: rule)
            return
        }
        Log.info("Asking whether to record the call in \(app.name)", "meetings")
        promptIsReminder = false
        callPrompt = app
    }

    private func startRuleRecording(_ app: MeetingApp, rule: BrowserRule) {
        pendingTitle = rule.title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : RecordingFiles.sanitize(rule.title)
        pendingRuleID = rule.id.uuidString
        start(autoApp: app)
    }

    // MARK: - Countdown before an automatic recording

    /// The seconds between "the app took the microphone" and the automatic start, shown in grey next
    /// to the menu bar icon and in the panel, with "Записать сейчас" / "Не записывать".
    struct Countdown: Equatable {
        let app: MeetingApp
        let seconds: Int
        /// "встречу в Teams" / "Skyeng".
        let what: String
    }

    @Published private(set) var countdown: Countdown?
    private var countdownTimer: Timer?
    private var countdownRule: BrowserRule?
    /// "Не записывать эту встречу": no automatic recording until this meeting ends.
    private var skippedMeetingApp: String?

    private func pendingChanged(_ pending: (MeetingApp, Date)?) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
        countdownRule = nil
        guard let (app, since) = pending else { return }
        skippedMeetingApp = nil // a new call
        guard meetingDetection, !isRecording, !isBusy, MenuBarStyle.current != .discreet else { return }
        // Only calls that will record by themselves: Teams, and browser tabs with a rule.
        var what = "\(app.asks ? "звонок" : "встречу") в \(app.place)"
        if asks(app) {
            guard app.id == "browser", let rule = matchingBrowserRule(for: app) else { return }
            countdownRule = rule
            what = rule.title.isEmpty ? rule.keyword : rule.title
        }
        Log.info("Countdown to automatic recording of \(what): \(Int(app.startAfter)) s", "meetings")
        let update = { [weak self] in
            guard let self else { return }
            let left = Int((app.startAfter - Date().timeIntervalSince(since)).rounded(.up))
            let value = Countdown(app: app, seconds: max(left, 1), what: what)
            if value != self.countdown { self.countdown = value }
        }
        update()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in update() }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    /// "Записать сейчас": start without waiting for the end of the countdown.
    func recordNow() {
        guard let countdown, !isRecording else { return }
        let rule = countdownRule
        cancelCountdown()
        Log.info("User started the \(countdown.app.name) recording before the countdown ended", "meetings")
        if let rule {
            startRuleRecording(countdown.app, rule: rule)
        } else {
            start(autoApp: countdown.app)
        }
    }

    /// "Не записывать": this meeting is not recorded automatically (a manual start still works).
    func skipMeeting() {
        guard let countdown else { return }
        skippedMeetingApp = countdown.app.id
        cancelCountdown()
        Log.info("User chose not to record this \(countdown.app.name) meeting", "meetings")
    }

    // MARK: - Countdown before the automatic stop

    /// The seconds between "the meeting's app released the microphone" and the automatic stop.
    struct StopCountdown: Equatable {
        let app: MeetingApp
        let seconds: Int
    }

    @Published private(set) var stopCountdown: StopCountdown?
    private var stopCountdownTimer: Timer?
    /// "Продолжить запись": this recording no longer stops with the meeting.
    private var autoStopDisabled = false

    private func endingChanged(_ ending: (MeetingApp, Date)?) {
        cancelStopCountdown()
        guard let (app, since) = ending, isRecording, autoStartedBy != nil, !autoStopDisabled,
              MenuBarStyle.current != .discreet else { return }
        Log.info("Countdown to automatic stop (\(app.name) released the microphone): \(Int(MeetingDetector.endAfter)) s", "meetings")
        let update = { [weak self] in
            guard let self else { return }
            let left = Int((MeetingDetector.endAfter - Date().timeIntervalSince(since)).rounded(.up))
            let value = StopCountdown(app: app, seconds: max(left, 1))
            if value != self.stopCountdown { self.stopCountdown = value }
        }
        update()
        stopCountdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in update() }
        }
    }

    private func cancelStopCountdown() {
        stopCountdownTimer?.invalidate()
        stopCountdownTimer = nil
        if stopCountdown != nil { stopCountdown = nil }
    }

    /// "Остановить сейчас": do not wait for the end of the countdown.
    func stopNow() {
        guard let countdown = stopCountdown else { return }
        cancelStopCountdown()
        Log.info("User stopped the recording before the stop countdown ended", "meetings")
        stop(reason: "\(countdown.app.noun) в \(countdown.app.place) \(countdown.app.asks ? "завершился" : "завершилась")")
    }

    /// "Продолжить запись": keep recording after the meeting, like a manual recording.
    func keepRecording() {
        guard stopCountdown != nil else { return }
        cancelStopCountdown()
        autoStopDisabled = true
        Log.info("User chose to keep recording after the meeting", "meetings")
    }

    // MARK: - Browser rules ("record Skyeng without asking")

    var browserRules: [BrowserRule] {
        get { (try? JSONDecoder().decode([BrowserRule].self, from: Data(browserRulesJSON.utf8))) ?? [] }
        set {
            browserRulesJSON = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? "[]"
            Log.info("Browser auto-record rules: " + newValue.map { "\"\($0.keyword)\" → \"\($0.title)\"" }.joined(separator: "; "), "meetings")
        }
    }

    /// A rule whose text appears in the title of a browser window (its active tab).
    private func matchingBrowserRule(for app: MeetingApp) -> BrowserRule? {
        let rules = browserRules.filter { !$0.keyword.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rules.isEmpty else { return nil }
        let titles = MeetingTitle.windows().filter { app.matches($0.bundleID) }.map(\.title)
        Log.debug("Browser window titles: " + titles.map { "\"\($0)\"" }.joined(separator: ", "), "meetings")
        return rules.first { rule in
            titles.contains { $0.localizedCaseInsensitiveContains(rule.keyword.trimmingCharacters(in: .whitespaces)) }
        }
    }

    // MARK: - Microphone follows the call

    /// The microphone to start with: the chosen one, else the one the meeting app captures from
    /// (headphones put on just before answering), else the system default input.
    private func startMicrophone(for app: MeetingApp?) -> String? {
        if !microphoneID.isEmpty { return microphoneID }
        if let app, let used = AudioDevices.inputsUsed(by: app).first {
            Log.info("Starting with the microphone \(app.name) uses: \(AudioDevices.name(of: used)) (\(used))", "devices")
            return used
        }
        return AudioDevices.defaultInputUID()
    }

    /// Every few seconds: is the recording still capturing the microphone the call (or, without a
    /// call, the system) uses? In "По умолчанию" mode MeetRec switches by itself; with a microphone
    /// chosen by hand it only suggests the switch once.
    private func checkMicrophoneSource() {
        guard microphone, !isBusy, Date().timeIntervalSince(lastMicCheck) >= 3 else { return }
        lastMicCheck = Date()
        let app = MeetingApp.all.first { $0.id == autoStartedAppID } ?? detector.currentMeeting
        var target: String?
        var reason: String
        var callUses = false
        if let app, let used = AudioDevices.inputsUsed(by: app).first {
            target = used
            reason = "Как в \(app.place)"
            callUses = true
        } else {
            target = AudioDevices.defaultInputUID()
            reason = "Так выбрано в системе"
        }
        guard let target, target != recordingMicUID else {
            micCandidate = nil
            return
        }
        // Must be seen twice in a row: devices flap while headphones connect.
        guard micCandidate == target else {
            micCandidate = target
            return
        }
        micCandidate = nil
        let name = AudioDevices.name(of: target)
        if microphoneID.isEmpty && !micOverridden {
            Log.info("Microphone in use changed to \(name) (\(reason)); switching the recording", "devices")
            switchMicrophone(to: target, announce: Toast(kind: .info, title: "Микрофон: «\(name)»", detail: reason))
        } else if !suggestedMics.contains(target) {
            suggestedMics.insert(target)
            Log.info("Suggesting microphone \(name) (\(reason)); recording \(recordingNames.microphone)", "devices")
            showToast(Toast(kind: .info, title: "Записывать «\(name)»?",
                            detail: "\(callUses ? "Звонок использует" : "В системе выбран") «\(name)», а запись идёт с «\(recordingNames.microphone)».",
                            action: .switchMicrophone(uid: target)))
        }
    }

    /// Switches the running recording's microphone; `byUser` stops automatic switching for it.
    func switchMicrophone(to uid: String, byUser: Bool = false, announce: Toast? = nil) {
        guard isRecording, microphone else { return }
        if byUser { micOverridden = true }
        Task {
            do {
                try await recorder.setMicrophone(uid)
                recordingMicUID = uid
                let name = AudioDevices.name(of: uid)
                recordingNames.microphone = name
                healthTracker?.microphoneName = name
                firedAlerts.remove("mic-dead")
                firedAlerts.remove("mic-quiet")
                if let announce { showToast(announce) }
            } catch {
                errorMessage = "Не удалось переключить микрофон: \(error.localizedDescription)"
                Notifier.shared.send(id: "meetrec-mic-switch", title: "Микрофон не переключился",
                                     body: "Запись продолжается с «\(recordingNames.microphone)». \(error.localizedDescription)")
            }
        }
    }

    func performToastAction(_ action: Toast.Action) {
        dismissToast()
        switch action {
        case .switchMicrophone(let uid): switchMicrophone(to: uid, byUser: true)
        }
    }

    // MARK: - Toasts

    /// Live moments are shown by a small toast, not the panel, and not in the discreet style.
    func showToast(_ toast: Toast) {
        guard MenuBarStyle.current != .discreet else { return }
        self.toast = toast
    }

    func dismissToast() {
        if toast != nil { toast = nil }
    }

    /// Shows the result of the last stop (also used when the panel folds away after "Остановить").
    func showStopToast() {
        if let lastStopToast { showToast(lastStopToast) }
    }

    func acceptCallPrompt() {
        guard let app = callPrompt else { return }
        callPrompt = nil
        promptIsReminder = false
        Log.info("User chose to record the call in \(app.name)", "meetings")
        if !isRecording { start(autoApp: app) }
    }

    func dismissCallPrompt() {
        guard let app = callPrompt else { return }
        callPrompt = nil
        promptIsReminder = false
        remindedMeeting = app.id
        Log.info("User declined recording the call in \(app.name)", "meetings")
    }

    /// "в браузере" / "в Telegram".
    static func callPlace(_ app: MeetingApp) -> String { app.place }

    // MARK: - Meeting without recording

    /// Shows "встреча идёт, а запись не ведётся" once per meeting if, after `delay`, the meeting is
    /// still on and nothing records: auto-recording off, its start failed, or it was stopped by hand.
    private func scheduleMeetingReminder(_ app: MeetingApp, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isRecording, !self.isBusy, self.detector.currentMeeting?.id == app.id,
                  self.remindedMeeting != app.id else { return }
            self.remindedMeeting = app.id
            guard self.callPrompt == nil else { return }
            Log.warning("Meeting in \(app.name) is going on without a recording", "alerts")
            self.promptIsReminder = true
            self.callPrompt = app
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

    /// "Спрашивать" (true) or "Записывать" (false) for this app.
    func asks(_ app: MeetingApp) -> Bool {
        for pair in meetingAppModesRaw.split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, parts[0] == app.id { return parts[1] == "ask" }
        }
        return app.asks
    }

    func setAsks(_ app: MeetingApp, _ value: Bool) {
        var modes = Dictionary(uniqueKeysWithValues: meetingAppModesRaw.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: ":")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        })
        modes[app.id] = value ? "ask" : "auto"
        meetingAppModesRaw = modes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        Log.info("Meeting app \(app.name): \(value ? "ask before recording" : "record automatically")", "meetings")
        objectWillChange.send()
    }

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
        if skippedMeetingApp == app.id {
            Log.info("Meeting in \(app.name) started; the user chose not to record it", "meetings")
            return
        }
        if asks(app) {
            askToRecord(app)
            return
        }
        guard meetingDetection else {
            Log.info("Meeting in \(app.name) started; auto-recording is off, not reminding", "meetings")
            return
        }
        scheduleMeetingReminder(app, after: 30) // in case the start fails
        guard !isRecording, !isBusy else {
            Log.info("Meeting in \(app.name) started, but a recording is already running; leaving it as is", "meetings")
            return
        }
        Log.info("Auto-starting recording for \(app.name) meeting", "meetings")
        start(autoApp: app) // the "recording started" toast makes it obvious
    }

    private func meetingEnded(_ app: MeetingApp) {
        remindedMeeting = nil
        if skippedMeetingApp == app.id { skippedMeetingApp = nil }
        Notifier.shared.remove(id: "meetrec-not-recording")
        if callPrompt?.id == app.id {
            callPrompt = nil
            promptIsReminder = false
            Log.info("Call in \(app.name) ended before an answer to the prompt", "meetings")
        }
        guard isRecording else { return }
        guard autoStartedBy != nil else {
            Log.info("Meeting in \(app.name) ended; the recording was started manually, so it keeps running", "meetings")
            return
        }
        guard !autoStopDisabled else {
            Log.info("Meeting in \(app.name) ended; the user chose to keep recording", "meetings")
            return
        }
        Log.info("Auto-stopping recording: \(app.name) meeting ended", "meetings")
        // The "Запись сохранена" toast makes the end obvious (see stop()).
        stop(reason: app.asks ? "звонок в \(Self.callPlace(app)) завершился" : "встреча в \(Self.callPlace(app)) завершилась")

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
                    microphoneID: startMicrophone(for: autoApp),
                    outputURL: nextFileURL()
                )
                Log.info("Starting: display=\(display.id) \"\(display.name)\" (setting=\(displayID == Self.autoDisplay ? "auto" : String(displayID))) mic=\(microphones.first(where: { $0.id == microphoneID })?.name ?? "default: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")")
                recordingMicUID = startMicrophone(for: autoApp)
                micOverridden = false
                micCandidate = nil
                suggestedMics = []
                recordingNames = (microphone: AudioDevices.name(of: recordingMicUID), display: display.name)
                try await recorder.start(options)
                if let autoApp {
                    // Decided now, while it is known: transcription may run much later.
                    RecordingTag.setMeetingApp(autoApp.id, on: options.outputURL)
                }
                if let ruleID = pendingRuleID {
                    RecordingTag.setRule(ruleID, on: options.outputURL)
                    pendingRuleID = nil
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

    func stop(reason: String? = nil) {
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
            stopNotice = ["Запись сохранена · \(duration)", reason].compactMap { $0 }.joined(separator: " · ")
            let transcriber = Transcriber.shared
            let transcriptNote = file != nil && transcriber.transcribeAfterRecording && transcriber.modelsState == .ready
                ? "транскрипт появится рядом с видео" : nil
            let detail = [reason, transcriptNote].compactMap { $0 }.joined(separator: " · ")
            lastStopToast = Toast(kind: .stopped, title: "Запись сохранена · \(duration)",
                                  detail: detail.isEmpty ? file?.lastPathComponent : detail.prefix(1).uppercased() + detail.dropFirst(),
                                  file: file)
            // With the panel open the result is visible there (it shows the toast as it folds away).
            if !panelVisible { showStopToast() }
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
        // High CPU is only logged: the user cannot act on it mid-meeting, and frame drops show in the stats.
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
            stop(reason: "на диске осталось \(DiskSpace.format(free))")
        }
    }

    /// Remembers a title for the file name: an open Teams meeting's. Other windows (a browser tab,
    /// an app chosen for single-window capture) are not used: their titles are incidental and change.
    private func updateMeetingTitle(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastTitleCheck) >= 15 else { return }
        lastTitleCheck = Date()
        let title = MeetingTitle.teamsMeeting()
        if let title, title != meetingTitle {
            Log.info("Recording title: \"\(title)\"")
            meetingTitle = title
        }
    }

    /// "2026-10-16 14-03-22.mov" → "2026-10-16 14-03-22 Weekly sync.mov"; keeps the old name on failure.
    private func renameWithTitle(_ file: URL, title: String) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let newStem = RecordingFiles.uniqueStem(RecordingFiles.stem(timestamp: stem, title: RecordingFiles.sanitize(title)),
                                                in: file.deletingLastPathComponent(),
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
        cancelCountdown()
        cancelStopCountdown()
        autoStopDisabled = false
        markers = []
        captureWindow = nil
        meetingTitle = pendingTitle
        ruleTitle = pendingTitle
        pendingTitle = nil
        live.update(load: nil)
        loadSampler = LoadSampler()
        _ = loadSampler.sample()
        lastLoadSample = Date()
        lastLoadLog = .distantPast
        highCPUSince = nil
        meetingWindowIgnored = false
        meetingWindowProblemSince = nil
        meetingWindowSettled = false
        meetingWindowElsewhere = nil
        lastMeetingWindowCheck = Date() // give the meeting window time to open
        Notifier.shared.remove(id: "meetrec-not-recording")
        if callPrompt != nil {
            callPrompt = nil
            promptIsReminder = false
        }
        lastStopToast = nil
        if !panelVisible {
            let title: String
            let app = MeetingApp.all.first { $0.id == autoStartedAppID }
            if let ruleTitle = meetingTitle {
                title = "Записываю: \(ruleTitle)" // a browser rule, e.g. "Записываю: Skyeng"
            } else if let app {
                title = "Записываю \(app.asks ? "звонок" : "встречу") в \(app.place)"
            } else {
                title = "Запись началась"
            }
            showToast(Toast(kind: .started, title: title,
                            detail: app.map { "Остановится сама, когда \($0.noun) закончится" }
                                ?? "\(Self.hotKeyHint) — остановить, \(Self.markerHotKeyHint) — отметить момент"))
        }
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
        // Meters at ~3 updates a second look smooth enough and cost less than 5.
        let interval = panelVisible ? 0.33 : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval / 5
    }

    private func tick() {
        guard let startedAt, var tracker = healthTracker else { return }
        live.update(elapsed: Date().timeIntervalSince(startedAt))
        let muted = microphone && InputMuteState.isMuted(uid: recordingMicUID)
        if muted != micMuted {
            micMuted = muted
            Log.info("Microphone \(muted ? "muted" : "unmuted") at system level", "health")
        }
        checkDiskSpace()
        checkCaptureWindow()
        checkMeetingWindow()
        checkMicrophoneSource()
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
        // Dead silence for a minute (not just listening): likely the wrong microphone. Once per recording.
        alert("mic-quiet", when: microphone && health.microphone.state != .noSignal
                && health.micSilentFor >= Self.micSilenceAlertAfter, once: true,
              title: "С микрофона не идёт звук",
              body: "«\(mic)» молчит больше минуты, даже фонового шума нет. Возможно, выбран не тот микрофон.")
        alert("file-stalled", when: health.fileStalledFor >= HealthTracker.fileStalledAfter,
              title: "Файл записи перестал расти",
              body: "Данные не записываются уже \(Int(health.fileStalledFor)) с. Остановите и начните запись заново.")
        alert("screen-black", when: health.blackFor >= HealthTracker.blackAfter,
              title: "В записи чёрный экран",
              body: "Картинка полностью чёрная \(Int(health.blackFor)) с: экран заблокирован, монитор спит или выбран не тот монитор.")
        // Silence of the other side is normal while the user talks: shown in the panel, no alert.
    }

    /// One alert per problem episode (`once`: per recording), as a silent notification: during a
    /// meeting a sound would distract, and the banner itself is enough.
    private func alert(_ key: String, when condition: Bool, once: Bool = false, title: String, body: String) {
        if condition {
            guard !firedAlerts.contains(key) else { return }
            firedAlerts.insert(key)
            Log.warning("Alert: \(title)", "alerts")
            Notifier.shared.send(id: "meetrec-\(key)", title: title, body: body, silent: isRecording)
        } else if !once, firedAlerts.remove(key) != nil {
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
        ruleTitle = nil
        captureWindow = nil
        Watchdog.recordingStopped()
        cancelStopCountdown()
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

/// "If a browser tab titled like this has a call, record it without asking", e.g. "Vimbox" → "Skyeng".
struct BrowserRule: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Text looked for in browser window titles (the active tab), case-insensitive.
    var keyword: String
    /// Put into the file name after the timestamp; empty keeps just the date.
    var title: String
}
