import AppKit
import AVFoundation
import Carbon
import SwiftUI

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
    @AppStorage("browserAutoRules") var browserRulesJSON = ""
    /// Relaunch MeetRec after a crash and continue an interrupted recording (see `Watchdog`).
    @AppStorage("crashWatchdog") var crashWatchdog = true
    /// Per-app mode overrides, "telegram:auto,browser:ask"; missing apps use `MeetingApp.asks`.
    @AppStorage("meetingAppModes") var meetingAppModesRaw = ""
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
    /// Stop pressed, the file (and its chapters) is being finished: nothing recording-related works now.
    var isStopping: Bool { isRecording && isBusy }
    /// Timer, level meters and CPU: published separately so the panel does not redraw on every tick.
    let live = LiveRecording()
    var health: RecordingHealth? { live.health }
    /// Kept across launches, so "Последняя запись" in the menu and the panel survive a restart.
    @Published var lastFile: URL? = {
        guard let path = UserDefaults.standard.string(forKey: "lastRecording"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }() {
        didSet { UserDefaults.standard.set(lastFile?.path, forKey: "lastRecording") }
    }
    @Published var errorMessage: String?
    /// Detector state for the UI ("Жду встречу", "Идёт встреча в Teams"…); nil when detection is off.
    @Published var detectorStatus: String?
    /// A call noticed in an ask-first app (browser, Telegram), or a meeting going on unrecorded:
    /// the toast (and the panel) ask "Записать?".
    @Published var callPrompt: MeetingApp?
    /// The question is the "встреча идёт, а запись не ведётся" reminder.
    @Published var promptIsReminder = false
    /// A short message for a live moment (recording started / saved), shown by `ToastController`.
    @Published var toast: Toast?
    /// Name of the app whose meeting started the current recording; nil for manual recordings.
    @Published private(set) var autoStartedBy: String?
    /// `MeetingApp.id` behind `autoStartedBy`, for the file tag.
    var autoStartedAppID: String?
    /// Shown in the panel after a recording stops ("Запись сохранена · 34:12 · …") until the next start.
    @Published var stopNotice: String?
    /// Bumped to open the settings page (quick menu "Настройки…").
    @Published private(set) var settingsRequest = 0
    func requestSettings() { settingsRequest += 1 }

    /// Whether the menu panel is on screen; drives the microphone level preview and how often the
    /// recording status refreshes (5×/s for smooth meters while visible, once a second otherwise).
    @Published var panelVisible = false {
        didSet {
            if isRecording, panelVisible != oldValue { scheduleTick() }
            // A window choice is for a start from this opening of the panel only.
            if !panelVisible, !isRecording, !isBusy, chosenWindow != nil {
                chosenWindow = nil
                Log.debug("Window choice cleared (panel closed without starting)")
            }
        }
    }
    /// Moments marked in the current recording (⌃⌥⌘M or the button).
    @Published var markers: [Marker] = []
    /// The recording is on pause: nothing is written, the file is joined up afterwards (like OBS).
    @Published var isPaused = false
    var pausedSince: Date?
    /// Pauses before the current one, cut out of the file.
    var pausedTotal: TimeInterval = 0
    var pauseNoticeSent = false
    var pauseQuestionsSent = 0
    static let pauseNoticeAfter: TimeInterval = 600
    static let pauseQuestionEvery: TimeInterval = 1800
    /// The chapter / transcript line where a pause was cut.
    static let pauseNote = "Пауза"
    /// The single window being recorded instead of the whole display; nil = whole display.
    @Published var captureWindow: CaptureWindow?
    /// A window chosen in the panel for the next manual start only; cleared when the panel closes
    /// without starting and after that start. Automatic recordings always take the whole display.
    @Published var chosenWindow: CaptureWindow?
    /// Windows offered in the "what to record" menu while recording.
    @Published var windows: [CaptureWindow] = []
    /// Free space on the recordings volume, refreshed while recording.
    @Published var freeSpace: Int64?
    /// Set when the Teams meeting window is not on the recorded display (or hidden).
    @Published var meetingWindowWarning: String?
    /// The display showing the Teams meeting window, offered as "записывать этот монитор".
    @Published var meetingWindowDisplay: DisplayInfo?

    static let showPanelNotification = Notification.Name("MeetRecShowPanel")
    /// A stop began: the open panel fades out at once (nothing in it is useful any more), the toast
    /// tells the result.
    static let foldPanelNotification = Notification.Name("MeetRecFoldPanel")
    let detector = MeetingDetector()

    let recorder = ScreenRecorder()
    var startedAt: Date?
    var timer: Timer?
    var healthTracker: HealthTracker?
    /// Alerts already sent in the current episode; cleared when the condition recovers.
    var firedAlerts: Set<String> = []
    var micMuted = false
    static let micSilenceAlertAfter: TimeInterval = 60
    var recordingNames = (microphone: "", display: "")
    var lastDiskCheck = Date.distantPast
    var lastTitleCheck = Date.distantPast
    var lastWindowCheck = Date.distantPast
    /// Best title for the file name, found while recording (Teams meeting, or a browser rule).
    var meetingTitle: String?
    /// Title from a browser rule, applied when the recording it starts begins.
    var pendingTitle: String?
    /// The browser rule's title of the current recording ("Skyeng"), for the header badge.
    @Published private(set) var ruleTitle: String?
    /// The browser rule that started the current recording, to continue it after an interruption.
    var currentRuleID: String?

    /// "Teams", "Браузер" or the rule's "Skyeng" for an automatic recording; nil for a manual one.
    var autoBadge: String? {
        guard let app = autoStartedBy else { return nil }
        return ruleTitle ?? app.replacingOccurrences(of: "Microsoft ", with: "")
    }
    /// The browser rule that is starting a recording, tagged on its file.
    var pendingRuleID: String?
    /// The microphone being recorded right now (CoreAudio UID).
    @Published var recordingMicUID: String?
    /// Picked by hand during this recording: MeetRec no longer switches it by itself.
    var micOverridden = false
    /// A different microphone seen by the last check; switching needs it twice in a row.
    var micCandidate: String?
    var lastMicCheck = Date.distantPast
    /// Microphones already suggested in this recording (each at most once, so it never nags).
    var suggestedMics: Set<String> = []
    /// "Запись сохранена · 34:12" for the last stop, shown when the panel is not in view.
    var lastStopToast: Toast?
    var observers: [NSObjectProtocol] = []
    /// Keeps the Mac and its displays awake while recording.
    var sleepActivity: NSObjectProtocol?
    var lastMeetingWindowCheck = Date.distantPast
    var meetingWindowProblemSince: Date?
    /// The first seconds of a recording decide whether the meeting window is recorded; then no more checks.
    var meetingWindowSettled = false
    var meetingWindowElsewhere: DisplayInfo?
    static let meetingWindowCheckPeriod: TimeInterval = 30
    /// The user chose "Игнорировать" for the meeting window warning in this recording.
    var meetingWindowIgnored = false
    /// The meeting for which "встреча идёт, а запись не ведётся" was already shown.
    var remindedMeeting: String?
    var permissionTimer: Timer?
    var loadSampler = LoadSampler()
    var idleLoadSampler = LoadSampler()
    var idleLoadTimer: Timer?
    var lastLoadSample = Date.distantPast
    var lastLoadLog = Date.distantPast
    var highCPUSince: Date?
    static let highCPUPercent: Double = 90
    var permissionsMissing: Set<String> = []

    /// The pause shortcut, when one is set (none by default).
    var pauseHotKeyHint: String? { Shortcuts.shared.hint(.pause) }
    static var hotKeyHint: String? { Shortcuts.shared.hint(.record) }
    static var markerHotKeyHint: String? { Shortcuts.shared.hint(.marker) }

    /// The display being recorded (also while one window of it is recorded).
    @Published var recordingDisplayID: CGDirectDisplayID?

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
        detector.keepsMeeting = { [weak self] app in self?.callTabOpen(app) ?? false }
        configureDetector()
        recorder.onUnexpectedStop = { [weak self] error, file in
            self?.recordingInterrupted(error, file: file)
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

    @Published var countdown: Countdown?
    var countdownTimer: Timer?
    var countdownRule: BrowserRule?
    /// "Не записывать эту встречу": no automatic recording until this meeting ends.
    var skippedMeetingApp: String?

    var lastAutomaticRestart = Date.distantPast

    @Published var stopCountdown: StopCountdown?
    var stopCountdownTimer: Timer?
    /// "Продолжить запись": this recording no longer stops with the meeting.
    var autoStopDisabled = false

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
                recordedDisplayLost()
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
    static func isLoopback(_ device: AVCaptureDevice) -> Bool {
        device.uniqueID.hasPrefix("MSLoopbackDriverDevice") || device.localizedName == "Microsoft Teams Audio"
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    var selectedMeetingApps: Set<String> {
        Set(meetingAppsRaw.split(separator: ",").map(String.init))
    }

    // MARK: - Browser call tab

    /// The tab of a browser call being recorded (`MeetingTitle.tabKey`). While a browser window still
    /// shows it, the call goes on with the mic released: lessons mute the mic for minutes while
    /// listening to audio. Closing the tab (or switching away from it) ends the call as usual.
    var callTab: String?

    /// A meeting recording younger than this is not stopped as soon as the meeting ends.
    static let youngRecording: TimeInterval = 60

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
                    outputURL: nextFileURL(),
                    windowID: autoApp == nil && pendingRuleID == nil ? chosenWindow?.id : nil
                )
                let startWindow = options.windowID == nil ? nil : chosenWindow
                chosenWindow = nil
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
                currentRuleID = pendingRuleID
                if let ruleID = pendingRuleID {
                    RecordingTag.setRule(ruleID, on: options.outputURL)
                    pendingRuleID = nil
                }
                recordingDisplayID = display.id
                DisplayHighlight.shared.flash(displayID: display.id)
                autoStartedBy = autoApp?.name
                autoStartedAppID = autoApp?.id
                if let autoApp, autoApp.id == "browser" { rememberCallTab(autoApp) }
                didStart()
                if let startWindow {
                    captureWindow = startWindow
                    healthTracker?.displayName = "окно \(startWindow.appName)"
                    lastWindowCheck = Date()
                    updateMeetingTitle(force: true)
                    Log.info("Recording only window from the start: \(startWindow.label)")
                }
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
        if panelVisible { NotificationCenter.default.post(name: Self.foldPanelNotification, object: nil) }
        Log.info("Stopping after \(elapsedText)\(reason.map { " (\($0))" } ?? "")")
        if let meeting = detector.currentMeeting, reason == nil {
            // Stopped by hand while the meeting goes on: remind once in case it was a mistake.
            scheduleMeetingReminder(meeting, after: 60)
        }
        let duration = elapsedText
        let began = startedAt
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
            // Before anything else reads the file (transcription): markers become chapters and both
            // audio tracks get a mixed track that every player plays.
            let marked = markers
            if let recorded = file {
                do {
                    try await ChapterWriter.finish(recorded, markers: marked)
                } catch {
                    Log.warning("Recording not finished (chapters, mixed audio) for \(recorded.lastPathComponent): \(Log.describe(error)); the recording is unchanged", "recorder")
                }
            }
            isBusy = false
            didStop(file: file)
            // "14:03–14:25 · 22:10": when it was, so it is easy to tell which meeting this is.
            let span = began.map { "\($0.formatted(date: .omitted, time: .shortened))–\(Date().formatted(date: .omitted, time: .shortened)) · " } ?? ""
            stopNotice = ["Запись сохранена · \(span)\(duration)", reason].compactMap { $0 }.joined(separator: " · ")
            let transcriber = Transcriber.shared
            let transcriptNote = file != nil && transcriber.transcribeAfterRecording && transcriber.modelsState == .ready
                ? "транскрипт появится рядом с видео" : nil
            let detail = [reason, transcriptNote].compactMap { $0 }.joined(separator: " · ")
            lastStopToast = Toast(kind: .stopped, title: "Запись сохранена · \(duration)",
                                  detail: detail.isEmpty ? file?.lastPathComponent : detail.prefix(1).uppercased() + detail.dropFirst(),
                                  file: file)
            // The panel folded away when the stop began; if it was opened again since, the toast waits
            // until it closes (ToastController).
            showStopToast()
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

    func didStart() {
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
                                ?? [Self.hotKeyHint.map { "\($0) — остановить" }, Self.markerHotKeyHint.map { "\($0) — отметить момент" }]
                                    .compactMap { $0 }.joined(separator: ", ")))
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

    func didStop(file: URL?) {
        isRecording = false
        isPaused = false
        pausedSince = nil
        pausedTotal = 0
        clearPauseNotifications()
        timer?.invalidate()
        healthTracker = nil
        live.update(health: nil)
        timer = nil
        startedAt = nil
        recordingDisplayID = nil
        autoStartedBy = nil
        autoStartedAppID = nil
        callTab = nil
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

    static func logLaunch() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        Log.info("──────── MeetRec \(version) launched, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(String(cString: model)), log: \(Log.fileURL.path)")
        Log.debug("Teams windows: \(MeetingTitle.describeTeamsWindows())")
        Log.info("Permissions: screen=\(CGPreflightScreenCaptureAccess() ? "granted" : "not granted") microphone=\(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)))")
    }

    static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    func nextFileURL() -> URL {
        folderURL.appendingPathComponent(RecordingFiles.timestamp(Date())).appendingPathExtension("mov")
    }

}

