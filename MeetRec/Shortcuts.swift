import AppKit
import Carbon
import SwiftUI

/// A global shortcut as Carbon wants it, with the key's name for showing it ("⇧⌘4").
struct KeyCombo: Equatable {
    var keyCode: Int
    /// Carbon mask: `cmdKey | shiftKey`…
    var modifiers: Int
    var label: String

    /// In Apple's order: ⌃⌥⇧⌘.
    var text: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + label
    }

    /// For an NSMenuItem: its key equivalent and modifiers (empty when the key has no single character).
    var menuKey: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        return (label.count == 1 ? label.lowercased() : "", flags)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        return mask
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (Shift alone would eat ordinary typing).
    static func isUsable(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control]).isEmpty
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// "4", "S", "F5", "Space": what the key prints without modifiers, or its name.
    static func label(keyCode: Int, characters: String?) -> String {
        if let name = named[keyCode] { return name }
        let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? "#\(keyCode)" : text.uppercased()
    }
}


/// Everything a global shortcut can do. Recording and the marker keep their old keys; the pause has
/// none until one is set (the owner uses the buttons).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case record, marker, pause, screenshot, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return String(localized: "Начать / остановить запись")
        case .marker: return String(localized: "Отметить момент")
        case .pause: return String(localized: "Пауза")
        case .screenshot: return String(localized: "Скриншот")
        case .text: return "OCR"
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .record: return KeyCombo(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey | controlKey, label: "R")
        case .marker: return KeyCombo(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey | controlKey, label: "M")
        case .pause: return nil
        case .screenshot: return KeyCombo(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, label: "4")
        case .text: return KeyCombo(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey, label: "2")
        }
    }

    /// UserDefaults: "<prefix>HotKey" (on/off), "<prefix>KeyCode", "<prefix>KeyModifiers", "<prefix>KeyLabel".
    var prefix: String { rawValue }

    static let recording: [ShortcutAction] = [.record, .marker, .pause]
    static let screenshots: [ShortcutAction] = [.screenshot, .text]
}

/// The global shortcuts: what is set, registering them (Carbon, no Accessibility permission), and
/// which could not be registered because another app or macOS already has the keys.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    /// Could not be registered: another app (Shottr) or macOS has these keys.
    @Published private(set) var taken: Set<ShortcutAction> = []
    /// Settings wait for a new shortcut for this action; its old one is off meanwhile.
    @Published private(set) var recording: ShortcutAction?

    private var hotKeys: [ShortcutAction: HotKey] = [:]

    func start() {
        for action in ShortcutAction.allCases { register(action) }
    }

    func combo(_ action: ShortcutAction) -> KeyCombo? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: action.prefix + "KeyCode") != nil else { return action.defaultCombo }
        guard defaults.integer(forKey: action.prefix + "KeyCode") >= 0 else { return nil } // cleared
        return KeyCombo(keyCode: defaults.integer(forKey: action.prefix + "KeyCode"),
                        modifiers: defaults.integer(forKey: action.prefix + "KeyModifiers"),
                        label: defaults.string(forKey: action.prefix + "KeyLabel") ?? "")
    }

    /// "⇧⌘4" when set and on, else nil.
    func hint(_ action: ShortcutAction) -> String? {
        isEnabled(action) ? combo(action)?.text : nil
    }

    func isEnabled(_ action: ShortcutAction) -> Bool {
        (UserDefaults.standard.object(forKey: action.prefix + "HotKey") as? Bool ?? true) && combo(action) != nil
    }

    func setEnabled(_ action: ShortcutAction, _ enabled: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(enabled, forKey: action.prefix + "HotKey")
        register(action)
    }

    /// The other action already using `combo`, if any.
    func conflict(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && isEnabled($0) && self.combo($0) == combo }
    }

    func beginRecording(_ action: ShortcutAction) {
        if let other = recording { endRecording(other, nil) }
        recording = action
        hotKeys[action] = nil
    }

    /// nil: cancelled, the old shortcut comes back.
    func endRecording(_ action: ShortcutAction, _ combo: KeyCombo?) {
        recording = nil
        if let combo { set(action, combo) }
        register(action)
    }

    /// Back to the default; for the pause that means none.
    func reset(_ action: ShortcutAction) {
        if let combo = action.defaultCombo {
            set(action, combo)
        } else {
            objectWillChange.send()
            UserDefaults.standard.set(-1, forKey: action.prefix + "KeyCode")
            Log.info("\(action.rawValue) hotkey cleared", "shortcuts")
        }
        register(action)
    }

    private func set(_ action: ShortcutAction, _ combo: KeyCombo) {
        objectWillChange.send()
        let defaults = UserDefaults.standard
        defaults.set(combo.keyCode, forKey: action.prefix + "KeyCode")
        defaults.set(combo.modifiers, forKey: action.prefix + "KeyModifiers")
        defaults.set(combo.label, forKey: action.prefix + "KeyLabel")
        defaults.set(true, forKey: action.prefix + "HotKey")
        Log.info("\(action.rawValue) hotkey set to \(combo.text)", "shortcuts")
    }

    /// Also "Повторить" after the keys were freed in the other app.
    func register(_ action: ShortcutAction) {
        hotKeys[action] = nil
        taken.remove(action)
        guard isEnabled(action), let combo = combo(action) else { return }
        let key = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) {
            Log.info("Hotkey \(combo.text) pressed (\(action.rawValue))", "shortcuts")
            Task { @MainActor in Shortcuts.perform(action) }
        }
        if key.isRegistered {
            hotKeys[action] = key
            Log.info("\(action.rawValue) hotkey \(combo.text) registered", "shortcuts")
        } else {
            taken.insert(action)
            Log.warning("\(action.rawValue) hotkey \(combo.text) not registered (status \(key.status)): taken by another app or macOS", "shortcuts")
        }
    }

    static func perform(_ action: ShortcutAction) {
        let model = RecorderModel.shared
        switch action {
        case .record: model.toggle()
        case .marker: model.addMarker()
        case .pause: model.togglePause()
        case .screenshot, .text: Screenshotter.shared.capture(action)
        }
    }
}

/// A settings row: on/off, the shortcut (click to change), ↺ back to the default, and a warning with
/// "Повторить" when the keys are taken.
struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if shortcuts.combo(action) != nil {
                    Toggle(action.title, isOn: Binding(get: { shortcuts.isEnabled(action) },
                                                       set: { shortcuts.setEnabled(action, $0) }))
                } else {
                    Text(action.title)
                }
                Spacer(minLength: 4)
                HotKeyRecorder(action: action)
                if shortcuts.combo(action) != action.defaultCombo {
                    Button {
                        shortcuts.reset(action)
                    } label: {
                        Image(systemName: action.defaultCombo == nil ? "xmark.circle" : "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(action.defaultCombo.map { String(localized: "Вернуть \($0.text)") } ?? String(localized: "Убрать сочетание"))
                }
            }
            if shortcuts.taken.contains(action), let combo = shortcuts.combo(action) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("\(combo.text) занято другим приложением или macOS. Освободите его там или задайте другое и нажмите «Повторить».")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Повторить") { shortcuts.register(action) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Click, then press the new shortcut; Esc cancels. The current one is off while waiting, so pressing
/// it again keeps it.
private struct HotKeyRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var shortcuts = Shortcuts.shared
    @EnvironmentObject private var model: RecorderModel
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        Button {
            recording ? stop(nil) : start()
        } label: {
            Text(recording ? (hint ?? String(localized: "Нажмите сочетание…")) : (shortcuts.combo(action)?.text ?? String(localized: "Задать")))
                .font(.system(.callout, design: .rounded).weight(.medium))
                .frame(minWidth: 90)
        }
        .help(recording ? "Нажмите сочетание с ⌘, ⌥ или ⌃; Esc — отмена" : "Нажмите, чтобы задать сочетание")
        .onChange(of: model.panelVisible) { if !model.panelVisible { stop(nil) } }
        .onDisappear { stop(nil) }
    }

    private var recording: Bool { shortcuts.recording == action }

    private func start() {
        shortcuts.beginRecording(action)
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop(nil)
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard KeyCombo.isUsable(flags) else {
                hint = String(localized: "Нужен ⌘, ⌥ или ⌃")
                NSSound.beep()
                return nil
            }
            let keyCode = Int(event.keyCode)
            let combo = KeyCombo(keyCode: keyCode, modifiers: KeyCombo.carbonModifiers(flags),
                                 label: KeyCombo.label(keyCode: keyCode, characters: event.charactersIgnoringModifiers))
            if let other = shortcuts.conflict(combo, for: action) {
                hint = String(localized: "Уже у «\(other.title)»")
                NSSound.beep()
                return nil
            }
            stop(combo)
            return nil
        }
    }

    private func stop(_ combo: KeyCombo?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hint = nil
        if recording { shortcuts.endRecording(action, combo) }
    }
}
