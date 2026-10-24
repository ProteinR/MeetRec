import SwiftUI

/// The settings page behind the gear: tabs for recording (general settings and the accordion of
/// sections), screenshots and shortcuts.
extension ContentView {
    /// Settings that rarely change, behind the gear button.
    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    Label("Назад", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Настройки").font(.headline)
                Spacer()
                // Balances the back button so the title stays centred.
                Label("Назад", systemImage: "chevron.left").hidden()
            }
            SettingsTabBar(selection: settingsTabBinding)
            switch settingsTab {
            case .recording:
                generalSettings
                // Accordion: one card open at a time keeps the page within the screen height.
                VStack(spacing: 8) {
                    CollapsibleSection(title: String(localized: "Видео"), icon: "video.fill", summary: videoSummary,
                                       isExpanded: expanded("video")) { videoSettings }
                    CollapsibleSection(title: String(localized: "Встречи и звонки"), icon: "person.2.wave.2.fill", summary: meetingSummary,
                                       isExpanded: expanded("meetings")) { MeetingSettings() }
                    CollapsibleSection(title: String(localized: "Транскрибация"), icon: "text.bubble.fill", summary: transcriptionSummary,
                                       isExpanded: expanded("transcription")) { TranscriptionSettings() }
                    CollapsibleSection(title: String(localized: "Вид во время записи"), icon: "menubar.rectangle", summary: appearanceSummary,
                                       isExpanded: expanded("appearance")) { AppearanceSettings() }
                }
            case .screenshots:
                ScreenshotSettings().settingsCard()
            case .shortcuts:
                shortcutSettings.settingsCard()
            }
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

    /// Folder, log, language, launch at login, crash watchdog.
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
            LanguagePicker()
            HStack(alignment: .top, spacing: 20) {
                LoginItemToggle()
                Toggle("Перезапуск после сбоя", isOn: Binding(get: { model.crashWatchdog },
                                                               set: { model.setCrashWatchdog($0) }))
                    .help("Если MeetRec упадёт, он запустится снова через несколько секунд и продолжит запись")
                Spacer(minLength: 0)
            }
        }
        .settingsCard()
    }

    var meetingSummary: String {
        guard model.meetingDetection else { return String(localized: "Выключена") }
        let names = MeetingApp.all.filter { $0.supported && model.selectedMeetingApps.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return String(localized: "Не выбраны приложения") }
        return (model.detectorStatus ?? String(localized: "Включена")) + " · " + names.joined(separator: ", ")
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
            parts.append(transcriber.language.isEmpty ? String(localized: "язык авто") : transcriber.language)
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
        .padding(.top, 4)
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
