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
                    CollapsibleSection(title: "Видео", icon: "video.fill", summary: videoSummary,
                                       isExpanded: expanded("video")) { videoSettings }
                    CollapsibleSection(title: "Встречи и звонки", icon: "person.2.wave.2.fill", summary: meetingSummary,
                                       isExpanded: expanded("meetings")) { MeetingSettings() }
                    CollapsibleSection(title: "Транскрибация", icon: "text.bubble.fill", summary: transcriptionSummary,
                                       isExpanded: expanded("transcription")) { TranscriptionSettings() }
                    CollapsibleSection(title: "Вид во время записи", icon: "menubar.rectangle", summary: appearanceSummary,
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

    /// Folder, launch at login, crash watchdog.
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
        guard model.meetingDetection else { return "Выключена" }
        let names = MeetingApp.all.filter { $0.supported && model.selectedMeetingApps.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return "Не выбраны приложения" }
        return (model.detectorStatus ?? "Включена") + " · " + names.joined(separator: ", ")
    }

    var appearanceSummary: String {
        let style = (MenuBarStyle(rawValue: menuBarStyle) ?? .full).title
        return hideFromSharing ? "\(style) · скрыт при показе экрана" : style
    }

    var videoSummary: String {
        let resolution = ResolutionPreset(rawValue: model.resolution)?.title ?? model.resolution
        return "\(model.fps) к/с · \(resolution) · \(model.codec == "hevc" ? "HEVC" : "H.264")"
    }

    var transcriptionSummary: String {
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
