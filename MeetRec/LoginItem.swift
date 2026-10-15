import ServiceManagement
import SwiftUI

/// "Запускать при входе": registers MeetRec as a login item, so meeting auto-recording works after a
/// restart without opening the app by hand.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false
    /// macOS registered the item but wants the user to allow it in System Settings → Login Items.
    @Published private(set) var needsApproval = false

    private init() {
        refresh()
        Log.info("Launch at login: \(describe(SMAppService.mainApp.status))")
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("Launch at login \(enabled ? "enabled" : "disabled"): \(describe(SMAppService.mainApp.status))")
        } catch {
            Log.error("Launch at login change to \(enabled) failed: \(Log.describe(error))")
        }
        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "off"
        case .requiresApproval: return "needs approval in System Settings"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}

struct LoginItemToggle: View {
    @ObservedObject private var item = LoginItem.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Запуск при входе", isOn: Binding(get: { item.isEnabled || item.needsApproval },
                                                                   set: { item.set($0) }))
                .help("Запускать MeetRec при входе в систему, чтобы автозапись встреч работала после перезагрузки")
            if item.needsApproval {
                Button("Разрешите MeetRec в настройках «Объекты входа»") { item.openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .onAppear { item.refresh() }
    }
}
