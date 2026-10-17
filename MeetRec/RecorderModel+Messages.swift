import AppKit
import AVFoundation

/// How MeetRec talks to the user: toasts for live moments and the buttons on its notifications.
extension RecorderModel {
    // MARK: - Notification buttons

    func handleNotificationAction(_ action: String) {
        if action == "pause-stop" {
            stop(reason: "остановлена на паузе")
        } else if action == "pause-resume" {
            resume()
        } else if action == "pause-keep" {
            Log.info("Pause kept after the reminder")
        } else if action == "ignore-window" {
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
}
