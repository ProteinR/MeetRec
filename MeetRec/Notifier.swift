import Foundation
import UserNotifications

/// macOS notifications for recording problems. Clicking one opens the MeetRec panel; buttons on a
/// notification (see `Action`) are handled by `RecorderModel`.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// A button on a notification. `id` comes back through `actionNotification`.
    struct Action {
        let id: String
        let title: String
    }

    /// Posted on the main queue when a notification button is pressed; `userInfo["action"]` is its id.
    static let actionNotification = Notification.Name("MeetRecNotificationAction")

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private let lock = NSLock()
    private var categories: [String: UNNotificationCategory] = [:]

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.info("Notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \(Log.describe($0))" } ?? "")", "alerts")
        }
    }

    func send(id: String, title: String, body: String, actions: [Action] = []) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if !actions.isEmpty {
            // One category per notification id, so its buttons can change (e.g. the display name).
            let category = UNNotificationCategory(
                identifier: id,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) },
                intentIdentifiers: [])
            lock.lock()
            categories[id] = category
            let all = Set(categories.values)
            lock.unlock()
            center.setNotificationCategories(all)
            content.categoryIdentifier = id
        }
        // Same id replaces a previous notification of the same kind instead of stacking them.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.error("Notification failed: \(Log.describe(error))", "alerts") }
        }
    }

    func remove(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while MeetRec is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if action == UNNotificationDefaultActionIdentifier || action == UNNotificationDismissActionIdentifier {
                NotificationCenter.default.post(name: RecorderModel.showPanelNotification, object: nil)
            } else {
                Log.info("Notification button pressed: \(action)", "alerts")
                NotificationCenter.default.post(name: Self.actionNotification, object: nil, userInfo: ["action": action])
            }
        }
        completionHandler()
    }
}
