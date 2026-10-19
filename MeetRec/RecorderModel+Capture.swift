import AppKit
import AVFoundation

/// What is being captured mid-recording: another display, a single window, back to the whole display.
extension RecorderModel {
    /// Records another display from now on (same file, picture fitted into the same size).
    func switchDisplay(to displayID: CGDirectDisplayID) {
        guard isRecording, !isBusy else { return }
        Task {
            do {
                let name = try await recorder.setTarget(windowID: nil, displayID: displayID)
                recordingDisplayID = displayID
                DisplayHighlight.shared.flash(displayID: displayID)
                captureWindow = nil
                recordingNames.display = name
                healthTracker?.displayName = name
                // The user chose the monitor: no more meeting window checks in this recording.
                meetingWindowSettled = true
                clearMeetingWindowProblem()
                Log.info("Recording switched to display \(displayID) \"\(name)\"")
            } catch {
                errorMessage = "Не удалось переключить монитор: \(error.localizedDescription)"
                Log.error("Switching display failed: \(Log.describe(error))")
            }
        }
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
    func checkCaptureWindow() {
        guard let window = captureWindow, Date().timeIntervalSince(lastWindowCheck) >= 3 else { return }
        lastWindowCheck = Date()
        guard !MeetingTitle.exists(window.id) else { return }
        Log.warning("Recorded window \(window.id) (\(window.label)) is gone, switching back to the whole display")
        Notifier.shared.send(id: "meetrec-window-gone", title: "Окно закрыто",
                             body: "«\(window.label)» больше нет — записывается весь экран.")
        record(window: nil)
    }
}
