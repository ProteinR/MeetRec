import SwiftUI

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    var id: String { url.path }
}

enum RecordingsStore {
    static let limit = 30

    /// The newest `.mov` files in the output folder.
    static func load(from folder: URL) -> [RecordingItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mov" || $0.pathExtension.lowercased() == "mp4" }
            .compactMap { url -> RecordingItem? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                return RecordingItem(url: url, date: date, size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}

/// Recent recordings with their transcription state: done (opens the transcript), progress while
/// running, queued, failed (retry), or a button to transcribe. A collapsible card; the summary line
/// shows the count, how many are transcribed and a running transcription's progress.
struct RecordingsSection: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @State private var items: [RecordingItem] = []

    var body: some View {
        CollapsibleSection(title: "Записи", icon: "film.stack", summary: summary, isExpanded: $isExpanded) {
            if items.isEmpty {
                Text("Пока нет записей в папке «\(model.folderURL.lastPathComponent)»")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            RecordingRow(item: item)
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 42, 230))
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.lastFile) { reload() }
        .onChange(of: model.folderPath) { reload() }
        .onChange(of: transcriber.transcriptsVersion) { reload() }
    }

    private var summary: String {
        guard !items.isEmpty else { return "Пока пусто" }
        if let running = transcriber.runningFile, items.contains(where: { $0.url == running }) {
            let percent = transcriber.progress.map { " \(Int($0 * 100))%" } ?? ""
            return "Транскрибируется\(percent) · всего \(countText)"
        }
        let transcribed = items.filter { Transcriber.existingTranscript(for: $0.url) != nil }.count
        return "\(countText) · с текстом: \(transcribed)"
    }

    private var countText: String {
        "\(items.count)\(items.count == RecordingsStore.limit ? "+" : "")"
    }

    private func reload() {
        items = RecordingsStore.load(from: model.folderURL)
    }
}

struct RecordingRow: View {
    let item: RecordingItem
    @EnvironmentObject private var transcriber: Transcriber
    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .help("Открыть видео")
        .contextMenu {
            Button("Открыть видео") { NSWorkspace.shared.open(item.url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let transcript = Transcriber.existingTranscript(for: item.url) {
                Button("Открыть транскрипцию") { NSWorkspace.shared.open(transcript) }
            }
            Button("Транскрибировать") { transcriber.enqueue(item.url) }
                .disabled(transcriber.modelsState != .ready)
        }
    }

    @ViewBuilder
    private var status: some View {
        if transcriber.runningFile == item.url {
            HStack(spacing: 4) {
                if let progress = transcriber.progress {
                    Text("\(Int(progress * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .help("Транскрибируется")
        } else if transcriber.queue.contains(item.url) {
            Image(systemName: "clock").foregroundStyle(.secondary).help("В очереди на транскрибацию")
        } else if let transcript = Transcriber.existingTranscript(for: item.url) {
            Button {
                NSWorkspace.shared.open(transcript)
            } label: {
                Image(systemName: "doc.text.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Открыть транскрипцию")
        } else if let failure = transcriber.failures[item.url.path] {
            Button {
                transcriber.enqueue(item.url)
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Ошибка: \(failure). Нажмите, чтобы повторить")
        } else if transcriber.modelsState == .ready {
            Button {
                transcriber.enqueue(item.url)
            } label: {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Транскрибировать")
        }
    }

    private var title: String {
        // MeetRec / OBS names are "yyyy-MM-dd HH-mm-ss"; show those as a readable date.
        isDateNamed ? Self.dateFormatter.string(from: item.date) : item.url.deletingPathExtension().lastPathComponent
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        // Date-named files already show the date as the title.
        return isDateNamed ? size : "\(Self.dateFormatter.string(from: item.date)) · \(size)"
    }

    private var isDateNamed: Bool {
        item.url.deletingPathExtension().lastPathComponent
            .range(of: #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}
