import AVFoundation

/// The microphone follows the call: which device to start with, switching when the call's device or
/// the system default changes, and the user's own choice.
extension RecorderModel {
    // MARK: - Microphone follows the call

    /// The microphone to start with: the chosen one, else the one the meeting app captures from
    /// (headphones put on just before answering), else the system default input.
    func startMicrophone(for app: MeetingApp?) -> String? {
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
    func checkMicrophoneSource() {
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
}
