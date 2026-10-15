import SwiftUI

@main
struct MeetRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(isMenuBarPanel: true)
                .environmentObject(model)
        } label: {
            if model.isRecording {
                Image(systemName: model.health?.hasProblem == true ? "exclamationmark.triangle.fill" : "record.circle.fill")
                Text(model.elapsedText)
            } else {
                Image(systemName: "record.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shows the same panel as a normal window on launch and whenever the app is opened again
/// (Finder, Spotlight, Dock), so MeetRec is reachable even when its menu bar icon is hidden by a
/// menu bar manager or the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.info("App reopened, showing window")
        showWindow()
        return true
    }

    @MainActor
    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView(isMenuBarPanel: false).environmentObject(RecorderModel.shared))
            // Let the hosting controller size the window. Forcing a content rect or
            // `sizingOptions = .preferredContentSize` sends AppKit into a constraint-update loop that
            // crashes on launch (NSGenericException in _postWindowNeedsUpdateConstraints).
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "MeetRec"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ContentView: View {
    /// The menu bar panel closes itself after Start/Stop; the regular window stays open.
    let isMenuBarPanel: Bool

    @EnvironmentObject private var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var showVideoSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordButton
            Divider()
            if model.isRecording, let health = model.health {
                StatusPanel(health: health)
            } else {
                sources
                DisclosureGroup("Видео", isExpanded: $showVideoSettings) { videoSettings }
            }
            Divider()
            folderRow
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshDevices() }
        .onExitCommand { close() }
        .background {
            // ⌘W closes the panel or window; the app has no menu bar menu to provide it.
            Button("", action: close).keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    private func close() {
        if isMenuBarPanel {
            dismiss()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    private var header: some View {
        HStack {
            Text("MeetRec").font(.headline)
            Spacer()
            if model.isRecording {
                Label(model.elapsedText, systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
        }
    }

    private var recordButton: some View {
        Button {
            model.toggle()
            if isMenuBarPanel { dismiss() }
        } label: {
            HStack {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Остановить запись" : "Начать запись")
                Spacer()
                Text(RecorderModel.hotKeyHint).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        // Stop stays as visible as Start: a grey button read as "disabled".
        .tint(model.isRecording ? Color(red: 0.75, green: 0.1, blue: 0.1) : .red)
        .controlSize(.large)
        .disabled(model.isBusy)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Монитор", selection: $model.displayID) {
                Text(autoDisplayTitle).tag(RecorderModel.autoDisplay)
                ForEach(model.displays) { display in
                    Text(display.name).tag(Int(display.id))
                }
            }
            Toggle("Звук системы", isOn: $model.systemAudio)
            Toggle("Микрофон", isOn: $model.microphone)
            if model.microphone {
                Picker("Устройство", selection: $model.microphoneID) {
                    Text("Системный по умолчанию").tag("")
                    ForEach(model.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
            }
        }
        .disabled(model.isRecording)
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Кадров/с", selection: $model.fps) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Разрешение", selection: $model.resolution) {
                ForEach(ResolutionPreset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Кодек", selection: $model.codec) {
                Text("H.264 (совместимость)").tag("h264")
                Text("HEVC (меньше файлы)").tag("hevc")
            }
        }
        .padding(.top, 6)
        .disabled(model.isRecording)
    }

    private var folderRow: some View {
        HStack {
            Image(systemName: "folder")
            Text(model.folderURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.folderPath)
            Spacer()
            Button("Изменить") { model.chooseFolder() }
                .disabled(model.isRecording)
            Button("Открыть") { model.openFolder() }
        }
    }

    private var footer: some View {
        HStack {
            if model.lastFile != nil {
                Button("Последняя запись") { model.revealLastFile() }
            }
            Button("Лог") { model.openLog() }
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
                .disabled(model.isRecording)
        }
        .buttonStyle(.borderless)
    }

    private var autoDisplayTitle: String {
        if let display = model.effectiveDisplay {
            return "Авто (\(display.name))"
        }
        return "Авто"
    }
}

/// Live "is everything being recorded?" panel shown while recording.
struct StatusPanel: View {
    let health: RecordingHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Статус записи").font(.subheadline.weight(.semibold))
            StatusRow(icon: "mic.fill", signal: health.microphone)
            StatusRow(icon: "speaker.wave.2.fill", signal: health.systemAudio)
            StatusRow(icon: "display", signal: health.screen)
            StatusRow(icon: "internaldrive", signal: health.file)
            if health.hasProblem {
                Text("Один из источников не передаёт сигнал. Проверьте устройство или остановите и начните запись заново.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusRow: View {
    let icon: String
    let signal: SignalHealth

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(signal.title).font(.callout)
                    Spacer()
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(signal.detail)
                    .font(.caption)
                    .foregroundStyle(signal.state == .noSignal ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let level = signal.levelDB {
                    LevelMeter(levelDB: level)
                }
            }
        }
    }

    private var color: Color {
        switch signal.state {
        case .ok: return .green
        case .quiet: return signal.title == "Микрофон" ? .yellow : .gray
        case .noSignal: return .red
        case .off: return .gray.opacity(0.4)
        }
    }
}

/// Horizontal level bar from -60 dBFS to 0 dBFS.
struct LevelMeter: View {
    let levelDB: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, (levelDB + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(levelDB > -6 ? Color.red : levelDB > -20 ? Color.yellow : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.15), value: levelDB)
    }
}
