import AppKit

/// Markers and the pause: both are times in the file, which leaves the paused stretches out.
extension RecorderModel {
    // MARK: - Markers

    /// Marks the current moment of the recording; it shows up in the transcript as "⭐ 12:34".
    func addMarker() {
        let current = recorder.currentFile()
        guard isRecording, !isStopping, let file = current.url else {
            Log.debug("Marker ignored: \(isStopping ? "stopping" : "not recording")")
            return
        }
        let origin = current.sessionStartedAt ?? startedAt ?? Date()
        let marker = Marker(time: recordingTime(origin: origin))
        markers.append(marker)
        do {
            try MarkerFile.save(markers, for: file)
            Log.info("Marker #\(markers.count) at \(marker.timeText)")
        } catch {
            Log.error("Could not save markers: \(Log.describe(error))")
        }
        NSSound(named: "Tink")?.play()
    }

    // MARK: - Pause

    /// Seconds of the file at `date`: wall time since `origin` without the pauses.
    func recordingTime(at date: Date = Date(), origin: Date) -> TimeInterval {
        let current = pausedSince.map { date.timeIntervalSince($0) } ?? 0
        return max(0, date.timeIntervalSince(origin) - pausedTotal - current)
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Nothing is written until `resume()`; a "Пауза" chapter marks where the file is joined up.
    func pause() {
        guard isRecording, !isStopping, !isPaused else { return }
        let now = Date()
        let current = recorder.currentFile()
        let origin = current.sessionStartedAt ?? startedAt ?? now
        let marker = Marker(time: recordingTime(at: now, origin: origin), note: Self.pauseNote)
        recorder.pause()
        isPaused = true
        pausedSince = now
        pauseNoticeSent = false
        pauseQuestionsSent = 0
        if let file = current.url {
            markers.append(marker)
            do {
                try MarkerFile.save(markers, for: file)
            } catch {
                Log.error("Could not save the pause marker: \(Log.describe(error))")
            }
        }
        Log.info("Recording paused at \(marker.timeText)")
    }

    func resume() {
        guard isRecording, isPaused, let since = pausedSince else { return }
        recorder.resume()
        let gap = Date().timeIntervalSince(since)
        pausedTotal += gap
        pausedSince = nil
        isPaused = false
        clearPauseNotifications()
        // The pause must not count as a dead microphone, a stalled file or a black screen.
        if let old = healthTracker {
            healthTracker = HealthTracker(startedAt: Date(), microphoneOn: old.microphoneOn, systemAudioOn: old.systemAudioOn,
                                          microphoneName: old.microphoneName, displayName: old.displayName)
        }
        Log.info("Recording resumed after a \(Int(gap)) s pause (\(Int(pausedTotal)) s cut in all)")
    }

    /// A forgotten pause: a quiet notice after 10 minutes, then every 30 a question with buttons.
    func checkPauseReminders() {
        guard isPaused, let since = pausedSince else { return }
        let paused = Date().timeIntervalSince(since)
        if !pauseNoticeSent, paused >= Self.pauseNoticeAfter {
            pauseNoticeSent = true
            Log.info("Pause reminder: \(Int(paused / 60)) min", "alerts")
            Notifier.shared.send(id: "meetrec-paused", title: "Запись на паузе \(Int(paused / 60)) минут",
                                 body: "Ничего не записывается. Нажмите, чтобы открыть MeetRec и снять с паузы.", silent: true)
        }
        let due = Int(paused / Self.pauseQuestionEvery)
        if due > pauseQuestionsSent {
            pauseQuestionsSent = due
            let minutes = Int(paused / 60)
            Log.info("Pause question: \(minutes) min", "alerts")
            Notifier.shared.remove(id: "meetrec-paused")
            Notifier.shared.send(id: "meetrec-pause-question", title: "Запись на паузе уже \(minutes) минут",
                                 body: "Сохранить её, продолжить запись или оставить на паузе?",
                                 actions: [Notifier.Action(id: "pause-stop", title: "Сохранить и остановить"),
                                           Notifier.Action(id: "pause-resume", title: "Снять с паузы"),
                                           Notifier.Action(id: "pause-keep", title: "Оставить на паузе")],
                                 silent: true)
        }
    }

    func clearPauseNotifications() {
        Notifier.shared.remove(id: "meetrec-paused")
        Notifier.shared.remove(id: "meetrec-pause-question")
    }
}
