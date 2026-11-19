import AVFoundation
import Carbon
import SwiftUI

struct ContentView: View {
    /// Closes the panel (Esc, ⌘W).
    let close: () -> Void
    /// Fades the panel out (after Start/Stop).
    let closeAnimated: () -> Void

    @EnvironmentObject var model: RecorderModel
    @EnvironmentObject var transcriber: Transcriber
    @StateObject private var micMonitor = MicrophoneMonitor()
    /// Taken or changed shortcuts show up in the panel at once.
    @ObservedObject private var shortcuts = Shortcuts.shared
    @StateObject private var displayPreview = DisplayPreview()
    @StateObject private var windowPreview = WindowPreview()
    @State private var openSection: String?
    /// The tab last chosen ("Записи" or "Скриншоты"), opened again next time.
    @AppStorage(PanelTab.storageKey) private var panelTabRaw = PanelTab.recordings.rawValue
    private var panelTab: PanelTab { PanelTab(rawValue: panelTabRaw) ?? .recordings }
    @State private var recordingsCount: String?
    @State private var screenshotsCount: String?
    @State var showingSettings = false
    /// The first launch's steps are shown instead of the main page until finished.
    @AppStorage(OnboardingView.storageKey) var onboardingDone = false
    /// The settings section shown as its own page; nil: the list of sections.
    @State var settingsSubpage: SettingsPage?
    @State private var closeAfterToggle = false
    /// After a click on Start/Stop the layout stays as it was until the panel folds away, so the
    /// button morphs in place instead of jumping.
    @State private var frozenLayout: Bool?
    private var recordingLayout: Bool { frozenLayout ?? model.isRecording }

    var body: some View {
        Group {
            if !onboardingDone {
                OnboardingView { withAnimation(.smooth(duration: 0.3)) { onboardingDone = true } }
                    .transition(.opacity)
            } else if showingSettings {
                // A long page (meetings with site rules) on a small screen scrolls.
                HuggingScrollView { settingsPage }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: showingSettings)
        .padding(14)
        .frame(width: MenuPanelController.cardWidth)
        .onAppear {
            model.refreshDevices()
            transcriber.refreshModels()
        }
        .onExitCommand {
            if showingSettings, settingsSubpage != nil {
                openSettings(nil)
            } else if showingSettings {
                showingSettings = false
            } else {
                close()
            }
        }
        .onChange(of: model.isRecording) { _, recording in
            guard closeAfterToggle, recording else { return }
            closeAfterToggle = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { closeAnimated() }
        }
        // A stop began (button, banner, hotkey, island, automatic) and the panel fades out: keep the
        // layout as it is meanwhile, so nothing inside rearranges during the fade.
        .onReceive(NotificationCenter.default.publisher(for: RecorderModel.foldPanelNotification)) { _ in
            closeAfterToggle = false
            frozenLayout = true
        }
        .onChange(of: model.isBusy) { _, busy in
            // Start failed (nothing changed): keep the panel open to show the error.
            if !busy, closeAfterToggle, model.errorMessage != nil {
                closeAfterToggle = false
                frozenLayout = nil
            }
        }
        .onChange(of: model.settingsRequest) {
            settingsSubpage = model.settingsPage
            showingSettings = true
        }
        // Every opening starts on the main page with all sections folded; reset while hidden, so
        // nothing animates.
        .onChange(of: model.panelVisible) { _, visible in
            if !visible { HoverTip.shared.hide() }
            guard !visible, openSection != nil || showingSettings || settingsSubpage != nil || frozenLayout != nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                openSection = nil
                showingSettings = false
                settingsSubpage = nil
                frozenLayout = nil
            }
        }
        .background {
            // ⌘W closes the panel; the app has no menu bar menu to provide it.
            Button("", action: close).keyboardShortcut("w", modifiers: .command).hidden()
            Button("") { showingSettings = true }
                .keyboardShortcut(",", modifiers: .command).hidden()
        }
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PanelTabBar(selection: Binding(get: { panelTab }, set: { tab in
                openSection = nil
                panelTabRaw = tab.rawValue
            }), counts: [.recordings: recordingsCount, .screenshots: screenshotsCount].compactMapValues { $0 })
            switch panelTab {
            case .recordings:
                recordingsTab
            case .screenshots:
                // A recording going on can be stopped from here too.
                if model.isRecording, frozenLayout == nil { recordButton }
                ScreenshotsSection(count: $screenshotsCount, close: close)
            }
            if !recordingLayout, frozenLayout == nil {
                UpdateBanner()
            }
            if let notice = model.stopNotice, !model.isRecording, frozenLayout == nil {
                LastRecordingNotice(notice: notice, interrupted: model.stopNoticeInterrupted, file: model.lastFile) { model.stopNotice = nil }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshTabCounts)
        .onChange(of: model.panelVisible) { if model.panelVisible { refreshTabCounts() } }
    }

    @ViewBuilder
    private var recordingsTab: some View {
        if recordingLayout {
            // Opened to check the recording: the status first, the stop button last, out of the way.
            if let stop = model.stopCountdown, model.isRecording {
                StopCountdownBanner(countdown: stop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            LiveStatusPanel()
            Divider()
            RecordingControls()
            // During the stop countdown its banner already offers "Остановить сейчас".
            if model.stopCountdown == nil {
                recordButton
            }
        } else {
            // A noticed call replaces the start button: one clear question instead of two red buttons.
            if let countdown = model.countdown, !model.isRecording {
                CountdownBanner(countdown: countdown)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let app = model.callPrompt, !model.isRecording {
                CallPromptBanner(app: app)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                recordButton
            }
            takenShortcutsWarning
            AutoRecordStatus()
            sources
            Divider()
            // Transcription progress is shown per recording in the list, not here.
            RecordingsSection(count: $recordingsCount)
        }
    }

    /// The tab not shown still gets its count; listing the folder is quick and off the main thread.
    private func refreshTabCounts() {
        let folder = model.folderURL, shotsFolder = Screenshotter.shared.folderURL
        Task {
            let counts = await Task.detached(priority: .utility) {
                (RecordingsStore.page(from: folder, limit: 0).total, ScreenshotFiles.list(in: shotsFolder, limit: 0).total)
            }.value
            if panelTab != .recordings { recordingsCount = counts.0 > 0 ? counts.0.formatted() : nil }
            if panelTab != .screenshots { screenshotsCount = counts.1 > 0 ? counts.1.formatted() : nil }
        }
    }

    /// A recording shortcut another app holds would silently do nothing.
    @ViewBuilder
    private var takenShortcutsWarning: some View {
        let taken = ShortcutAction.recording.filter { Shortcuts.shared.taken.contains($0) }
        if !taken.isEmpty {
            Button {
                settingsSubpage = .shortcuts
                showingSettings = true
            } label: {
                let combos = taken.compactMap { Shortcuts.shared.combo($0)?.text }.joined(separator: ", ")
                WarningLabel(text: String(localized: "Не работает: \(combos) — сочетание занято другим приложением. Изменить…"))
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape").font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help("Настройки")
    }

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
            Text("MeetRec").font(.headline)
            Spacer()
            if let badge = model.autoBadge, model.isRecording {
                Text("авто · \(badge)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
            }
            if model.isRecording {
                ElapsedLabel()
                settingsButton
            } else {
                Button {
                    close()
                    CameraMirror.shared.toggle()
                } label: {
                    // Words, not just an icon: a person in a square did not say "camera mirror".
                    Label("Проверить камеру", systemImage: "web.camera")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Как я выгляжу: зеркало с камеры перед встречей, ничего не записывается")
                settingsButton
            }
        }
    }

    /// After a click the button morphs, then the panel folds away: the user wants to get back to the
    /// meeting, the menu bar icon and the island show the recording from there.
    private var recordButton: some View {
        RecordButton(isRecording: model.isRecording, isBusy: model.isBusy) {
            // Starting folds the panel once recording runs; a stop folds it at once (foldPanelNotification).
            closeAfterToggle = !model.isRecording
            frozenLayout = model.isRecording
            model.toggle()
        }
    }

    /// What will be recorded: three equal buttons (microphone, the other side, the screen); the
    /// microphone's and the screen's choices open under the row, one at a time.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SourceChip(icon: model.microphone ? "mic.fill" : "mic.slash", title: String(localized: "Микрофон"),
                           subtitle: microphoneSubtitle, isOn: model.microphone, isOpen: openSection == "mic",
                           help: model.microphone ? String(localized: "Ваш голос записывается. Нажмите, чтобы выключить") : String(localized: "Ваш голос не записывается. Нажмите, чтобы включить"),
                           action: { model.microphone.toggle() },
                           menu: { toggleSection("mic") }, menuHelp: String(localized: "Выбрать микрофон"))
                SourceChip(icon: model.systemAudio ? "speaker.wave.2.fill" : "speaker.slash", title: String(localized: "Собеседники"),
                           subtitle: model.systemAudio ? String(localized: "звук Mac") : String(localized: "выключены"),
                           isOn: model.systemAudio, isOpen: false,
                           help: model.systemAudio ? String(localized: "Звук Mac (голоса собеседников) записывается. Нажмите, чтобы выключить") : String(localized: "Звук Mac не записывается. Нажмите, чтобы включить"),
                           action: { model.systemAudio.toggle() })
                SourceChip(icon: model.chosenWindow == nil ? "display" : "macwindow",
                           title: model.chosenWindow == nil ? String(localized: "Экран") : String(localized: "Окно"),
                           subtitle: screenSubtitle, isOn: model.effectiveDisplay != nil, isOpen: openSection == "display",
                           help: String(localized: "Выбрать экран или одно окно"),
                           action: { toggleSection("display") },
                           menu: { toggleSection("display") }, menuHelp: String(localized: "Выбрать экран"))
            }
            if openSection == "mic" {
                microphoneMenu
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if openSection == "display" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displaySummary).font(.caption).foregroundStyle(.secondary)
                    DisplayChooser(preview: displayPreview, windows: windowPreview)
                    Text("Встречи, которые MeetRec записывает сам, тоже пишутся с этого экрана.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .disabled(model.isRecording)
        .onAppear(perform: updatePreviews)
        .onChange(of: model.panelVisible) { updatePreviews() }
        .onChange(of: model.microphone) { updateMicPreview() }
        .onChange(of: model.microphoneID) { updateMicPreview() }
        .onChange(of: model.isRecording) { updatePreviews() }
        .onChange(of: openSection) { updatePreviews() }
        .onChange(of: model.displayID) { updateDisplayPreview() }
        .onChange(of: model.displays) { updateDisplayPreview() }
        .onChange(of: model.chosenWindow) { updateDisplayPreview() }
        // Every refresh: the window may have moved or been brought forward meanwhile.
        .onChange(of: windowPreview.tiles.map { "\($0.id) \(NSStringFromRect($0.frame))" }) { updateDisplayPreview() }
        .onDisappear {
            DisplayHighlight.shared.hide()
            displayPreview.stop()
            windowPreview.stop()
            micMonitor.stop()
        }
    }

    private func toggleSection(_ section: String) {
        withAnimation(.smooth(duration: 0.25)) { openSection = openSection == section ? nil : section }
    }

    private var microphoneSubtitle: String {
        guard model.microphone else { return String(localized: "выключен") }
        if model.microphoneID.isEmpty { return String(localized: "авто") }
        return model.microphones.first { $0.id == model.microphoneID }?.name ?? String(localized: "не подключён")
    }

    private var screenSubtitle: String {
        if let window = model.chosenWindow { return window.label }
        guard let display = model.effectiveDisplay else { return String(localized: "не найден") }
        if model.displayID == RecorderModel.autoDisplay {
            return display.isBuiltIn ? String(localized: "авто · встроенный") : String(localized: "авто · внешний")
        }
        return display.name
    }

    /// The microphones as a list (the one recorded ticked) and, on request, its level.
    private var microphoneMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            microphoneOption(id: "", title: String(localized: "Авто"),
                             subtitle: String(localized: "как в звонке, иначе системный: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "нет"))"))
            ForEach(model.microphones) { mic in
                microphoneOption(id: mic.id, title: mic.name, subtitle: nil)
            }
            if model.microphone {
                micPreview
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func microphoneOption(id: String, title: String, subtitle: String?) -> some View {
        Button {
            model.microphoneID = id
            model.microphone = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(model.microphoneID == id ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    private var displaySummary: String {
        guard let display = model.effectiveDisplay else { return "" }
        if model.chosenWindow != nil { return String(localized: "Только это окно · на «\(display.name)» · на одну запись") }
        if model.displayID == RecorderModel.autoDisplay {
            return display.isBuiltIn ? String(localized: "Авто · встроенный экран") : String(localized: "Авто · внешний монитор")
        }
        return display.isBuiltIn ? String(localized: "встроенный экран") : String(localized: "внешний монитор")
    }

    private func updatePreviews() {
        updateMicPreview()
        updateDisplayPreview()
    }

    /// While the monitor section is open: pictures of all displays, and a red frame on the screen
    /// that will be recorded.
    private func updateDisplayPreview() {
        if model.panelVisible, !model.isRecording, openSection == "display", let display = model.effectiveDisplay {
            displayPreview.start()
            windowPreview.start(displayID: display.id)
            if let chosen = model.chosenWindow, let tile = windowPreview.tiles.first(where: { $0.id == chosen.id }) {
                DisplayHighlight.shared.show(windowFrame: tile.frame, windowID: tile.id)
            } else {
                DisplayHighlight.shared.show(displayID: display.id)
            }
        } else {
            displayPreview.stop()
            windowPreview.stop()
            DisplayHighlight.shared.hide()
        }
    }

    /// Live level of the chosen microphone, so a silent or wrong device is obvious before recording.
    @ViewBuilder
    private var micPreview: some View {
        if micMonitor.waitingForCheck {
            // Any microphone only on request: the same with or without headphones, no orange dot
            // each time the panel opens.
            HStack(spacing: 6) {
                Text(micMonitor.deviceName ?? String(localized: "Микрофон"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Проверить") { micMonitor.check(deviceID: model.microphoneID) }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help(micMonitor.isBluetoothDevice
                          ? "Включит микрофон, чтобы показать уровень. Наушники переключатся в режим гарнитуры, пока панель открыта"
                          : "Включит микрофон, чтобы показать уровень, пока панель открыта")
            }
        } else {
            micLevel
        }
    }

    private var micLevel: some View {
        VStack(alignment: .leading, spacing: 3) {
            LevelMeter(levelDB: micMonitor.levelDB)
            Text(micPreviewText)
                .font(.caption2)
                .foregroundStyle(micMonitor.receiving ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
    }

    private var micPreviewText: String {
        guard let name = micMonitor.deviceName else { return String(localized: "Микрофон не найден") }
        if InputMuteState.isMuted(uid: model.microphoneID.isEmpty ? nil : model.microphoneID) {
            return String(localized: "\(name): выключен кнопкой — в записи будет тишина")
        }
        if !micMonitor.receiving { return String(localized: "\(name): сигнал не приходит") }
        return micMonitor.levelDB > -45 ? String(localized: "\(name): слышно") : String(localized: "\(name): скажите что-нибудь — полоска должна двигаться")
    }

    private func updateMicPreview() {
        if model.panelVisible, model.microphone, !model.isRecording, openSection == "mic" {
            micMonitor.start(deviceID: model.microphoneID)
        } else {
            micMonitor.stop()
        }
    }

    @AppStorage(MenuBarStyle.storageKey) var menuBarStyle = MenuBarStyle.full.rawValue
    @AppStorage(MenuBarStyle.hideFromSharingKey) var hideFromSharing = true

}

/// A row of a list shown in the panel (the microphones): highlighted under the pointer.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0))))
                .onHover { hovering = $0 }
        }
    }
}
