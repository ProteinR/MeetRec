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

    /// Where Teams auto-recordings' transcripts are also copied (a work docs repo).
    private var meetingsFolder: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Копировать транскрипты встреч Teams в")
            HStack {
                Image(systemName: "folder")
                Text(transcriber.meetingTranscriptsFolder.isEmpty
                     ? "не копировать"
                     : URL(fileURLWithPath: transcriber.meetingTranscriptsFolder).lastPathComponent)
                    .foregroundStyle(transcriber.meetingTranscriptsFolder.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(transcriber.meetingTranscriptsFolder)
                Spacer()
                Button("Изменить") { transcriber.chooseMeetingTranscriptsFolder() }
                if !transcriber.meetingTranscriptsFolder.isEmpty {
                    Button("Убрать") { transcriber.meetingTranscriptsFolder = "" }
                }
            }
            Text("Только автозаписи встреч Teams длиннее \(Int(Transcriber.minimumMeetingDuration / 60)) мин. Транскрипт остаётся и рядом с видео; файл в этой папке никогда не перезаписывается.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

/// One line under the main controls while a transcription runs, failed, or just finished.
struct TranscriptionStatus: View {
    @EnvironmentObject private var transcriber: Transcriber

    var body: some View {
        switch transcriber.job {
        case .running(let file, let phase, let startedAt):
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let percent = transcriber.progress.map { " · \(Int($0 * 100))%" } ?? ""
                        Text("Транскрибация\(percent) · \(Self.format(context.date.timeIntervalSince(startedAt)))")
                            .font(.callout).monospacedDigit()
                    }
                    Text("\(phase) — \(file.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                    if !transcriber.queue.isEmpty {
                        Text("В очереди: \(transcriber.queue.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Стоп") { transcriber.cancelCurrent() }.buttonStyle(.link)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if let transcript = transcriber.lastTranscript {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        QuickLookPresenter.shared.preview(transcript)
                    } label: {
                        Label("Просмотреть транскрипцию", systemImage: "doc.text")
                    }
                    .buttonStyle(.link)
                    if let summary = transcriber.lastSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
