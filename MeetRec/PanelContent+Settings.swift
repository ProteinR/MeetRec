import SwiftUI

/// The author's pages, at the bottom of the settings list. A landing page will join them later.
enum Links {
    static let author = URL(string: "https://github.com/ProteinR")!
}

/// The settings behind the gear: a list of sections, each opening as its own page.
extension ContentView {
    var settingsPage: some View {
        ZStack(alignment: .top) {
            if let page = settingsSubpage {
                settingsDetail(page)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                settingsList
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: settingsSubpage)
    }

    func openSettings(_ page: SettingsPage?) {
        withAnimation(.smooth(duration: 0.3)) { settingsSubpage = page }
    }

    /// Back, the title in the middle and something on the right (the version on the list).
    private func settingsHeader(back: String, title: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        ZStack {
            Text(title).font(.headline).lineLimit(1)
            HStack {
                Button(action: action) {
                    Label(back, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsHeader(back: String(localized: "Назад"), title: String(localized: "Настройки")) { showingSettings = false }
            ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                SettingsGroup {
                    ForEach(Array(group.enumerated()), id: \.element) { index, page in
                        if index > 0 { Divider().padding(.leading, 44) }
                        SettingsRow(page: page, summary: settingsSummary(page)) { openSettings(page) }
                    }
                }
            }
            // Quiet, at the end: whoever opens the settings has been through it already.
            Button {
                showingSettings = false
                onboardingDone = false
            } label: {
                Label("Пройти знакомство с MeetRec ещё раз", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            aboutFooter
        }
    }

    /// The version and the author's page, as in the owner's other apps (Genius Typer).
    private var aboutFooter: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 10) {
                Text("MeetRec \(RecorderModel.appVersion)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Link(destination: Links.author) {
                    Label("github.com/ProteinR", systemImage: "arrow.up.right.square")
                }
                .help("Автор MeetRec на GitHub")
            }
            .font(.caption)
            .padding(.horizontal, 4)
        }
    }

    private func settingsDetail(_ page: SettingsPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsHeader(back: String(localized: "Настройки"), title: page.title) { openSettings(nil) }
            Group {
                switch page {
                case .general: generalSettings
                case .video: videoSettings
                case .meetings: MeetingSettings()
                case .transcription: TranscriptionSettings()
                case .appearance: AppearanceSettings()
                case .screenshots: ScreenshotSettings()
                case .shortcuts: shortcutSettings
                }
            }
            .settingsCard()
        }
    }

    func settingsSummary(_ page: SettingsPage) -> String {
        switch page {
        case .general: String(localized: "Папка «\(model.folderURL.lastPathComponent)», значок, язык, запуск, обновления")
        case .video: videoSummary
        case .meetings: meetingSummary
        case .transcription: transcriptionSummary
        case .appearance: appearanceSummary
        case .screenshots: String(localized: "Папка «\(Screenshotter.shared.folderURL.lastPathComponent)», формат, поиск по картинке")
        case .shortcuts: [Shortcuts.shared.hint(.record), Shortcuts.shared.hint(.screenshot), Shortcuts.shared.hint(.text)]
            .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Every shortcut in one place, so a clash between two of them is seen at once.
    var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Запись").font(.caption).foregroundStyle(.secondary)
            ForEach(ShortcutAction.recording) { ShortcutRow(action: $0) }
            Text("Скриншоты").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(ShortcutAction.screenshots) { ShortcutRow(action: $0) }
        }
    }

    /// Folder, log, menu bar icon, language, launch at login, crash watchdog.
    var generalSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Папка для записей").font(.callout)
                    Text(model.folderPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("Изменить") { model.chooseFolder() }
                    .disabled(model.isRecording)
                    .help(model.isRecording ? "Меняется после записи: текущий файл пишется в эту папку" : "")
            }
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Журнал").font(.callout)
                    Text("Подробный лог: запись, звук, встречи, транскрибация").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Открыть") { model.openLog() }
            }
            MenuBarIconPicker()
            LanguagePicker()
            HStack(alignment: .top, spacing: 20) {
                LoginItemToggle()
                Toggle("Перезапуск после сбоя", isOn: Binding(get: { model.crashWatchdog },
                                                               set: { model.setCrashWatchdog($0) }))
                    .help("Если MeetRec упадёт, он запустится снова через несколько секунд и продолжит запись")
                Spacer(minLength: 0)
            }
            UpdateSettingsRow()
        }
    }

    var meetingSummary: String {
        let selected = MeetingApp.all.filter { $0.supported && model.selectedMeetingApps.contains($0.id) }
        let auto = model.meetingDetection ? selected.filter { !model.asks($0) }.map(\.shortName) : []
        let ask = selected.filter { model.asks($0) }.map(\.shortName)
        guard !auto.isEmpty || !ask.isEmpty else { return String(localized: "Автозапись выключена") }
        var parts: [String] = []
        if !auto.isEmpty { parts.append(String(localized: "Сам запишу: \(auto.formatted(.list(type: .and))).")) }
        if !ask.isEmpty { parts.append(String(localized: "Спрошу: \(ask.formatted(.list(type: .and))).")) }
        return parts.joined(separator: " ")
    }

    var appearanceSummary: String {
        let style = (MenuBarStyle(rawValue: menuBarStyle) ?? .full).title
        return hideFromSharing ? String(localized: "\(style) · скрыт при показе экрана") : style
    }

    var videoSummary: String {
        let resolution = ResolutionPreset(rawValue: model.resolution)?.title ?? model.resolution
        let codec = model.codec == "hevc" ? "HEVC" : "H.264"
        return String(localized: "\(model.fps) к/с · \(resolution) · \(codec)")
    }

    var transcriptionSummary: String {
        switch transcriber.modelsState {
        case .missing: return String(localized: "Модели не скачаны")
        case .downloading: return String(localized: "Скачивание моделей…")
        case .failed: return String(localized: "Ошибка моделей")
        case .checking: return String(localized: "Проверка…")
        case .ready:
            var parts = [transcriber.transcribeAfterRecording ? String(localized: "После записи: вкл") : String(localized: "После записи: выкл")]
            if transcriber.diarization { parts.append(String(localized: "по ролям")) }
            if Summarizer.shared.summarizeAfterTranscription && Summarizer.shared.isConfigured {
                parts.append(String(localized: "резюме: \(Summarizer.shared.provider.title)"))
            }
            return parts.joined(separator: " · ")
        }
    }

    var videoSettings: some View {
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
        .disabled(model.isRecording)
        .overlay(alignment: .bottomTrailing) {
            if model.isRecording {
                Text("Меняется после записи").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// The settings page's plain card (general settings, screenshots, shortcuts).
    func settingsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Scrolls only when the content does not fit: as tall as the content (so the card still hugs it),
/// at most what the panel window leaves. A plain `ScrollView` would always take the whole height.
struct HuggingScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            content()
                .background(OverlayScrollers())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    // Sections open with an animation: the card follows it instead of jumping.
                    if height == nil {
                        height = newHeight
                    } else {
                        withAnimation(.smooth(duration: 0.28)) { height = newHeight }
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: height ?? 0)
    }
}
