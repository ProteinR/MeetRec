import SwiftUI

/// The settings page's top level: recording (with its accordion), screenshots, shortcuts.
enum SettingsTab: String, CaseIterable, Identifiable {
    case recording, screenshots, shortcuts

    static let storageKey = "settingsTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: String(localized: "Запись")
        case .screenshots: String(localized: "Скриншоты")
        case .shortcuts: String(localized: "Клавиши")
        }
    }

    var icon: String {
        switch self {
        case .recording: "video.fill"
        case .screenshots: "camera.viewfinder"
        case .shortcuts: "keyboard"
        }
    }
}

/// Tabs drawn by SwiftUI, looking like a segmented control: the system one is glass on macOS 26,
/// like the switch and the slider that each took ~100 MB for a moment on their first draw.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.callout)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}
