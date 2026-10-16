import SwiftUI

/// Settings section: auto-transcription, models, diarization, language, own voice sample.
struct TranscriptionSettings: View {
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var model: RecorderModel
    @StateObject private var sampleRecorder = VoiceSampleRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            models
            HStack(spacing: 20) {
                Toggle("Сразу после записи", isOn: $transcriber.transcribeAfterRecording)
                    .disabled(transcriber.modelsState != .ready)
                    .help("Транскрибировать каждую запись, как только она остановлена")
                Toggle("Разбивка по ролям", isOn: $transcriber.diarization)
                    .help("Определять, кто говорит, и подписывать реплики именами")
                Spacer(minLength: 0)
            }
            Picker("Язык", selection: $transcriber.language) {
                Text("Определять автоматически").tag("")
                Text("English").tag("en")
                Text("Русский").tag("ru")
                Text("Deutsch").tag("de")
            }
            meetingsFolder
            if transcriber.diarization {
                voice
            }
            if let last = model.lastFile, transcriber.modelsState == .ready {
                Button("Транскрибировать последнюю запись") { transcriber.enqueue(last) }
                    .buttonStyle(.link)
                    .help(last.lastPathComponent)
            }
        }
        .padding(.top, 4)
    }

    private var meetingsFolder: some View { CopyRulesEditor() }

    @ViewBuilder
    private var models: some View {
        switch transcriber.modelsState {
        case .ready:
            Label("Модели загружены", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .checking:
            Text("Проверка моделей…").font(.callout).foregroundStyle(.secondary)
        case .missing:
            VStack(alignment: .leading, spacing: 4) {
                Text("Модели не скачаны (~3 ГБ: распознавание речи и разбивка по ролям)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Скачать модели") { transcriber.downloadModels() }
            }
        case .downloading(let phase):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase).font(.callout).lineLimit(2)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить") { transcriber.downloadModels() }
            }
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Моё имя")
                TextField("Имя", text: $transcriber.myName)
                    .textFieldStyle(.roundedBorder)
            }
            let samples = transcriber.speakerSamples[transcriber.myName] ?? 0
            Text(samples > 0
                 ? "Мой голос: \(samples) образц. — буду подписан как «\(transcriber.myName)»"
                 : "Образца голоса нет — я буду «Speaker N»")
                .font(.caption)
                .foregroundStyle(samples > 0 ? .green : .secondary)
            if sampleRecorder.isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Говорите обычным голосом… \(sampleRecorder.remaining) с").font(.callout)
                    LevelMeter(levelDB: sampleRecorder.levelDB)
                    Button("Отмена") { sampleRecorder.cancel() }
                }
            } else {
                Button(samples > 0 ? "Записать ещё образец (20 с)" : "Записать образец голоса (20 с)") {
                    transcriber.setEnrollMessage(nil)
                    sampleRecorder.start { url in
                        guard let url else {
                            transcriber.setEnrollMessage("Запись образца не удалась")
                            return
                        }
                        Task { _ = await transcriber.enrollSample(url) }
                    }
                }
                .disabled(transcriber.modelsState != .ready || model.isRecording)
            }
            if let message = transcriber.enrollMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let others = otherVoices {
                Text("Знакомые голоса: \(others)").font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherVoices: String? {
        let names = transcriber.speakerSamples.keys.filter { $0 != transcriber.myName }.sorted()
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

/// "Копировать транскрипты": rules "app → folder", each with its own folder; "+" adds another.
struct CopyRulesEditor: View {
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var model: RecorderModel

    private var apps: [MeetingApp] { MeetingApp.all.filter(\.supported) }

    /// Apps, then browser rules ("Skyeng (браузер)"): each can have its own folder.
    private var sources: [(key: String, title: String)] {
        apps.map { ($0.id, $0.id == "browser" ? "Браузер (все)" : $0.name.replacingOccurrences(of: "Microsoft ", with: "")) }
            + model.browserRules.filter { !$0.keyword.isEmpty }.map { rule in
                (CopyRule.ruleKey(rule.id.uuidString), "\(rule.title.isEmpty ? rule.keyword : rule.title) (браузер)")
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Копировать транскрипты встреч")
            ForEach(transcriber.copyRules) { rule in
                HStack(spacing: 6) {
                    Picker("Приложение", selection: appBinding(rule)) {
                        ForEach(sources, id: \.key) { Text($0.title).tag($0.key) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                    Button {
                        if let path = transcriber.chooseFolder(startingAt: rule.folder) { update(rule) { $0.folder = path } }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text(rule.folder.isEmpty ? "Выбрать папку…" : URL(fileURLWithPath: rule.folder).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(rule.folder.isEmpty ? "Куда копировать" : rule.folder)
                    Button {
                        transcriber.copyRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать правило")
                }
            }
            Button {
                let used = Set(transcriber.copyRules.map(\.app))
                let app = apps.first { !used.contains($0.id) }?.id ?? "teams"
                transcriber.copyRules.append(CopyRule(app: app, folder: ""))
            } label: {
                Label(transcriber.copyRules.isEmpty ? "Добавить приложение" : "Добавить ещё", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            Text("Для записей встреч (начатых автоматически или по вопросу о звонке) длиннее \(Int(Transcriber.minimumMeetingDuration / 60)) мин. Транскрипт остаётся и рядом с видео; файл в папке никогда не перезаписывается.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appBinding(_ rule: CopyRule) -> Binding<String> {
        Binding(get: { rule.app }, set: { value in update(rule) { $0.app = value } })
    }

    private func update(_ rule: CopyRule, _ change: (inout CopyRule) -> Void) {
        var rules = transcriber.copyRules
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&rules[index])
        transcriber.copyRules = rules
    }
}
