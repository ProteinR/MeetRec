import SwiftUI

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    /// Where the search query was found in the transcript, for the row's subtitle.
    var snippet: String?
    /// Moments marked during the recording.
    var markers: [Marker] = []
    var id: String { url.path }
}

enum RecordingsStore {
    static let limit = 30

    /// The newest recordings in the output folder (`<stem>/<stem>.mov` and flat `.mov`/`.mp4`); all of
    /// them when `limit` is nil.
    static func load(from folder: URL, limit: Int? = RecordingsStore.limit) -> [RecordingItem] {
        page(from: folder, limit: limit).items
    }

    /// The newest `limit` recordings (all when nil), how many there are in all and how many of
    /// them have a transcript. Only the returned ones read their markers, so a folder with hundreds
    /// of recordings lists quickly.
    static func page(from folder: URL, limit: Int?) -> (items: [RecordingItem], total: Int, transcribed: Int) {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
        let isVideo = { (url: URL) in url.pathExtension.lowercased() == "mov" || url.pathExtension.lowercased() == "mp4" }
        let files = entries.flatMap { entry -> [URL] in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [entry] }
            // A folder is a recording when it holds a video of its own name (other folders are left alone).
            return ["mov", "mp4", "MOV", "MP4"].map { entry.appendingPathComponent(entry.lastPathComponent).appendingPathExtension($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(1).map { $0 }
        }
        let items = files
            .filter(isVideo)
            .map { url -> RecordingItem in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
                return RecordingItem(url: url, date: date, size: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
        let transcribed = items.filter { Transcriber.existingTranscript(for: $0.url) != nil }.count
        let shown = (limit.map { Array(items.prefix($0)) } ?? items).map { item -> RecordingItem in
            var item = item
            item.markers = MarkerFile.load(for: item.url)
            return item
        }
        return (shown, items.count, transcribed)
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

/// "Подписать спикеров": who is who in a finished recording. Each name given here also teaches
/// MeetRec that voice (an extra sample in speakers.json), so the next recordings name it themselves.
struct SpeakersEditor: View {
    let recording: URL
    let onDone: () -> Void
    @EnvironmentObject private var transcriber: Transcriber
    @State private var speakers: [RunSpeaker] = []
    @State private var names: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if speakers.isEmpty {
                Text("Нет данных о голосах. Транскрибируйте запись заново с разбивкой по ролям.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(speakers) { speaker in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(speaker.name).font(.callout.weight(.semibold))
                        Text("\(speaker.minutes, specifier: "%.1f") мин").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let closest = speaker.closest, let score = speaker.score {
                            // Similarity to the closest enrolled voice when transcribed; 70% and above names it.
                            Text(closest == speaker.name ? String(localized: "сходство \(Int((score * 100).rounded()))%")
                                                         : String(localized: "похож на \(closest) \(Int((score * 100).rounded()))%"))
                                .font(.caption2)
                                .foregroundStyle(score >= 0.7 ? Color.secondary : Color.orange)
                                .help("Сходство с ближайшим известным голосом во время транскрибации. Имя ставится автоматически от 70%.")
                        }
                    }
                    if let words = speaker.firstWords {
                        Text("«\(words)»").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 4) {
                        TextField("Кто это?", text: binding(for: speaker))
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(knownNames, id: \.self) { name in
                                Button(name) { names[speaker.label] = name }
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(knownNames.isEmpty)
                    }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
                    .disabled(speakers.isEmpty)
                Button("Отмена", action: onDone)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .onAppear {
            speakers = SpeakerNaming.speakers(of: recording) ?? []
            names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.label, $0.name) })
        }
    }

    /// Enrolled voices, the user's own name first.
    private var knownNames: [String] {
        let all = Set(transcriber.speakerSamples.keys).union(transcriber.myName.isEmpty ? [] : [transcriber.myName])
        return all.sorted { ($0 == transcriber.myName ? 0 : 1, $0) < ($1 == transcriber.myName ? 0 : 1, $1) }
    }

    private func binding(for speaker: RunSpeaker) -> Binding<String> {
        Binding(get: { names[speaker.label] ?? speaker.name }, set: { names[speaker.label] = $0 })
    }

    private func save() {
        message = nil
        do {
            for speaker in speakers {
                let name = (names[speaker.label] ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != speaker.name else { continue }
                try SpeakerNaming.assign(speaker.label, in: recording, to: name)
            }
            onDone()
        } catch {
            message = error.localizedDescription
            Log.error("Naming speakers in \(recording.lastPathComponent) failed: \(Log.describe(error))", "transcribe")
            speakers = SpeakerNaming.speakers(of: recording) ?? []
        }
    }
}
