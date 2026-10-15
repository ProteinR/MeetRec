import SwiftUI

/// How the menu bar item shows a running recording. "Незаметно" is for meetings where others see
/// the screen: the user still sees a filled icon, but nothing says "recording" or shows a timer.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case full, icon, discreet
    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Красный значок и таймер"
        case .icon: return "Только красный значок"
        case .discreet: return "Незаметно"
        }
    }

    var detail: String {
        switch self {
        case .full: return "Видно сразу, что идёт запись и сколько она длится."
        case .icon: return "Без таймера; красный кружок всё же заметен."
        case .discreet: return "Обычный серый значок, во время записи он закрашен. Таймера нет, панель сама не открывается при автозаписи."
        }
    }

    static let storageKey = "menuBarStyle"
    static let hideFromSharingKey = "hideFromScreenSharing"

    static var current: MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .full
    }

    static var hideFromSharing: Bool { UserDefaults.standard.bool(forKey: hideFromSharingKey) }
}

/// "Значок в меню": how a recording looks in the menu bar, and hiding MeetRec from screen sharing.
struct AppearanceSettings: View {
    @AppStorage(MenuBarStyle.storageKey) private var style = MenuBarStyle.full.rawValue
    @AppStorage(MenuBarStyle.hideFromSharingKey) private var hideFromSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Во время записи", selection: $style) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            Text((MenuBarStyle(rawValue: style) ?? .full).detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Прятать MeetRec при показе экрана", isOn: $hideFromSharing)
                .help("Значок и панель MeetRec не попадают в демонстрацию экрана (там, где приложение это учитывает)")
            Text("Значок и панель исключаются из захвата экрана. Работает не во всех приложениях — проверьте на тестовом звонке. Системные значки macOS (оранжевая точка микрофона, значок записи экрана) скрыть нельзя, но во время звонка с показом экрана они и так горят из-за Teams.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
