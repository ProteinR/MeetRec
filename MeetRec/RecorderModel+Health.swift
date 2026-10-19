import AppKit
import AVFoundation

/// Watching a running recording: the timer tick, source health and its alerts, disk space, load.
extension RecorderModel {
    // MARK: - Load

    func sampleLoad() {
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

    func checkDiskSpace() {
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

    /// Updates the timer and the live status panel; logs whenever a source changes state.
    func scheduleTick() {
        timer?.invalidate()
        // Meters at ~3 updates a second look smooth enough and cost less than 5.
        let interval = panelVisible ? 0.33 : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = interval / 5
    }

    func tick() {
        guard let startedAt, var tracker = healthTracker else { return }
        live.update(elapsed: recordingTime(origin: startedAt))
        // On pause nothing is written, so there is nothing to watch but the disk and the reminders.
        if isPaused {
            checkDiskSpace()
            checkPauseReminders()
            return
        }
        let muted = microphone && InputMuteState.isMuted(uid: recordingMicUID)
        if muted != micMuted {
            micMuted = muted
            Log.info("Microphone \(muted ? "muted" : "unmuted") at system level", "health")
            recordMute(muted)
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

    /// Saves a mute change next to the recording, so the transcript can show when the user was muted.
    func recordMute(_ muted: Bool) {
        guard let startedAt, let file = recorder.currentFile().url else { return }
        let time = recordingTime(origin: startedAt)
        if muted {
            guard muteSpans.last.map({ $0.end != nil }) ?? true else { return }
            muteSpans.append(MuteSpan(start: time))
        } else {
            guard let last = muteSpans.indices.last, muteSpans[last].end == nil else { return }
            muteSpans[last].end = time
        }
        do {
            try MuteFile.save(muteSpans, for: file)
        } catch {
            Log.warning("Could not save microphone mutes: \(Log.describe(error))", "health")
        }
    }

    /// Notifies once per episode when a source dies or stays silent too long during a recording.
    func checkAlerts(_ health: RecordingHealth) {
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
    func alert(_ key: String, when condition: Bool, once: Bool = false, title: String, body: String) {
        if condition {
            guard !firedAlerts.contains(key) else { return }
            firedAlerts.insert(key)
            Log.warning("Alert: \(title)", "alerts")
            Notifier.shared.send(id: "meetrec-\(key)", title: title, body: body, silent: isRecording)
        } else if !once, firedAlerts.remove(key) != nil {
            Log.info("Alert cleared: \(key)", "alerts")
        }
    }

    func logTransition(_ old: SignalHealth, _ new: SignalHealth) {
        guard old.state != new.state else { return }
        let text = "\(new.title): \(old.state) → \(new.state) (\(new.detail))"
        if new.state == .noSignal || (new.title == "Микрофон" && new.state == .quiet) {
            Log.warning(text, "health")
        } else {
            Log.info(text, "health")
        }
    }
}
