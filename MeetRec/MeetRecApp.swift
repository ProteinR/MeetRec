import Combine
import Quartz
import SwiftUI

@main
struct MeetRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a menu bar panel (see AppDelegate); SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item and the dropdown panel. Clicking the item, or opening the app again from
/// Finder/Spotlight, shows the panel; clicking anywhere outside closes it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuPanelController!
    private var cancellables: Set<AnyCancellable> = []

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = RecorderModel.shared
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading

        panel = MenuPanelController(rootView: ContentView(close: { [weak self] in self?.panel.close() })
            .environmentObject(model)
            .environmentObject(Transcriber.shared))
        panel.onVisibilityChange = { visible in model.panelVisible = visible }

        Publishers.CombineLatest3(model.$isRecording, model.$elapsed, model.$health)
            .receive(on: RunLoop.main)
            .sink { [weak self] recording, _, health in
                self?.updateStatusItem(recording: recording, problem: health?.hasProblem == true)
            }
            .store(in: &cancellables)
        updateStatusItem(recording: false, problem: false)

        // Auto-recording opens the panel so it is obvious that recording started.
        NotificationCenter.default.publisher(for: RecorderModel.showPanelNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showPanel() }
            .store(in: &cancellables)

        // Opening the app shows the panel right away, so it is never "nothing happened".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.info("App reopened, showing panel")
        Task { @MainActor in self.showPanel() }
        return false
    }

    @MainActor
    private func updateStatusItem(recording: Bool, problem: Bool) {
        guard let button = statusItem.button else { return }
        let symbol = problem ? "exclamationmark.triangle.fill" : (recording ? "record.circle.fill" : "record.circle")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetRec")
        image?.isTemplate = !recording
        button.image = recording ? image?.withSymbolConfiguration(.init(paletteColors: [problem ? .systemYellow : .systemRed])) : image
        button.title = recording ? " " + RecorderModel.shared.elapsedText : ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    @objc @MainActor
    private func togglePanel() {
        if panel.isShown { panel.close() } else { showPanel() }
    }

    @MainActor
    func showPanel() {
        guard !panel.isShown else { return }
        if let button = statusItem.button, let window = button.window, Self.isOnScreen(window) {
            panel.show(below: window.frame)
        } else {
            Log.debug("Status item hidden (frame \(NSStringFromRect(statusItem.button?.window?.frame ?? .zero))), showing panel top right")
            panel.show(below: nil)
        }
    }

    // MARK: - Quick Look
    // The app delegate is the end of the responder chain, so it can own the shared preview panel.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPresenter.shared
            panel.delegate = QuickLookPresenter.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    /// Menu bar managers like Ice "hide" items by pushing them past the left edge of the screen, where
    /// they still count as visible windows. Only an item that lies entirely on a screen, to the right of
    /// the app menus, is a usable anchor.
    private static func isOnScreen(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.occlusionState.contains(.visible) else { return false }
        let frame = window.frame
        guard frame.width > 1, let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }) else { return false }
        return frame.minX > screen.frame.minX + screen.frame.width * 0.25
    }
}

struct ContentView: View {
    /// Closes the panel (Esc, ⌘W).
    let close: () -> Void

    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @StateObject private var micMonitor = MicrophoneMonitor()
    @State private var openSection: String?

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding(get: { openSection == section }, set: { openSection = $0 ? section : nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordButton
            Divider()
            if model.isRecording, let health = model.health {
                StatusPanel(health: health)
            } else {
                sources
            }
            TranscriptionStatus()
            // Accordion: one card open at a time keeps the panel within the screen height.
            VStack(spacing: 8) {
                if !model.isRecording {
                    CollapsibleSection(title: "Видео", icon: "video.fill", summary: videoSummary,
                                       isExpanded: expanded("video")) { videoSettings }
                    CollapsibleSection(title: "Транскрибация", icon: "text.bubble.fill", summary: transcriptionSummary,
                                       isExpanded: expanded("transcription")) { TranscriptionSettings() }
                    CollapsibleSection(title: "Автозапись встреч", icon: "person.2.wave.2.fill", summary: meetingSummary,
                                       isExpanded: expanded("meetings")) { MeetingSettings() }
                }
                RecordingsSection(isExpanded: expanded("recordings"))
            }
            Divider()
            folderRow
            if let notice = model.stopNotice, !model.isRecording {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notice.hasPrefix("Запись прервалась") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.hasPrefix("Запись прервалась") ? .orange : .green)
                    Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.stopNotice = nil } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            model.refreshDevices()
            transcriber.refreshModels()
        }
        .onExitCommand { close() }
        .background {
            // ⌘W closes the panel; the app has no menu bar menu to provide it.
            Button("", action: close).keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    private var header: some View {
        HStack {
            Text("MeetRec").font(.headline)
            Spacer()
            if let app = model.autoStartedBy, model.isRecording {
                Text("авто · \(app.replacingOccurrences(of: "Microsoft ", with: ""))")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
            }
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
                micPreview
            }
        }
        .disabled(model.isRecording)
        .onAppear(perform: updateMicPreview)
        .onChange(of: model.panelVisible) { updateMicPreview() }
        .onChange(of: model.microphone) { updateMicPreview() }
        .onChange(of: model.microphoneID) { updateMicPreview() }
        .onChange(of: model.isRecording) { updateMicPreview() }
    }

    /// Live level of the chosen microphone, so a silent or wrong device is obvious before recording.
    private var micPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.caption).foregroundStyle(.secondary)
                LevelMeter(levelDB: micMonitor.levelDB)
            }
            Text(micPreviewText)
                .font(.caption2)
                .foregroundStyle(micMonitor.receiving ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
    }

    private var micPreviewText: String {
        guard let name = micMonitor.deviceName else { return "Микрофон не найден" }
        if InputMuteState.isMuted(uid: model.microphoneID.isEmpty ? nil : model.microphoneID) {
            return "\(name): выключен кнопкой — в записи будет тишина"
        }
        if !micMonitor.receiving { return "\(name): сигнал не приходит" }
        return micMonitor.levelDB > -45 ? "\(name): слышно" : "\(name): скажите что-нибудь — полоска должна двигаться"
    }

    private func updateMicPreview() {
        if model.panelVisible, model.microphone, !model.isRecording {
            micMonitor.start(deviceID: model.microphoneID)
        } else {
            micMonitor.stop()
        }
    }

    private var meetingSummary: String {
        guard model.meetingDetection else { return "Выключена" }
        let names = MeetingApp.all.filter { $0.supported && model.selectedMeetingApps.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return "Не выбраны приложения" }
        return (model.detectorStatus ?? "Включена") + " · " + names.joined(separator: ", ")
    }

    private var videoSummary: String {
        let resolution = ResolutionPreset(rawValue: model.resolution)?.title ?? model.resolution
        return "\(model.fps) к/с · \(resolution) · \(model.codec == "hevc" ? "HEVC" : "H.264")"
    }

    private var transcriptionSummary: String {
        switch transcriber.modelsState {
        case .missing: return "Модели не скачаны"
        case .downloading: return "Скачивание моделей…"
        case .failed: return "Ошибка моделей"
        case .checking: return "Проверка…"
        case .ready:
            var parts = [transcriber.transcribeAfterRecording ? "После записи: вкл" : "После записи: выкл"]
            if transcriber.diarization { parts.append("по ролям") }
            parts.append(transcriber.language.isEmpty ? "язык авто" : transcriber.language)
            return parts.joined(separator: " · ")
        }
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
        .padding(.top, 4)
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
