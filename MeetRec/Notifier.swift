import Foundation
import UserNotifications

/// macOS notifications for recording problems. Clicking one opens the MeetRec panel.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.info("Notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \(Log.describe($0))" } ?? "")", "alerts")
        }
    }

    func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Same id replaces a previous notification of the same kind instead of stacking them.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.error("Notification failed: \(Log.describe(error))", "alerts") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while MeetRec is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RecorderModel.showPanelNotification, object: nil)
        }
        completionHandler()
    }
}
