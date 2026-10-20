import AppKit
import AVFoundation

/// Things going wrong around a recording: a crash (the watchdog relaunched MeetRec), the recorded monitor
/// unplugged, capture stopping by itself, missing permissions.
extension RecorderModel {
    // MARK: - Crash recovery

    func setCrashWatchdog(_ enabled: Bool) {
        crashWatchdog = enabled
        Watchdog.setAgent(enabled: enabled)
    }

    /// The previous run died while recording: report the saved file, transcribe it, and continue.
    /// A manual recording restarts in a new file right away; a meeting recording is restarted by the
    /// detector if the meeting is still going (so it also stops when the meeting ends).
    func recoverInterrupted(_ state: Watchdog.InterruptedRecording) {
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
    func checkPermissions() {
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

    // MARK: - Monitor unplugged, capture stopped

    /// The recorded monitor went away (unplugged, lid closed): keep recording the screen that is left,
    /// in the same file. Its picture is fitted into the recording's size, never cropped.
    func recordedDisplayLost() {
        guard let fallback = effectiveDisplay else {
            Log.error("Recorded display is gone and no other display is available", "devices")
            return
        }
        Log.warning("Switching the recording to display \(fallback.id) \(fallback.name)", "devices")
        switchDisplay(to: fallback.id)
        showToast(Toast(kind: .info, title: "Монитор отключён", detail: "Запись продолжается: «\(fallback.name)»"))
    }

    /// Capture stopped on its own (e.g. the monitor vanished before the switch). The part recorded so
    /// far is saved and transcribed; a new recording continues on the screen that is available, as the
    /// same kind (an automatic meeting recording still stops when the meeting ends). At most once in
    /// two minutes, so a persistent failure does not loop.
    func recordingInterrupted(_ error: Error, file: URL?) {
        Log.error("Recording stopped unexpectedly: \(Log.describe(error)); saved part: \(file?.lastPathComponent ?? "none")")
        let app = MeetingApp.all.first { $0.id == autoStartedAppID }
        let rule = ruleTitle
        let ruleID = currentRuleID
        let wasAuto = autoStartedBy != nil && !autoStopDisabled
        didStop(file: file)
        // A meeting recording whose meeting is over or ending (the app released the mic) is not
        // continued: it would only be stopped again a few seconds later.
        if wasAuto, let app, detector.currentMeeting?.id != app.id || detector.isEnding {
            Log.info("\(app.name) meeting is ending: not continuing the recording", "recorder")
            return
        }
        let restart = Date().timeIntervalSince(lastAutomaticRestart) > 120 && effectiveDisplay != nil
        if restart {
            lastAutomaticRestart = Date()
            Log.warning("Continuing in a new recording after the interruption", "recorder")
            pendingTitle = rule
            pendingRuleID = ruleID
            start(autoApp: wasAuto ? app : nil)
            stopNotice = nil
            Notifier.shared.send(id: "meetrec-stopped-unexpectedly", title: "Запись прервалась и продолжена",
                                 body: "\(error.localizedDescription). Записанное сохранено, запись продолжается в новом файле.",
                                 silent: true)
        } else {
            stopNotice = "Запись прервалась: \(error.localizedDescription)"
            errorMessage = "Запись остановлена: \(error.localizedDescription)"
            Notifier.shared.send(id: "meetrec-stopped-unexpectedly", title: "Запись прервалась",
                                 body: "\(error.localizedDescription). Записанное до этого момента сохранено.")
        }
    }

    func ensurePermissions() async -> Bool {
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
