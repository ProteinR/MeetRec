import SwiftUI

/// Settings section: auto-transcription, models, diarization, own voice sample.
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
            meetingsFolder
            if transcriber.diarization {
                voice
            }
            Divider().padding(.vertical, 4)
            SummarySettings()
        }
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
                Text("Модели не скачаны (~650 МБ: распознавание речи и разбивка по ролям)")
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
                 ? String(localized: "Мой голос: \(samples) образц. — буду подписан как «\(transcriber.myName)»")
                 : String(localized: "Образца голоса нет — я буду «Speaker N»"))
                .font(.caption)
                .foregroundStyle(samples > 0 ? .green : .secondary)
            if sampleRecorder.isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Говорите обычным голосом… \(sampleRecorder.remaining) с").font(.callout)
                    LevelMeter(levelDB: sampleRecorder.levelDB)
                    Button("Отмена") { sampleRecorder.cancel() }
                }
            } else {
                Button(samples > 0 ? String(localized: "Записать ещё образец (20 с)") : String(localized: "Записать образец голоса (20 с)")) {
                    transcriber.setEnrollMessage(nil)
                    sampleRecorder.start { url in
                        guard let url else {
                            transcriber.setEnrollMessage(String(localized: "Запись образца не удалась"))
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
        apps.map { ($0.id, $0.id == "browser" ? String(localized: "Браузер (все)") : $0.name.replacingOccurrences(of: "Microsoft ", with: "")) }
            + model.browserRules.filter { !$0.keyword.isEmpty }.map { rule in
                (CopyRule.ruleKey(rule.id.uuidString), String(localized: "\(rule.title.isEmpty ? rule.keyword : rule.title) (браузер)"))
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
                            Text(rule.folder.isEmpty ? String(localized: "Выбрать папку…") : URL(fileURLWithPath: rule.folder).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(rule.folder.isEmpty ? String(localized: "Куда копировать") : rule.folder)
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
                Label(transcriber.copyRules.isEmpty ? String(localized: "Добавить приложение") : String(localized: "Добавить ещё"), systemImage: "plus.circle.fill")
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

/// "Суммаризация встречи": provider, API key (kept in a file only this user reads), model, language, after transcription.
struct SummarySettings: View {
    @EnvironmentObject private var summarizer: Summarizer
    @State private var keyDraft = ""

    private var provider: SummaryProvider { summarizer.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Суммаризация встречи").font(.callout.weight(.medium))
            Picker("Сервис", selection: Binding(get: { summarizer.provider }, set: { summarizer.provider = $0; keyDraft = "" })) {
                ForEach(SummaryProvider.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            if provider.needsKey { key } else { server }
            modelRow
            Picker("Язык суммаризации", selection: $summarizer.language) {
                Text("Как во встрече").tag("meeting")
                Text("Язык MeetRec").tag("app")
            }
            .fixedSize()
            spent
            Toggle("Сразу после транскрибации", isOn: $summarizer.summarizeAfterTranscription)
                .disabled(!summarizer.isConfigured)
                .help("Делать суммаризацию каждой записи, как только готов её транскрипт")
            Text(provider.needsKey
                 ? String(localized: "Транскрипт отправляется в \(provider.title) по вашему ключу; видео и звук остаются на Mac. Суммаризация встаёт в начало транскрипта. Для любой записи — «Сделать суммаризацию» в её меню.")
                 : String(localized: "Ничего не уходит с Mac: модель работает на этом компьютере (Ollama, LM Studio). Суммаризация встаёт в начало транскрипта. Для любой записи — «Сделать суммаризацию» в её меню."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The running total of every summary: money, tokens, how many.
    @ViewBuilder
    private var spent: some View {
        if summarizer.summaryRuns > 0 {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
                Text(String(localized: "Потрачено: \(SummaryUsage.money(summarizer.spentUSD)) · токены: \(SummaryUsage.tokens(summarizer.spentTokens)) · суммаризаций: \(summarizer.summaryRuns)"))
                    .font(.callout)
                if summarizer.unpricedRuns > 0 {
                    Text(String(localized: "(без цены: \(summarizer.unpricedRuns))"))
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Цена этих моделей неизвестна, они не вошли в сумму")
                }
                Spacer(minLength: 4)
                Button("Сбросить") { summarizer.resetTotals() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(summarizer.hasKey(provider) ? String(localized: "Ключ сохранён — вставьте новый, чтобы заменить") : String(localized: "Ключ API"),
                            text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("Сохранить", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
                if let masked = summarizer.maskedKey(provider) {
                    Label {
                        Text(masked).font(.caption.monospaced()).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .help(String(localized: "Ключ сохранён в файле \(APIKeyStore.file.path), который может читать только ваш пользователь"))
                    Button("Удалить ключ") { summarizer.saveKey("", for: provider) }
                        .buttonStyle(.borderless)
                }
                if let page = provider.keyPage {
                    Link("Где взять ключ", destination: page)
                }
            }
            .font(.caption)
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Адрес сервера")
                TextField(SummaryProvider.local.defaultBaseURL, text: $summarizer.localURL)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Сервер с OpenAI-совместимым API: Ollama — http://localhost:11434/v1, LM Studio — http://localhost:1234/v1")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Models come from the provider itself, so nobody has to know their names.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if summarizer.models.isEmpty {
                    Text("Модель")
                    Text(summarizer.loadingModels ? String(localized: "Загружаю список…") : summarizer.model(for: provider))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Picker("Модель", selection: Binding(get: { summarizer.model(for: provider) },
                                                        set: { summarizer.setModel($0, for: provider) })) {
                        ForEach(summarizer.models) { Text($0.name).tag($0.id) }
                        // The saved one, if the service no longer lists it (the picker needs a tag for it).
                        if !summarizer.models.contains(where: { $0.id == summarizer.model(for: provider) }) {
                            Text(summarizer.model(for: provider)).tag(summarizer.model(for: provider))
                        }
                    }
                }
                Spacer(minLength: 0)
                if summarizer.loadingModels {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Button {
                        summarizer.loadModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(provider.needsKey && !summarizer.hasKey(provider))
                    .help("Обновить список моделей")
                }
            }
            if let message = summarizer.modelsMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { summarizer.loadModelsIfNeeded() }
        .onChange(of: summarizer.localURL) { if provider == .local { summarizer.invalidateModels() } }
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        summarizer.saveKey(value, for: provider)
        keyDraft = ""
    }
}
