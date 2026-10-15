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
    private var statusIconKey = ""

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = RecorderModel.shared
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading

        panel = MenuPanelController(rootView: ContentView(close: { [weak self] in self?.panel.close() })
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(Transcriber.shared))
        panel.onVisibilityChange = { visible in model.panelVisible = visible }

        // Only when something visible changes: the second, recording on/off, problem on/off.
        Publishers.CombineLatest3(model.$isRecording, model.live.$elapsed,
                                  model.live.$health.map { $0?.hasProblem == true }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] recording, _, problem in
                self?.updateStatusItem(recording: recording, problem: problem)
            }
            .store(in: &cancellables)
        updateStatusItem(recording: false, problem: false)

        // Menu bar style or "hide from screen sharing" changed in the panel.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem(recording: model.isRecording, problem: model.health?.hasProblem == true)
            }
            .store(in: &cancellables)

        // Auto-recording opens the panel so it is obvious that recording started.
        NotificationCenter.default.publisher(for: RecorderModel.showPanelNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showPanel() }
            .store(in: &cancellables)

        // Opening the app shows the panel right away, so it is never "nothing happened".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
    }

    /// Quitting while recording (logout, shutdown, `install.sh`) first closes the file properly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = RecorderModel.shared
            guard model.isRecording || model.isBusy else { return .terminateNow }
            Log.warning("Quit requested while recording: finishing the file first")
            model.stop(reason: "выход из MeetRec")
            Task { @MainActor in
                for _ in 0..<100 where model.isRecording || model.isBusy {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.info("App reopened, showing panel")
        Task { @MainActor in self.showPanel() }
        return false
    }

    @MainActor
    private func updateStatusItem(recording: Bool, problem: Bool) {
        guard let button = statusItem.button else { return }
        let style = MenuBarStyle.current
        // Discreet: a plain monochrome icon like any menu bar app; filled while recording.
        let colored = recording && style != .discreet
        let symbol = problem ? (colored ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            : (recording ? "record.circle.fill" : "record.circle")
        let iconKey = "\(symbol) \(colored) \(problem)"
        if iconKey != statusIconKey {
            statusIconKey = iconKey
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetRec")
            image?.isTemplate = !colored
            button.image = colored ? image?.withSymbolConfiguration(.init(paletteColors: [problem ? .systemYellow : .systemRed])) : image
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        let title = recording && style == .full ? " " + RecorderModel.shared.elapsedText : ""
        if button.title != title { button.title = title }
        // Keep MeetRec out of screen sharing (apps that honour the window sharing type).
        let sharing: NSWindow.SharingType = MenuBarStyle.hideFromSharing ? .none : .readOnly
        if button.window?.sharingType != sharing { button.window?.sharingType = sharing }
        panel.setSharingType(sharing)
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
            if model.isRecording {
                RecordingControls()
            }
            Divider()
            if model.isRecording {
                LiveStatusPanel()
            } else {
                sources
            }
            // While recording the panel shows only what concerns the recording itself.
            if !model.isRecording {
                TranscriptionStatus()
                // Accordion: one card open at a time keeps the panel within the screen height.
                VStack(spacing: 8) {
                    CollapsibleSection(title: "Видео", icon: "video.fill", summary: videoSummary,
                                       isExpanded: expanded("video")) { videoSettings }
                    CollapsibleSection(title: "Транскрибация", icon: "text.bubble.fill", summary: transcriptionSummary,
                                       isExpanded: expanded("transcription")) { TranscriptionSettings() }
                    CollapsibleSection(title: "Автозапись встреч", icon: "person.2.wave.2.fill", summary: meetingSummary,
                                       isExpanded: expanded("meetings")) { MeetingSettings() }
                    CollapsibleSection(title: "Значок в меню", icon: "menubar.rectangle", summary: appearanceSummary,
                                       isExpanded: expanded("appearance")) { AppearanceSettings() }
                    RecordingsSection(isExpanded: expanded("recordings"))
                }
                Divider()
                bottomRow
                HStack(alignment: .top, spacing: 20) {
                    LoginItemToggle()
                    Toggle("Перезапуск после сбоя", isOn: Binding(get: { model.crashWatchdog },
                                                                   set: { model.setCrashWatchdog($0) }))
                        .help("Если MeetRec упадёт, он запустится снова через несколько секунд и продолжит запись")
                    Spacer(minLength: 0)
                }
            }
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
        }
        .padding(14)
        .frame(width: MenuPanelController.cardWidth)
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
                ElapsedLabel()
            }
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording, isBusy: model.isBusy) { model.toggle() }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "display").foregroundStyle(.secondary).frame(width: 18)
                    Picker("Монитор", selection: $model.displayID) {
                        Text(autoDisplayTitle).tag(RecorderModel.autoDisplay)
                        ForEach(model.displays) { display in
                            Text(display.name).tag(Int(display.id))
                        }
                    }
                    .labelsHidden()
                    .help("Какой монитор записывать")
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary).frame(width: 18)
                    Picker("Микрофон", selection: $model.microphoneID) {
                        Text("Системный по умолчанию").tag("")
                        ForEach(model.microphones) { mic in
                            Text(mic.name).tag(mic.id)
                        }
                    }
                    .labelsHidden()
                    .help("Какой микрофон записывать")
                }
                .frame(maxWidth: .infinity)
                .disabled(!model.microphone)
            }
            HStack(spacing: 20) {
                Toggle("Звук системы", isOn: $model.systemAudio)
                Toggle("Микрофон", isOn: $model.microphone)
                Spacer(minLength: 0)
            }
            if model.microphone {
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

    @AppStorage(MenuBarStyle.storageKey) private var menuBarStyle = MenuBarStyle.full.rawValue
    @AppStorage(MenuBarStyle.hideFromSharingKey) private var hideFromSharing = false

    private var appearanceSummary: String {
        let style = (MenuBarStyle(rawValue: menuBarStyle) ?? .full).title
        return hideFromSharing ? "\(style) · скрыт при показе экрана" : style
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
            HStack(spacing: 16) {
                Picker("Кадров/с", selection: $model.fps) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Picker("Разрешение", selection: $model.resolution) {
                    ForEach(ResolutionPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Picker("Кодек", selection: $model.codec) {
                Text("H.264 (совместимость)").tag("h264")
                Text("HEVC (меньше файлы)").tag("hevc")
            }
        }
        .padding(.top, 4)
        .disabled(model.isRecording)
    }

    /// Recordings folder and the app's own buttons in one row.
    private var bottomRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            Text(model.folderURL.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.folderPath)
            Spacer(minLength: 4)
            Button("Изменить") { model.chooseFolder() }
                .disabled(model.isRecording)
                .help("Выбрать папку для записей")
            Button("Открыть") { model.openFolder() }
                .help("Открыть папку с записями в Finder")
            Divider().frame(height: 16)
            Button("Лог") { model.openLog() }
                .buttonStyle(.borderless)
                .help("Открыть журнал MeetRec")
            Button("Выйти") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .disabled(model.isRecording)
        }
    }

    private var autoDisplayTitle: String {
        if let display = model.effectiveDisplay {
            return "Авто (\(display.name))"
        }
        return "Авто"
    }
}

/// The recording timer; observes only `LiveRecording`, so it redraws once a second on its own.
struct ElapsedLabel: View {
    @EnvironmentObject private var live: LiveRecording

    var body: some View {
        Label(live.elapsedText, systemImage: "record.circle.fill")
            .foregroundStyle(.red)
            .monospacedDigit()
    }
}

/// `StatusPanel` fed from `LiveRecording`: the meters redraw without redrawing the rest of the panel.
struct LiveStatusPanel: View {
    @EnvironmentObject private var live: LiveRecording

    var body: some View {
        if let health = live.health {
            StatusPanel(health: health, load: live.load)
        }
    }
}

/// Live "is everything being recorded?" panel shown while recording.
struct StatusPanel: View {
    let health: RecordingHealth
    let load: SystemLoad?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Статус записи").font(.subheadline.weight(.semibold))
            StatusRow(icon: "mic.fill", signal: health.microphone)
            StatusRow(icon: "speaker.wave.2.fill", signal: health.systemAudio)
            StatusRow(icon: "display", signal: health.screen)
            StatusRow(icon: "internaldrive", signal: health.file)
            if let load {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                    Text("Процессор \(Int(load.systemCPU.rounded()))%")
                        .font(.callout)
                        .foregroundStyle(load.systemCPU >= RecorderModel.highCPUPercent ? .red : .primary)
                    Spacer()
                    Text("MeetRec \(Int(load.appCPU.rounded()))% · \(load.memoryText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Общая загрузка процессора Mac; справа — сколько процессора (в % одного ядра) и памяти занимает MeetRec")
            }
            if health.fileStalledFor >= HealthTracker.fileStalledAfter {
                Text("Файл записи перестал расти: данные не сохраняются. Остановите и начните запись заново.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health.diskLow {
                Text("Заканчивается место на диске. Запись остановится сама, когда останется меньше \(DiskSpace.format(DiskSpace.stopBelow)).")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if health.hasProblem {
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

/// While recording: mark the current moment, and choose between the whole screen and one window.
struct RecordingControls: View {
    @EnvironmentObject private var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = model.meetingWindowWarning {
                VStack(alignment: .leading, spacing: 6) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let display = model.meetingWindowDisplay {
                            Button("Записывать «\(display.name)»") { model.switchDisplay(to: display.id) }
                        }
                        Button("Игнорировать") { model.ignoreMeetingWindow() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            Button {
                model.addMarker()
            } label: {
                HStack {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text("Отметить момент")
                    Spacer()
                    Text(RecorderModel.markerHotKeyHint).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Отметка попадёт в транскрипт как «⭐ время»")
            if let last = model.markers.last {
                Text("Отметок: \(model.markers.count), последняя на \(last.timeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Записывать")
                Spacer()
                Menu {
                    Button {
                        model.record(window: nil)
                    } label: {
                        Label("Весь экран", systemImage: model.captureWindow == nil ? "checkmark" : "display")
                    }
                    Divider()
                    if model.windows.isEmpty {
                        Text("Нет окон")
                    }
                    ForEach(model.windows) { window in
                        Button {
                            model.record(window: window)
                        } label: {
                            if model.captureWindow?.id == window.id {
                                Label(window.label, systemImage: "checkmark")
                            } else {
                                Text(window.label)
                            }
                        }
                    }
                    Divider()
                    Button("Обновить список окон") { model.refreshWindows() }
                } label: {
                    Text(model.captureWindow.map { $0.label } ?? "Весь экран")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .disabled(model.isBusy)
            }
            if model.captureWindow != nil {
                Text("Пишется только это окно: другие окна и уведомления в запись не попадут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshWindows() }
        .onChange(of: model.panelVisible) { if model.panelVisible { model.refreshWindows() } }
    }
}

/// The big start/stop button. Switching morphs it: the colour deepens, the record icon turns into a
/// stop square, the title slides, and a ring ripples out on start. While recording it glows (a steady
/// glow, not a pulse: an endless animation would redraw the panel every frame during the recording).
struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false
    @State private var ripple = false

    private static let startColor = Color(red: 0.96, green: 0.26, blue: 0.27)
    private static let stopColor = Color(red: 0.62, green: 0.08, blue: 0.10)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "record.circle")
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 20)
                ZStack(alignment: .leading) {
                    Text(isRecording ? "Остановить запись" : "Начать запись")
                        .id(isRecording)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
                .clipped()
                Spacer()
                Text(RecorderModel.hotKeyHint).foregroundStyle(.white.opacity(0.7))
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(isRecording ? Self.stopColor : Self.startColor)
                    .brightness(hovering && !isBusy ? 0.06 : 0)
            }
            .overlay {
                // Ripple on start.
                Capsule()
                    .stroke(Self.startColor, lineWidth: 3)
                    .scaleEffect(x: ripple ? 1.06 : 1, y: ripple ? 1.5 : 1)
                    .opacity(ripple ? 0 : (isRecording ? 0.9 : 0))
                    .allowsHitTesting(false)
            }
            .shadow(color: (isRecording ? Self.stopColor : Self.startColor).opacity(isRecording ? 0.6 : 0.25),
                    radius: isRecording ? 10 : 5)
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isBusy)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
        .onChange(of: isRecording) { _, recording in
            guard recording else { return }
            ripple = false
            withAnimation(.easeOut(duration: 0.8)) { ripple = true }
        }
    }
}

/// Plain look, but tells the button when it is held down, for the press-in effect.
private struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
    }
}
