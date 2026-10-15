import SwiftUI

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    /// Where the search query was found in the transcript, for the row's subtitle.
    var snippet: String?
    var id: String { url.path }
}

enum RecordingsStore {
    static let limit = 30

    /// The newest `.mov`/`.mp4` files in the output folder; all of them when `limit` is nil.
    static func load(from folder: URL, limit: Int? = RecordingsStore.limit) -> [RecordingItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        let items = files
            .filter { $0.pathExtension.lowercased() == "mov" || $0.pathExtension.lowercased() == "mp4" }
            .compactMap { url -> RecordingItem? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                return RecordingItem(url: url, date: date, size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
        return limit.map { Array(items.prefix($0)) } ?? items
    }

    /// Recordings whose name or transcripts contain `query` (case-insensitive), newest first.
    static func search(_ query: String, in folder: URL) -> [RecordingItem] {
        load(from: folder, limit: nil).compactMap { item in
            var item = item
            if item.url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) { return item }
            for transcript in RecordingFiles.companions(of: item.url) where transcript.pathExtension == "md" {
                guard let text = try? String(contentsOf: transcript, encoding: .utf8),
                      let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                item.snippet = snippet(in: text, around: range)
                return item
            }
            return nil
        }
    }

    private static func snippet(in text: String, around range: Range<String.Index>) -> String {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var line = String(text[lineStart..<lineEnd])
        // Drop the "[00:12:34] Name:" prefix when the match is in the text itself.
        if let bracket = line.range(of: #"^\[[\d:]+\] "#, options: .regularExpression) {
            line.removeSubrange(bracket)
        }
        let offset = line.range(of: String(text[range]), options: .caseInsensitive)?.lowerBound
        if let offset, line.distance(from: line.startIndex, to: offset) > 40 {
            line = "…" + line[line.index(offset, offsetBy: -30)...]
        }
        return line
    }
}

/// Recent recordings with their transcription state: done (opens the transcript), progress while
/// running, queued, failed (retry), or a button to transcribe. A collapsible card; the summary line
/// shows the count, how many are transcribed and a running transcription's progress. The search field
/// looks through file names and the text of all transcripts.
struct RecordingsSection: View {
    @Binding var isExpanded: Bool
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @State private var items: [RecordingItem] = []
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        CollapsibleSection(title: "Записи", icon: "film.stack", summary: summary, isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск по названиям и транскриптам", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

                if items.isEmpty {
                    Text(query.isEmpty ? "Пока нет записей в папке «\(model.folderURL.lastPathComponent)»" : "Ничего не найдено")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                RecordingRow(item: item, onChange: reload)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(items.count) * 42, 230))
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.lastFile) { reload() }
        .onChange(of: model.folderPath) { reload() }
        .onChange(of: transcriber.transcriptsVersion) { reload() }
        .onChange(of: query) { reload() }
    }

    private var summary: String {
        guard !items.isEmpty || !query.isEmpty else { return "Пока пусто" }
        if let running = transcriber.runningFile, items.contains(where: { $0.url == running }) {
            let percent = transcriber.progress.map { " \(Int($0 * 100))%" } ?? ""
            return "Транскрибируется\(percent) · всего \(countText)"
        }
        if !query.isEmpty { return "Найдено: \(items.count)" }
        let transcribed = items.filter { Transcriber.existingTranscript(for: $0.url) != nil }.count
        return "\(countText) · с текстом: \(transcribed)"
    }

    private var countText: String {
        "\(items.count)\(items.count == RecordingsStore.limit ? "+" : "")"
    }

    private func reload() {
        let text = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        guard !text.isEmpty else {
            items = RecordingsStore.load(from: model.folderURL)
            return
        }
        let folder = model.folderURL
        // Reading every transcript takes a moment with many recordings: debounce and search off the main thread.
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { RecordingsStore.search(text, in: folder) }.value
            guard !Task.isCancelled else { return }
            items = found
        }
    }
}

struct RecordingRow: View {
    let item: RecordingItem
    /// Called after the file was renamed or moved to the Trash.
    let onChange: () -> Void
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @State private var hovering = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var error: String?
    @FocusState private var titleFocused: Bool

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
                if renaming {
                    TextField("Название", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .focused($titleFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                } else {
                    Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Text(error ?? subtitle)
                    .font(.caption2)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if !renaming { status }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !renaming { NSWorkspace.shared.open(item.url) } }
        .help("Открыть видео")
        .contextMenu {
            Button("Открыть видео") { NSWorkspace.shared.open(item.url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let transcript = Transcriber.existingTranscript(for: item.url) {
                Divider()
                Button("Просмотреть транскрипцию") { QuickLookPresenter.shared.preview(transcript) }
                Button("Открыть транскрипцию в редакторе") { NSWorkspace.shared.open(transcript) }
                Button("Транскрибировать заново") { transcriber.enqueue(item.url) }
                    .disabled(transcriber.modelsState != .ready || isBusy)
            } else {
                Button("Транскрибировать") { transcriber.enqueue(item.url) }
                    .disabled(transcriber.modelsState != .ready || isBusy)
            }
            Divider()
            Button("Переименовать…", action: startRename)
                .disabled(isLocked)
            Button("Переместить в Корзину", action: moveToTrash)
                .disabled(isLocked)
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
                QuickLookPresenter.shared.preview(transcript)
            } label: {
                Image(systemName: "doc.text.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Просмотреть транскрипцию (правый клик — открыть в редакторе)")
        } else if let failure = transcriber.failures[item.url.path] {
            Button {
                transcriber.enqueue(item.url)
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Ошибка: \(failure). Нажмите, чтобы повторить")
        } else if transcriber.modelsState == .ready && !isBeingRecorded {
            Button {
                transcriber.enqueue(item.url)
            } label: {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Транскрибировать")
        }
    }

    // MARK: - Actions

    private var isBeingRecorded: Bool { model.recordingFile == item.url }
    private var isBusy: Bool { transcriber.runningFile == item.url || transcriber.queue.contains(item.url) || isBeingRecorded }
    /// Renaming or deleting a file that is being written or transcribed would break that job.
    private var isLocked: Bool { isBusy }

    private func startRename() {
        newTitle = parts.title
        error = nil
        renaming = true
        DispatchQueue.main.async { titleFocused = true }
    }

    /// Applies the new title; the recording's date and time stay at the end of the name.
    private func commitRename() {
        renaming = false
        let title = RecordingFiles.sanitize(newTitle)
        let stem = [title, parts.timestamp].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        guard !stem.isEmpty, !isLocked else { return }
        do {
            let renamed = try RecordingFiles.rename(item.url, to: stem)
            model.recordingMoved(from: item.url, to: renamed)
            onChange()
        } catch {
            self.error = "Не удалось переименовать: \(error.localizedDescription)"
            Log.error("Rename of \(item.url.lastPathComponent) failed: \(Log.describe(error))", "files")
        }
    }

    private func moveToTrash() {
        guard !isLocked else { return }
        do {
            try RecordingFiles.trash(item.url)
            model.recordingMoved(from: item.url, to: nil)
            onChange()
        } catch {
            self.error = "Не удалось удалить: \(error.localizedDescription)"
            Log.error("Trash of \(item.url.lastPathComponent) failed: \(Log.describe(error))", "files")
        }
    }

    // MARK: - Text

    private var parts: (title: String, timestamp: String?) {
        RecordingFiles.split(item.url.deletingPathExtension().lastPathComponent)
    }

    private var title: String {
        // "yyyy-MM-dd HH-mm-ss" alone (MeetRec / OBS default) reads better as a date.
        parts.title.isEmpty ? Self.dateFormatter.string(from: item.date) : parts.title
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        if let snippet = item.snippet { return snippet }
        // Date-only names already show the date as the title.
        return parts.title.isEmpty ? size : "\(Self.dateFormatter.string(from: item.date)) · \(size)"
    }
}
