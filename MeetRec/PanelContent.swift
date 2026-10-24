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
    @State var showingSettings = false
    /// The settings tab last looked at, kept across openings.
    @AppStorage(SettingsTab.storageKey) private var settingsTabRaw = SettingsTab.recording.rawValue
    var settingsTab: SettingsTab { SettingsTab(rawValue: settingsTabRaw) ?? .recording }
    var settingsTabBinding: Binding<SettingsTab> {
        Binding(get: { settingsTab }, set: { tab in
            openSection = nil
            settingsTabRaw = tab.rawValue
        })
    }
    @State private var closeAfterToggle = false
    /// After a click on Start/Stop the layout stays as it was until the panel folds away, so the
    /// button morphs in place instead of jumping.
    @State private var frozenLayout: Bool?
    private var recordingLayout: Bool { frozenLayout ?? model.isRecording }

    func expanded(_ section: String) -> Binding<Bool> {
        Binding(get: { openSection == section }, set: { openSection = $0 ? section : nil })
    }

    var body: some View {
        Group {
            if showingSettings {
                settingsPage
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
        .onExitCommand { if showingSettings { showingSettings = false } else { close() } }
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
            showingSettings = true
            if let tab = model.settingsTab { settingsTabRaw = tab.rawValue }
            if let section = model.settingsSection { openSection = section }
        }
        // Every opening starts on the main page with all sections folded; reset while hidden, so
        // nothing animates.
        .onChange(of: model.panelVisible) { _, visible in
            guard !visible, openSection != nil || showingSettings || frozenLayout != nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                openSection = nil
                showingSettings = false
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
                Divider()
                sources
            }
            // While recording the panel shows only what concerns the recording itself.
            if !recordingLayout {
                // Transcription progress is shown per recording in the list, not here.
                // The recordings folder opens from the search row inside; quitting is in the menu bar
                // item's right-click menu.
                RecordingsSection(isExpanded: expanded("recordings"))
                ScreenshotsSection(isExpanded: expanded("screenshots"), close: close)
            }
            if let notice = model.stopNotice, !model.isRecording, frozenLayout == nil {
                LastRecordingNotice(notice: notice, file: model.lastFile) { model.stopNotice = nil }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A recording shortcut another app holds would silently do nothing.
    @ViewBuilder
    private var takenShortcutsWarning: some View {
        let taken = ShortcutAction.recording.filter { Shortcuts.shared.taken.contains($0) }
        if !taken.isEmpty {
            Button {
                settingsTabRaw = SettingsTab.shortcuts.rawValue
                showingSettings = true
            } label: {
                WarningLabel(text: "Не работает: " + taken.compactMap { Shortcuts.shared.combo($0)?.text }.joined(separator: ", ")
                             + " — сочетание занято другим приложением. Изменить…")
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
            Text("MeetRec").font(.headline)
            Text(RecorderModel.appVersion)
                .font(.caption).foregroundStyle(.tertiary)
                .textSelection(.enabled)
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
                    Image(systemName: "person.crop.square").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Как я выгляжу: зеркало с камеры")
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

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Audio first, then the picture. The rows share the monitor card's grid: icon in its 24 pt
            // icon column, content from where its title starts, switches lined up on the right.
            sourceRow(icon: "mic.fill", isOn: $model.microphone) {
                Picker("Микрофон", selection: $model.microphoneID) {
                    Text("По умолчанию").tag("")
                    ForEach(model.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                .labelsHidden()
                .help("Какой микрофон записывать. «По умолчанию» — сейчас: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "нет")")
                .disabled(!model.microphone)
            }
            if model.microphone {
                micPreview
                    .padding(.leading, 44)
                    .padding(.trailing, 10)
            }
            sourceRow(icon: "speaker.wave.2.fill", isOn: $model.systemAudio) {
                Text("Звук системы")
            }
            CollapsibleSection(title: model.chosenWindow.map { "Окно: \($0.label)" } ?? model.effectiveDisplay?.name ?? "Монитор не найден",
                               icon: model.chosenWindow == nil ? "display" : "macwindow",
                               summary: displaySummary, isExpanded: expanded("display")) {
                DisplayChooser(preview: displayPreview, windows: windowPreview)
            }
        }
        .disabled(model.isRecording)
        .onAppear(perform: updatePreviews)
        .onChange(of: model.panelVisible) { updatePreviews() }
        .onChange(of: model.microphone) { updateMicPreview() }
        .onChange(of: model.microphoneID) { updateMicPreview() }
        .onChange(of: model.isRecording) { updatePreviews() }
        .onChange(of: openSection) { updateDisplayPreview() }
        .onChange(of: model.displayID) { updateDisplayPreview() }
        .onChange(of: model.displays) { updateDisplayPreview() }
        .onChange(of: model.chosenWindow) { updateDisplayPreview() }
        // Every refresh: the window may have moved or been brought forward meanwhile.
        .onChange(of: windowPreview.tiles.map { "\($0.id) \(NSStringFromRect($0.frame))" }) { updateDisplayPreview() }
        .onDisappear { DisplayHighlight.shared.hide() }
    }

    /// A source with its on/off switch, aligned with the collapsible cards below.
    private func sourceRow<Content: View>(icon: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(isOn.wrappedValue ? .primary : .tertiary)
                .frame(width: 24)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .toggleStyle(LightSwitchStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 10)
    }

    private var displaySummary: String {
        guard let display = model.effectiveDisplay else { return "" }
        if model.chosenWindow != nil { return "Только это окно · на «\(display.name)» · на одну запись" }
        let kind = display.isBuiltIn ? "встроенный экран" : "внешний монитор"
        return model.displayID == RecorderModel.autoDisplay ? "Авто · \(kind)" : kind
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
                Text(micMonitor.deviceName ?? "Микрофон")
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

    @AppStorage(MenuBarStyle.storageKey) var menuBarStyle = MenuBarStyle.full.rawValue
    @AppStorage(MenuBarStyle.hideFromSharingKey) var hideFromSharing = true

}
