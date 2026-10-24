import SwiftUI

/// How the menu bar item shows a running recording. "Незаметно" is for meetings where others see
/// the screen: the user still sees a filled icon, but nothing says "recording" or shows a timer.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case full, icon, discreet
    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return String(localized: "Красный значок и таймер")
        case .icon: return String(localized: "Только красный значок")
        case .discreet: return String(localized: "Незаметно")
        }
    }

    var detail: String {
        switch self {
        case .full: return String(localized: "Видно сразу, что идёт запись и сколько она длится.")
        case .icon: return String(localized: "Без таймера; красный кружок всё же заметен.")
        case .discreet: return String(localized: "Обычный серый значок, во время записи он закрашен. Таймера нет, окошки о начале и конце записи и вопрос о звонке не показываются.")
        }
    }

    static let storageKey = "menuBarStyle"
    static let hideFromSharingKey = "hideFromScreenSharing"

    static var current: MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .full
    }

    /// On by default: nothing of MeetRec should show up in a screen share unless asked for.
    static var hideFromSharing: Bool { UserDefaults.standard.object(forKey: hideFromSharingKey) as? Bool ?? true }
}

/// "Вид во время записи": how a recording looks in the menu bar, and hiding MeetRec from screen sharing.
struct AppearanceSettings: View {
    @AppStorage(MenuBarStyle.storageKey) private var style = MenuBarStyle.full.rawValue
    @AppStorage(MenuBarStyle.hideFromSharingKey) private var hideFromSharing = true
    @AppStorage(IslandController.enabledKey) private var island = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Во время записи", selection: $style) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            MenuBarPreview(style: MenuBarStyle(rawValue: style) ?? .full,
                           island: island && style != MenuBarStyle.discreet.rawValue)
            Text((MenuBarStyle(rawValue: style) ?? .full).detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Остров у выреза экрана во время записи (если у экрана есть вырез)", isOn: $island)
                .disabled(style == MenuBarStyle.discreet.rawValue)
                .help("Красная точка и таймер вокруг выреза MacBook; при наведении — уровни звука, отметка и стоп. В режиме «Незаметно» не показывается.")
            Toggle("Прятать MeetRec при показе экрана", isOn: $hideFromSharing)
                .help("Значок и панель MeetRec не попадают в демонстрацию экрана (там, где приложение это учитывает)")
            Text("Значок, панель и остров исключаются из захвата экрана. Работает не во всех приложениях — проверьте на тестовом звонке. Системные значки macOS (оранжевая точка микрофона, значок записи экрана) скрыть нельзя, но во время звонка с показом экрана они и так горят из-за Teams.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// A mock menu bar showing how MeetRec looks without and with a recording in the chosen style.
struct MenuBarPreview: View {
    let style: MenuBarStyle
    let island: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Без записи", recording: false)
            row("Идёт запись", recording: true)
            if island {
                HStack(spacing: 8) {
                    Text("Остров").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 7, height: 7).shadow(color: .red.opacity(0.8), radius: 3)
                        Spacer(minLength: 0)
                        Text("12:34").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 150, height: 20)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(Color.black))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .animation(.easeInOut(duration: 0.2), value: style)
    }

    private func row(_ label: LocalizedStringKey, recording: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            HStack(spacing: 10) {
                // Neighbouring menu bar items, for scale.
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                item(recording: recording)
                Text("Пт 9:41")
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func item(recording: Bool) -> some View {
        if !recording {
            Image(systemName: "record.circle")
        } else {
            switch style {
            case .full:
                HStack(spacing: 3) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("12:34").monospacedDigit()
                }
            case .icon:
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            case .discreet:
                Image(systemName: "record.circle.fill")
            }
        }
    }
}
