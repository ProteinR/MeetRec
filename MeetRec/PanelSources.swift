import SwiftUI

/// One of the three sources on the main page ("Микрофон", "Собеседники", "Экран"): the main part
/// switches the source on or off (or, for the screen, opens the choice), the optional chevron opens
/// its choices under the row. All three look the same, so the row reads at a glance.
struct SourceChip: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let isOpen: Bool
    var help: String = ""
    let action: () -> Void
    /// Opens the choices under the row; nil: no chevron.
    var menu: (() -> Void)?
    var menuHelp: String = ""

    @State private var hoverMain = false
    @State private var hoverMenu = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.caption.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, menu == nil ? 8 : 4)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(hoverMain ? 0.06 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverMain = $0 }
            .help(help)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            if let menu {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                Button(action: menu) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                        .background(Color.primary.opacity(hoverMenu ? 0.06 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverMenu = $0 }
                .help(menuHelp)
                .accessibilityLabel(menuHelp)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .foregroundStyle(isOn || isOpen ? .primary : .secondary)
        .background(RoundedRectangle(cornerRadius: 11).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(stroke))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .animation(.easeOut(duration: 0.12), value: hoverMain)
        .animation(.easeOut(duration: 0.12), value: hoverMenu)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    private var fill: Color {
        if isOpen { return Color.accentColor.opacity(0.24) }
        return isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)
    }

    private var stroke: Color {
        if isOpen { return Color.accentColor.opacity(0.9) }
        return isOn ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.1)
    }
}

/// A line under the start button saying what MeetRec does by itself: which calling apps it records
/// on its own and which it asks about. A click opens "Встречи и звонки" in the settings.
struct AutoRecordStatus: View {
    @EnvironmentObject private var model: RecorderModel
    @State private var installed: [MeetingApp] = []
    @State private var hovering = false

    var body: some View {
        // As `MeetingModeRow` sees it: asking works whenever the app is selected, recording by itself
        // also needs detection on.
        let selected = installed.filter { $0.supported && model.selectedMeetingApps.contains($0.id) }
        let auto = model.meetingDetection ? selected.filter { !model.asks($0) }.map(\.shortName) : []
        let ask = selected.filter { model.asks($0) }.map(\.shortName)
        let on = !auto.isEmpty || !ask.isEmpty
        Button {
            model.requestSettings(.meetings)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(on ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on ? String(localized: "Автозапись включена") : String(localized: "Автозапись выключена"))
                        .font(.caption.weight(.semibold))
                    Text(detail(on: on, auto: auto, ask: ask))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(on ? String(localized: "Изменить") : String(localized: "Включить"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill((on ? Color.green : Color.primary).opacity(hovering ? 0.13 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Какие встречи и звонки MeetRec записывает сам")
        .onAppear { installed = MeetingApp.all.filter(\.isInstalled) }
        .onChange(of: model.panelVisible) { if model.panelVisible { installed = MeetingApp.all.filter(\.isInstalled) } }
    }

    private func detail(on: Bool, auto: [String], ask: [String]) -> String {
        guard on else { return String(localized: "Встречи записываются только вручную") }
        var parts: [String] = []
        if !auto.isEmpty { parts.append(String(localized: "Сам запишу: \(auto.formatted(.list(type: .and))).")) }
        if !ask.isEmpty { parts.append(String(localized: "Спрошу: \(ask.formatted(.list(type: .and))).")) }
        return parts.joined(separator: " ")
    }
}

/// "Записи | Скриншоты" on the main page. The tab last chosen is remembered, so someone who only
/// takes screenshots always comes back to them.
enum PanelTab: String, CaseIterable, Identifiable {
    case recordings, screenshots

    static let storageKey = "panelTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: String(localized: "Записи")
        case .screenshots: String(localized: "Скриншоты")
        }
    }
}

/// Drawn by SwiftUI (the system segmented control is costly glass on macOS 26),
/// with each tab's count in grey.
struct PanelTabBar: View {
    @Binding var selection: PanelTab
    let counts: [PanelTab: String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.2)) { selection = tab }
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.title).fontWeight(.semibold)
                        if let count = counts[tab] {
                            Text(count).monospacedDigit().foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(selection == tab ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 7)
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
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
    }
}

extension MeetingApp {
    /// For the short line on the main page: "Teams", not "Microsoft Teams".
    var shortName: String {
        switch id {
        case "teams": "Teams"
        case "browser": name.lowercased()
        default: name
        }
    }
}
