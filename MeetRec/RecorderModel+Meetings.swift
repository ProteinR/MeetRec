import AppKit
import AVFoundation

/// Meetings and calls: what the detector reports, the countdowns before an automatic start and stop,
/// ask-first apps and browser rules, the meeting window on the recorded display, and the file title.
extension RecorderModel {
    // MARK: - Meeting window on the recorded display

    func ignoreMeetingWindow() { handleNotificationAction("ignore-window") }

    /// While a Teams meeting is recorded as a whole display, checks that its window is on that display.
    /// A wrong monitor (e.g. built-in instead of external) is otherwise noticed only afterwards.
    /// Only the first `meetingWindowCheckPeriod` of a recording decides: seen on the recorded display
    /// once → fine, checking stops (later the user may move Teams or share the screen, which minimises
    /// it). Seen on another monitor for `meetingWindowWarnAfter` → ⚠️ in the menu bar and a banner in
    /// the panel ("Записывать «…»" / "Игнорировать"), no notification and no switching by itself. The
    /// warning stays until answered, the display is switched, or the window comes onto the recorded
    /// display. A minimised or hidden window is not a problem.
    func checkMeetingWindow() {
        guard !meetingWindowSettled, Date().timeIntervalSince(lastMeetingWindowCheck) >= 1 else { return }
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
        let elsewhere = displays.first { display in
            display.id != displayID && windows.contains { Self.overlap($0.bounds, CGDisplayBounds(display.id)) >= 0.5 }
        }
        if meetingWindowWarning == nil {
            if let elsewhere {
                let since = meetingWindowProblemSince ?? Date()
                meetingWindowProblemSince = since
                if Date().timeIntervalSince(since) >= Self.meetingWindowWarnAfter {
                    let text = "Встреча Teams на мониторе «\(elsewhere.name)», а записывается «\(recordingNames.display)»."
                    meetingWindowWarning = text
                    meetingWindowDisplay = elsewhere
                    Log.warning("Alert: Teams meeting window is on display \(elsewhere.id) \(elsewhere.name), recording \(displayID)", "alerts")
                    return
                }
            } else {
                meetingWindowProblemSince = nil
            }
        } else if let elsewhere, elsewhere.id != meetingWindowDisplay?.id {
            // Moved on to a third monitor: offer that one.
            meetingWindowDisplay = elsewhere
            meetingWindowWarning = "Встреча Teams на мониторе «\(elsewhere.name)», а записывается «\(recordingNames.display)»."
        }
        // A shown warning waits for an answer; otherwise the check ends with the first seconds.
        if meetingWindowWarning == nil, Date().timeIntervalSince(startedAt) >= Self.meetingWindowCheckPeriod {
            meetingWindowSettled = true
            Log.info("Teams meeting window not seen on another monitor in the first \(Int(Self.meetingWindowCheckPeriod)) s; window check done", "health")
        }
    }

    func clearMeetingWindowProblem() {
        if meetingWindowWarning != nil {
            Log.info("Teams meeting window warning cleared", "health")
        }
        meetingWindowProblemSince = nil
        meetingWindowWarning = nil
        meetingWindowDisplay = nil
    }

    /// Share of `rect` that lies inside `area`.
    static func overlap(_ rect: CGRect, _ area: CGRect) -> CGFloat {
        let common = rect.intersection(area)
        guard !common.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return (common.width * common.height) / (rect.width * rect.height)
    }

    // MARK: - Ask-first calls (browser, Telegram)

    /// Browsers and Telegram hold the microphone for more than calls, so MeetRec asks instead of
    /// recording on its own. "Записать" starts a meeting recording that stops when the call ends.
    func askToRecord(_ app: MeetingApp) {
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

    func startRuleRecording(_ app: MeetingApp, rule: BrowserRule) {
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

    func pendingChanged(_ pending: (MeetingApp, Date)?) {
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

    func cancelCountdown() {
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

    func endingChanged(_ ending: (MeetingApp, Date)?) {
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

    func cancelStopCountdown() {
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
            Log.info("Browser auto-record rules: " + newValue.map { "\"\($0.keyword)\" → \"\($0.title)\"\($0.oneOther == true ? " (1:1)" : "")" }.joined(separator: "; "), "meetings")
        }
    }

    /// A rule whose text appears in the title of a browser window (its active tab).
    func matchingBrowserRule(for app: MeetingApp) -> BrowserRule? {
        let rules = browserRules.filter { !$0.keywords.isEmpty }
        guard !rules.isEmpty else { return nil }
        let titles = MeetingTitle.windows().filter { app.matches($0.bundleID) }.map(\.title)
        Log.debug("Browser window titles: " + titles.map { "\"\($0)\"" }.joined(separator: ", "), "meetings")
        return rules.first { rule in
            titles.contains(where: rule.matches)
        }
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
    func scheduleMeetingReminder(_ app: MeetingApp, after delay: TimeInterval) {
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

    func meetingStarted(_ app: MeetingApp) {
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

    func meetingEnded(_ app: MeetingApp) {
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
        // A call often drops the mic for a moment right at its start (a web lesson reconnecting): the
        // user said "Записать" and the call came back 20 s later, but a 15-second file was saved and
        // the same call was asked about again. A young recording waits for the app to come back.
        if let startedAt, case let age = Date().timeIntervalSince(startedAt), age < Self.youngRecording {
            let wait = Self.youngRecording - age
            Log.info("Meeting in \(app.name) ended \(Int(age)) s into the recording; waiting \(Int(wait)) s for it to come back", "meetings")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.isRecording, self.startedAt == startedAt, self.autoStartedAppID == app.id,
                      !self.autoStopDisabled else { return }
                guard self.detector.currentMeeting?.id != app.id else {
                    Log.info("\(app.name) took the microphone again; the recording goes on", "meetings")
                    return
                }
                Log.info("Auto-stopping recording: \(app.name) meeting did not come back", "meetings")
                self.stop(reason: app.asks ? "звонок в \(Self.callPlace(app)) завершился" : "встреча в \(Self.callPlace(app)) завершилась")
            }
            return
        }
        Log.info("Auto-stopping recording: \(app.name) meeting ended", "meetings")
        // The "Запись сохранена" toast makes the end obvious (see stop()).
        stop(reason: app.asks ? "звонок в \(Self.callPlace(app)) завершился" : "встреча в \(Self.callPlace(app)) завершилась")

    }

    /// The tab the call is in: the window matching a browser rule, else the frontmost browser window.
    func rememberCallTab(_ app: MeetingApp) {
        let windows = MeetingTitle.windows().filter { app.matches($0.bundleID) }
        let rules = browserRules
        let window = windows.first { window in rules.contains { $0.matches(window.title) } } ?? windows.first
        let key = window.map { MeetingTitle.tabKey($0.title) } ?? ""
        callTab = key.isEmpty ? nil : key
        Log.info("Call tab: \(callTab.map { "\"\($0)\"" } ?? "unknown")", "meetings")
    }

    func callTabOpen(_ app: MeetingApp) -> Bool {
        guard isRecording, autoStartedAppID == app.id, !autoStopDisabled, let callTab else { return false }
        return MeetingTitle.windows().contains { app.matches($0.bundleID) && MeetingTitle.tabKey($0.title) == callTab }
    }

    /// Remembers a title for the file name: an open Teams meeting's. Other windows (a browser tab,
    /// an app chosen for single-window capture) are not used: their titles are incidental and change.
    func updateMeetingTitle(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastTitleCheck) >= 15 else { return }
        lastTitleCheck = Date()
        let title = MeetingTitle.teamsMeeting()
        if let title, title != meetingTitle {
            Log.info("Recording title: \"\(title)\" (Teams windows: \(MeetingTitle.describeTeamsWindows()))")
            meetingTitle = title
        }
    }

    /// "2026-10-16 14-03-22.mov" → "2026-10-16 14-03-22 Weekly sync.mov"; keeps the old name on failure.
    func renameWithTitle(_ file: URL, title: String) -> URL {
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
}
