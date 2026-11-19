import AppKit
import SwiftUI

/// "Записи" on the main page: a search field and the recordings as a row of previews, newest first,
/// loaded a page at a time while scrolling. Each tile shows a frame from the middle of the video,
/// the duration, markers and the transcript state; while the pointer is over it, a tip next to the
/// pointer plays frames from the whole recording in a bigger preview and gives name, time, size and
/// state.
/// Renaming and speaker naming open under the row for the tile they belong to.
struct RecordingsSection: View {
    /// "236" (while searching "12 из 236") for the tab's title.
    @Binding var count: String?
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    // The main page is made anew when coming back from the settings: it starts with the last list,
    // so the row is there from the first frame of the slide instead of popping in during it.
    @State private var items: [RecordingItem] = RecordingsSection.last.items
    @State private var total = RecordingsSection.last.total
    @State private var transcribed = RecordingsSection.last.transcribed
    @State private var shown = max(RecordingsSection.pageSize, RecordingsSection.last.items.count)
    @State private var query = ""
    @State private var loadTask: Task<Void, Never>?
    @State private var detail: Detail?
    @State private var newTitle = ""
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    static let pageSize = 30
    /// The last list read (not a search result).
    private static var last: (items: [RecordingItem], total: Int, transcribed: Int) = ([], 0, 0)

    enum Detail: Equatable {
        case rename(RecordingItem)
        case speakers(RecordingItem)

        var item: RecordingItem {
            switch self {
            case .rename(let item), .speakers(let item): item
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchRow
            if items.isEmpty {
                Text(query.isEmpty ? String(localized: "Здесь появятся записи и их транскрипты. Начните запись кнопкой выше, или MeetRec начнёт её сам, когда начнётся встреча.") : String(localized: "Ничего не найдено"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HorizontalStrip(items: items, tileWidth: Thumbnails.videoSize.width, onReachEnd: loadMore) { item in
                    RecordingTile(item: item, query: query.trimmingCharacters(in: .whitespaces), onChange: reload, show: show)
                }
                .frame(height: Thumbnails.videoSize.height + 20)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let detail { detailView(detail) }
        }
        .onAppear(perform: reload)
        .onChange(of: countLabel, initial: true) { count = countLabel }
        // Files may have been renamed, moved or deleted in Finder since the list was read.
        .onChange(of: model.panelVisible) { if model.panelVisible { reload() } else { detail = nil; error = nil } }
        .onChange(of: model.lastFile) { reload() }
        .onChange(of: model.folderPath) { reload() }
        .onChange(of: transcriber.transcriptsVersion) { reload() }
        .onChange(of: query) {
            shown = Self.pageSize
            reload()
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
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
            Button { model.openFolder() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Открыть папку «\(model.folderURL.lastPathComponent)» в Finder")
        }
    }

    // MARK: - Under the row

    @ViewBuilder
    private func detailView(_ detail: Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(RecordingTile.title(of: detail.item)).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button { self.detail = nil } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.borderless)
                    .help("Закрыть")
            }
            switch detail {
            case .rename:
                TextField("Название", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit { commitRename(detail.item) }
                    .onExitCommand { self.detail = nil }
            case .speakers(let item):
                SpeakersEditor(recording: item.url) {
                    self.detail = nil
                    reload()
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func show(_ detail: Detail?, _ message: String?) {
        error = message
        withAnimation(.smooth(duration: 0.2)) { self.detail = detail }
        if case .rename(let item) = detail {
            newTitle = RecordingFiles.split(item.url.deletingPathExtension().lastPathComponent).title
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    /// Applies the new title; the recording's date and time stay first in the name.
    private func commitRename(_ item: RecordingItem) {
        detail = nil
        let parts = RecordingFiles.split(item.url.deletingPathExtension().lastPathComponent)
        let title = RecordingFiles.sanitize(newTitle)
        let stem = RecordingFiles.stem(timestamp: parts.timestamp, title: title)
        guard !stem.isEmpty, stem != item.url.deletingPathExtension().lastPathComponent,
              model.recordingFile != item.url, transcriber.runningFile != item.url, !transcriber.queue.contains(item.url) else { return }
        do {
            let renamed = try RecordingFiles.rename(item.url, to: stem)
            model.recordingMoved(from: item.url, to: renamed)
            reload()
        } catch {
            self.error = String(localized: "Не удалось переименовать: \(error.localizedDescription)")
            Log.error("Rename of \(item.url.lastPathComponent) failed: \(Log.describe(error))", "files")
        }
    }

    // MARK: - Loading

    /// "236"; while searching "12 из 236".
    private var countLabel: String? {
        guard total > 0 else { return nil }
        if !query.isEmpty { return String(localized: "\(items.count.formatted()) из \(total.formatted())") }
        return total.formatted()
    }

    private func loadMore() {
        guard query.isEmpty, items.count < total, items.count >= shown else { return }
        shown += Self.pageSize
        reload()
    }

    /// Off the main thread: listing a big folder and reading markers takes a moment; a search reads
    /// every transcript (debounced while typing).
    private func reload() {
        let text = query.trimmingCharacters(in: .whitespaces)
        let folder = model.folderURL
        let limit = shown
        loadTask?.cancel()
        loadTask = Task {
            if !text.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = await Task.detached(priority: .userInitiated) { RecordingsStore.search(text, in: folder) }.value
                guard !Task.isCancelled else { return }
                items = found
                return
            }
            let page = await Task.detached(priority: .userInitiated) { RecordingsStore.page(from: folder, limit: limit) }.value
            guard !Task.isCancelled else { return }
            items = page.items
            total = page.total
            transcribed = page.transcribed
            Self.last = page
        }
    }
}

struct RecordingTile: View {
    let item: RecordingItem
    /// The search text: the transcript in the tip starts where it is found.
    var query = ""
    /// After the file was renamed, moved to the Trash or got chapters.
    let onChange: () -> Void
    /// Opens a rename field or the speakers under the row, or shows an error there.
    let show: (RecordingsSection.Detail?, String?) -> Void
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @State private var poster: NSImage?
    @State private var duration: Double?

    init(item: RecordingItem, query: String = "", onChange: @escaping () -> Void,
         show: @escaping (RecordingsSection.Detail?, String?) -> Void) {
        self.item = item
        self.query = query
        self.onChange = onChange
        self.show = show
        // Already made: shown at once, not a frame later.
        let cached = Thumbnails.cachedVideo(item.url)
        _poster = State(initialValue: cached?.poster)
        _duration = State(initialValue: cached?.duration)
    }
    @State private var hovering = false
    @State private var frames: [NSImage] = []
    @State private var frameIndex = 0
    @State private var addingChapters = false
    /// The pointer is on the transcript badge (bottom left): the tip shows the transcript, a click
    /// opens it.
    @State private var overBadge = false
    @State private var transcript: TranscriptPreview?
    /// What the summaries of this recording took (`summary.json`), read when the pointer comes.
    @State private var summaryRuns: [SummaryUsage] = []

    private static let size = Thumbnails.videoSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            picture
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.size.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .hoverTip(tip, id: "recording:\(item.id)")
        .contextMenu { menu }
        .task(id: "\(item.id)#\(item.size)#\(isBeingRecorded)") {
            guard !isBeingRecorded else { return }
            let video = await Thumbnails.video(item.url)
            poster = video.poster
            duration = video.duration
        }
        // Frames from the whole recording in the tip while the pointer stays on the tile.
        .task(id: "\(hovering)#\(transcriber.transcriptsVersion)") {
            guard hovering else { return }
            let url = item.url
            summaryRuns = await Task.detached(priority: .userInitiated) { SummaryUsageFile.load(for: url) }.value
        }
        .task(id: hovering) {
            guard hovering, !isBeingRecorded else {
                frames = []
                frameIndex = 0
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let loaded = await Thumbnails.hoverFrames(item.url)
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            frames = loaded
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { break }
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
    }

    // MARK: - Picture

    private var picture: some View {
        // The cell sets the size and the picture fills it as an overlay (see ScreenshotThumbnail).
        Color.primary.opacity(0.08)
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay {
                if isBeingRecorded {
                    ZStack {
                        Color.red.opacity(0.85)
                        Label("Идёт запись", systemImage: "record.circle").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                } else if let poster {
                    Image(nsImage: poster).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .topLeading) {
                if !markerText.isEmpty {
                    TileBadge { Text(markerText) }.padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) { badgeArea }
            .overlay(alignment: .bottomTrailing) {
                if let duration, !isBeingRecorded {
                    TileBadge { Text(Self.durationText(duration)) }.padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hovering ? 2 : 0.5))
    }

    /// The badge with a larger area around it (the badge alone is hard to hit): hovering it outlines
    /// it and turns the tip into the transcript, a click opens the transcript file.
    private var badgeArea: some View {
        let file = Transcriber.existingTranscript(for: item.url)
        let active = overBadge && (file != nil || transcriber.runningFile == item.url)
        return statusBadge
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5).padding(-2)
                }
            }
            .padding(4)
            .frame(minWidth: 32, minHeight: 28, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .onHover { inside in
                overBadge = inside
                guard file != nil else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture {
                if let file { NSWorkspace.shared.open(file) } else { NSWorkspace.shared.open(item.url) }
            }
            .task(id: overBadge) {
                guard overBadge, let file else { return }
                let query = query
                transcript = await Task.detached(priority: .userInitiated) { TranscriptPreview.load(file, query: query) }.value
            }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if transcriber.runningFile == item.url {
            TileBadge { Text(transcriber.progress.map { "\(Int($0 * 100))%" } ?? "…") }
        } else if transcriber.queue.contains(item.url) {
            TileBadge { Image(systemName: "clock") }
        } else if summarizer.running.contains(item.url.path) {
            // No animation: it would redraw the whole card every frame.
            TileBadge { Label("резюме…", systemImage: "sparkles").labelStyle(.titleAndIcon) }
        } else if Transcriber.existingTranscript(for: item.url) != nil {
            TileBadge { Image(systemName: "doc.text") }
        } else if transcriber.failures[item.url.path] != nil {
            TileBadge { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menu: some View {
        Button("Открыть видео") { NSWorkspace.shared.open(item.url) }
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button(RecordingFiles.ownFolder(of: item.url) == nil ? String(localized: "Скопировать путь к видео") : String(localized: "Скопировать путь к папке записи"),
               action: copyPath)
        if let transcript = Transcriber.existingTranscript(for: item.url) {
            Divider()
            Button("Просмотреть транскрипт") { QuickLookPresenter.shared.preview(transcript) }
            Button("Открыть транскрипт в редакторе") { NSWorkspace.shared.open(transcript) }
            Button("Подписать спикеров…") { show(.speakers(item), nil) }
                .disabled(!SpeakerNaming.hasSpeakers(item.url) || isBusy)
            summaryItem
            Button("Транскрибировать заново") { transcriber.enqueue(item.url) }
                .disabled(transcriber.modelsState != .ready || isBusy)
        } else {
            Divider()
            Button("Транскрибировать") { transcriber.enqueue(item.url) }
                .disabled(transcriber.modelsState != .ready || isBusy)
        }
        if transcriber.runningFile == item.url {
            Button("Остановить транскрибацию") { transcriber.cancelCurrent() }
        }
        if !item.markers.isEmpty {
            Divider()
            Menu(String(localized: "Отметки (\(item.markers.count))")) {
                ForEach(Array(item.markers.enumerated()), id: \.offset) { _, marker in
                    Button(marker.label) { QuickTimeOpener.open(item.url, at: marker.time) }
                }
            }
            Button(addingChapters ? String(localized: "Добавляю главы…") : String(localized: "Добавить отметки в видео как главы")) { addChapters() }
                .disabled(addingChapters || isBusy)
        }
        Divider()
        Button("Переименовать…") { show(.rename(item), nil) }
            .disabled(isBusy)
        Button("Удалить", action: moveToTrash)
            .disabled(isBusy)
    }

    /// "Сделать резюме" (or again); before a provider is set up it opens that part of the settings.
    @ViewBuilder
    private var summaryItem: some View {
        if summarizer.running.contains(item.url.path) {
            Button("Пишу резюме…") {}.disabled(true)
        } else if !summarizer.isConfigured {
            Button("Сделать резюме… (настроить ИИ)") { model.requestSettings(.transcription) }
        } else {
            Button(Summarizer.hasSummary(item.url) ? String(localized: "Сделать резюме заново") : String(localized: "Сделать резюме")) {
                Task { await summarizer.summarize(item.url) }
            }
            .disabled(isBusy)
        }
    }

    /// The recording's own folder (video, transcripts, markers, speakers), so an agent given the path
    /// finds everything; the video itself for a recording of the older flat layout.
    private func copyPath() {
        let path = (RecordingFiles.ownFolder(of: item.url) ?? item.url).path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Log.info("Path copied: \(path)", "files")
    }

    private var isBeingRecorded: Bool { model.recordingFile == item.url }
    /// Renaming or deleting a file that is being written or transcribed would break that job.
    private var isBusy: Bool { transcriber.runningFile == item.url || transcriber.queue.contains(item.url) || isBeingRecorded }

    /// For recordings made before markers became chapters automatically.
    private func addChapters() {
        addingChapters = true
        Task {
            do {
                try await ChapterWriter.addChapters(item.markers, to: item.url)
                onChange()
            } catch {
                show(nil, String(localized: "Главы не добавлены: \(error.localizedDescription)"))
                Log.warning("Chapters not added to \(item.url.lastPathComponent): \(Log.describe(error))", "files")
            }
            addingChapters = false
        }
    }

    private func moveToTrash() {
        guard !isBusy else { return }
        do {
            try RecordingFiles.trash(item.url)
            model.recordingMoved(from: item.url, to: nil)
            show(nil, nil)
            onChange()
        } catch {
            show(nil, String(localized: "Не удалось удалить: \(error.localizedDescription)"))
            Log.error("Trash of \(item.url.lastPathComponent) failed: \(Log.describe(error))", "files")
        }
    }

    // MARK: - Text

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // The app's own language (Russian or English), not the system region.
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "ru")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "ru")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The name without its timestamp; a name that is only a timestamp reads better as a date.
    static func title(of item: RecordingItem) -> String {
        let title = RecordingFiles.split(item.url.deletingPathExtension().lastPathComponent).title
        return title.isEmpty ? String(localized: "Запись") : title
    }

    /// "Skyeng · 14:03", "Weekly sync · вчера 14:03", "Запись · 14 окт".
    private var caption: String {
        if let snippet = item.snippet { return snippet }
        return "\(Self.title(of: item)) · \(ScreenshotsSection.when(item.date))"
    }

    /// "52:10", "1:10:22".
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var markerText: String {
        let pauses = item.markers.filter(\.isPause).count
        let stars = item.markers.count - pauses
        return stars > 0 ? "⭐ \(stars)" : ""
    }

    private var tip: HoverTipContent {
        var lines: [String] = []
        var when = Self.dateFormatter.string(from: item.date)
        if let duration { when += "–" + Self.timeFormatter.string(from: item.date.addingTimeInterval(duration)) }
        lines.append(when)
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        var facts = [duration.map(Self.durationText), size].compactMap { $0 }
        if RecordingTag.meetingApp(of: item.url) == "teams" { facts.insert("Teams", at: 0) }
        let stars = item.markers.filter { !$0.isPause }.count, pauses = item.markers.count - stars
        if stars > 0 { facts.append("⭐ \(stars)") }
        if pauses > 0 { facts.append("⏸ \(pauses)") }
        lines.append(facts.joined(separator: " · "))
        lines.append(transcriptState)
        if let last = summaryRuns.last {
            var line = String(localized: "Резюме: \(last.shortText)")
            if summaryRuns.count > 1 {
                let total = summaryRuns.compactMap(\.costUSD).reduce(0, +)
                line += " " + String(localized: "(запусков: \(summaryRuns.count), всего \(SummaryUsage.money(total)))")
            }
            lines.append(line)
        }
        if overBadge, transcriber.runningFile == item.url {
            return HoverTipContent(title: Self.title(of: item), lines: [transcriptState])
        }
        if overBadge, let transcript {
            let words = String(localized: "\(transcript.words) слов")
            var facts = [words]
            if let engine = transcript.engine { facts.append(engine) }
            if transcript.isSummary, let last = summaryRuns.last { facts.append(last.shortText) }
            return HoverTipContent(title: transcript.isSummary ? String(localized: "Резюме") : String(localized: "Транскрипт"),
                                   lines: [], hint: (facts + [String(localized: "клик — открыть")]).joined(separator: " · "),
                                   transcript: transcript, highlight: query.isEmpty ? nil : query)
        }
        if let snippet = item.snippet { lines.append("«\(snippet)»") }
        // The poster until the frames are read (from the cache at once, else in a moment).
        let frame = frames.isEmpty ? nil : frames[min(frameIndex, frames.count - 1)]
        return HoverTipContent(title: Self.title(of: item), lines: lines,
                               hint: String(localized: "Клик — открыть, правый клик — ещё"),
                               preview: isBeingRecorded ? nil : frame ?? poster,
                               progress: frame == nil ? nil : Double(frameIndex + 1) / Double(frames.count))
    }

    private var transcriptState: String {
        if isBeingRecorded { return String(localized: "Идёт запись") }
        if transcriber.runningFile == item.url {
            return transcriber.progress.map { String(localized: "Транскрибируется: \(Int($0 * 100))%") } ?? String(localized: "Транскрибируется")
        }
        if transcriber.queue.contains(item.url) { return String(localized: "В очереди на транскрибацию") }
        if summarizer.running.contains(item.url.path) { return String(localized: "Транскрипт готов, пишу резюме…") }
        if Transcriber.existingTranscript(for: item.url) != nil {
            if let failure = summarizer.failures[item.url.path] { return String(localized: "Транскрипт готов; резюме не написано: \(failure)") }
            return String(localized: "Транскрипт готов")
        }
        if let failure = transcriber.failures[item.url.path] { return String(localized: "Ошибка транскрибации: \(failure)") }
        return String(localized: "Без транскрипта")
    }
}
