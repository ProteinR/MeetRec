import Foundation

/// A speaker found by diarization in one recording (from `runs/<recording>.json`, written by
/// `transcribe.py`): its label, the name it got in the transcript and how sure the match was.
struct RunSpeaker: Identifiable, Equatable {
    let label: String
    let name: String
    let minutes: Double
    /// Closest known voice and its similarity (0…1); the name is assigned at 0.7 and above.
    let closest: String?
    let score: Double?
    /// The speaker's first words in the transcript, to tell who is who.
    let firstWords: String?
    var id: String { label }
}

/// Naming speakers of a finished recording: the speaker's voice print from that recording is added
/// to the chosen person in `speakers.json` (a new person or an extra sample), so the next
/// transcriptions recognise them, and the transcript is updated.
enum SpeakerNaming {
    enum Failure: LocalizedError {
        case noRun, noEmbedding(String)
        var errorDescription: String? {
            switch self {
            case .noRun: return "Нет данных о голосах: транскрибируйте запись с разбивкой по ролям"
            case .noEmbedding(let label): return "Нет отпечатка голоса для \(label)"
            }
        }
    }

    static var runsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/runs", isDirectory: true)
    }

    static func runURL(for recording: URL) -> URL {
        runsDir.appendingPathComponent(recording.deletingPathExtension().lastPathComponent).appendingPathExtension("json")
    }

    static func hasSpeakers(_ recording: URL) -> Bool {
        FileManager.default.fileExists(atPath: runURL(for: recording).path)
    }

    /// Speakers of the recording, most talkative first; nil without diarization data.
    @MainActor
    static func speakers(of recording: URL) -> [RunSpeaker]? {
        guard let run = loadRun(recording),
              let names = run["names"] as? [String: String], !names.isEmpty else { return nil }
        let scores = run["scores"] as? [String: [String: Any]] ?? [:]
        var seconds: [String: Double] = [:]
        for turn in run["turns"] as? [[String: Any]] ?? [] {
            guard let label = turn["speaker"] as? String, let start = turn["start"] as? Double,
                  let end = turn["end"] as? Double else { continue }
            seconds[label, default: 0] += end - start
        }
        let transcript = Transcriber.existingTranscript(for: recording).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return names.map { label, name in
            RunSpeaker(label: label, name: name, minutes: (seconds[label] ?? 0) / 60,
                       closest: scores[label]?["name"] as? String, score: scores[label]?["score"] as? Double,
                       firstWords: transcript.flatMap { firstWords(of: name, in: $0) })
        }
        .sorted { $0.minutes > $1.minutes }
    }

    /// Names `label` in this recording as `newName`: stores its voice print and updates the transcript.
    /// The copy in the meetings folder is updated only if nobody has edited it yet.
    @MainActor
    static func assign(_ label: String, in recording: URL, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var run = loadRun(recording), var names = run["names"] as? [String: String] else { throw Failure.noRun }
        guard let embedding = (run["embeddings"] as? [String: [Double]])?[label] else { throw Failure.noEmbedding(label) }
        let oldName = names[label] ?? label

        // 1. Voice print: one more sample for this person (skipped if this very sample is already there).
        let transcriber = Transcriber.shared
        var references = (try? JSONSerialization.jsonObject(with: Data(contentsOf: transcriber.speakersFile))) as? [String: [[Double]]] ?? [:]
        var samples = references[name] ?? []
        if !samples.contains(where: { cosine($0, embedding) > 0.9999 }) {
            samples.append(embedding)
            references[name] = samples
            let data = try JSONSerialization.data(withJSONObject: references)
            try data.write(to: transcriber.speakersFile, options: .atomic)
            Log.info("Voice sample added for \(name) from \(recording.lastPathComponent) (\(label)); now \(samples.count) sample(s)", "transcribe")
        }
        transcriber.loadSpeakers()

        guard oldName != name else { return }
        // 2. Diarization record, so the list shows the new name. Speakers sharing the old name are one
        // person in the text (a "one other person" call, the user heard in two voices): all renamed.
        for (other, value) in names where value == oldName { names[other] = name }
        run["names"] = names
        try JSONSerialization.data(withJSONObject: run).write(to: runURL(for: recording), options: .atomic)

        // 3. Transcript next to the video (and the untouched copy in the meetings folder).
        guard let transcript = Transcriber.existingTranscript(for: recording),
              let original = try? String(contentsOf: transcript, encoding: .utf8) else { return }
        let updated = rename(oldName, to: name, in: original)
        try updated.write(to: transcript, atomically: true, encoding: .utf8)
        Log.info("Transcript \(transcript.lastPathComponent): \"\(oldName)\" → \"\(name)\"", "transcribe")

        for folder in transcriber.copyFolders(for: recording) {
            let copy = folder.appendingPathComponent(recording.deletingPathExtension().lastPathComponent).appendingPathExtension("md")
            if let copied = try? String(contentsOf: copy, encoding: .utf8) {
                if copied == original {
                    try? updated.write(to: copy, atomically: true, encoding: .utf8)
                    Log.info("Meeting copy updated too: \(copy.path)", "transcribe")
                } else {
                    Log.info("Meeting copy \(copy.path) was edited; speaker names there left as they are", "transcribe")
                }
            }
        }
    }

    /// "[00:01:02] Speaker 1: …" → "[00:01:02] Dima: …", then joins neighbouring lines of one speaker,
    /// as the transcript does when it is written.
    static func rename(_ oldName: String, to newName: String, in text: String) -> String {
        let prefix = try! NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\] (.+?): "#)
        func parse(_ line: String) -> (speaker: String, nameRange: Range<String.Index>, body: Substring)? {
            guard let match = prefix.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let head = Range(match.range, in: line) else { return nil }
            return (String(line[nameRange]), nameRange, line[head.upperBound...])
        }
        var paragraphs: [String] = []
        var previousSpeaker: String?
        for paragraph in text.components(separatedBy: "\n\n") {
            guard var parsed = parse(paragraph) else {
                paragraphs.append(paragraph)
                previousSpeaker = nil
                continue
            }
            var line = paragraph
            if parsed.speaker == oldName {
                line.replaceSubrange(parsed.nameRange, with: newName)
                guard let reparsed = parse(line) else { paragraphs.append(line); continue }
                parsed = reparsed
            }
            if parsed.speaker == previousSpeaker, let last = paragraphs.popLast() {
                paragraphs.append(last.trimmingCharacters(in: .newlines) + " " + parsed.body.trimmingCharacters(in: .newlines))
            } else {
                paragraphs.append(line)
            }
            previousSpeaker = parsed.speaker
        }
        let result = paragraphs.joined(separator: "\n\n")
        return text.hasSuffix("\n") && !result.hasSuffix("\n") ? result + "\n" : result
    }

    // MARK: - Private

    private static func loadRun(_ recording: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: runURL(for: recording)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func firstWords(of name: String, in transcript: String) -> String? {
        for line in transcript.components(separatedBy: "\n") {
            guard let range = line.range(of: "] \(name): ") else { continue }
            let text = line[range.upperBound...]
            return text.count > 70 ? String(text.prefix(70)) + "…" : String(text)
        }
        return nil
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na * nb).squareRoot() : 0
    }
}
