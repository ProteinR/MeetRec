// MeetRec's commands: download the models, transcribe a recording, enroll a voice sample. They talk
// to the app through JSON lines on stdout ({"event": "phase"|"progress"|"done"|"error", …}); the log
// lines go to stderr, which the app writes to its log.
//
// Speech recognition and diarization each run in a child process of this same tool (`asr`,
// `diarize`): one model in memory at a time, and all of it gone when the step ends.
import AVFoundation
import Foundation

let engine = "Parakeet Ultra + FluidAudio diarization"
let defaultThreshold = 0.7

struct Failure: Error {
    let code: String
    let message: String
}

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    emitJSON(object)
}

func emitJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

/// Emits a progress event only when the value moved by at least 1 %.
final class Throttle {
    let stage: String
    private var last = -1.0

    init(_ stage: String) { self.stage = stage }

    func report(_ raw: Double) {
        let value = max(0, min(1, raw))
        if value - last >= 0.01 || (value >= 1 && last < 1) {
            last = value
            emit("progress", ["stage": stage, "value": rounded(value, 3)])
        }
    }
}

// MARK: - Child processes

/// The child running now, ended with this process (MeetRec cancels a job with SIGTERM).
nonisolated(unsafe) private var currentChild: Process?
/// The WAVs of the running job, removed also when MeetRec cancels it.
nonisolated(unsafe) var temporaryFolder: URL?
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

func forwardTerminationToChildren() {
    for value in [SIGTERM, SIGINT] {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler {
            currentChild?.terminate()
            if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
            exit(128 + value)
        }
        source.resume()
        signalSources.append(source)
    }
}

/// Runs this tool with `arguments` and forwards its progress to `report`; its last JSON line.
func runChild(_ arguments: [String], report: ((Double) -> Void)? = nil) async throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    currentChild = process
    var last: [String: Any] = [:]
    for try await line in pipe.fileHandleForReading.bytes.lines {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        last = object
        if let progress = object["progress"] as? Double { report?(progress) }
    }
    process.waitUntilExit()
    currentChild = nil
    if let error = last["error"] as? String { throw AudioError(message: "MeetRecASR: \(error)") }
    if process.terminationStatus != 0 { throw AudioError(message: "MeetRecASR: exit \(process.terminationStatus)") }
    return last
}

/// Recognised phrases of a WAV.
func recognise(_ wav: URL, report: ((Double) -> Void)? = nil) async throws -> [Segment] {
    let result = try await runChild(["asr", wav.path], report: report)
    let raw = (result["words"] as? [[Any]] ?? []).compactMap { item -> (text: String, start: Double, end: Double)? in
        guard item.count >= 3, let text = item[0] as? String, let start = item[1] as? Double, let end = item[2] as? Double else { return nil }
        return (text, start, end)
    }
    return phrases(withoutFillers(raw))
}

struct Diarization {
    var turns: [Turn]
    var embeddings: [String: [Double]]
    var seconds: Double
}

/// Who spoke when: FluidAudio's offline diarization (pyannote community-1 segmentation, WeSpeaker
/// embeddings, VBx clustering as CoreML models; turns without overlaps). The embeddings are the
/// same WeSpeaker voice prints pyannote gave, so `speakers.json` from before keeps working.
func diarize(_ wav: URL, report: ((Double) -> Void)? = nil) async throws -> Diarization {
    let started = Date()
    let result = try await runChild(["diarize", wav.path], report: report)
    let turns = (result["turns"] as? [[Any]] ?? []).compactMap { item -> Turn? in
        guard item.count >= 3, let start = item[0] as? Double, let end = item[1] as? Double,
              let speaker = item[2] as? String else { return nil }
        return Turn(start: start, end: end, speaker: speaker)
    }
    let embeddings = (result["embeddings"] as? [String: [Double]]) ?? [:]
    return Diarization(turns: turns, embeddings: embeddings, seconds: Date().timeIntervalSince(started))
}

// MARK: - download

func downloadCommand() async throws {
    emit("phase", ["name": tr("Скачивание модели распознавания речи", "Downloading the speech recognition model")])
    var started = Date()
    let throttle = Throttle("download")
    _ = try await runChild(["asr-download"], report: throttle.report)
    log("ASR model ready in \(Int(Date().timeIntervalSince(started)))s")
    emit("phase", ["name": tr("Скачивание модели разбивки по ролям", "Downloading the speaker diarization model")])
    started = Date()
    _ = try await runChild(["diarizer-download"])
    log("Diarization model ready in \(Int(Date().timeIntervalSince(started)))s")
    emit("done", ["message": tr("Модели готовы", "Models ready")])
}

// MARK: - transcribe

struct TranscribeOptions {
    var recording: URL
    var output: URL
    var noDiarization = false
    var speakers: URL?
    var runFile: URL?
    var threshold = defaultThreshold
    var me = ""
    var oneOther = false
    var mixed = false

    init(_ arguments: [String]) throws {
        var positional: [String] = []
        var output: String?
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < arguments.count else { throw Failure(code: "usage", message: "\(arguments[i - 1]) needs a value") }
            return arguments[i]
        }
        var runsDir: String?
        while i < arguments.count {
            switch arguments[i] {
            case "--output": output = try value()
            case "--no-diarization": noDiarization = true
            case "--speakers": speakers = URL(fileURLWithPath: try value())
            case "--run-file": runFile = URL(fileURLWithPath: try value())
            case "--runs-dir": runsDir = try value()
            case "--threshold": threshold = Double(try value()) ?? defaultThreshold
            case "--me": me = try value()
            case "--one-other": oneOther = true
            case "--mixed": mixed = true
            default: positional.append(arguments[i])
            }
            i += 1
        }
        guard let path = positional.first, let output else {
            throw Failure(code: "usage", message: "transcribe <recording> --output <md> [options]")
        }
        recording = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        self.output = URL(fileURLWithPath: output)
        if runFile == nil, let runsDir {
            runFile = URL(fileURLWithPath: runsDir).appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".json")
        }
    }
}

/// Mono 16 kHz WAVs of the recording: `audio.wav` of everyone, plus `microphone.wav` and
/// `system.wav` when the file has them apart, to tell the user from the other side; and their
/// loudness. The mix MeetRec adds for players is not used: the raw tracks are mixed without its gain.
struct ExtractedAudio {
    var everyone: URL
    var microphone: URL?
    var system: URL?
    var levels: Levels?
}

func extractAudio(_ recording: URL, into folder: URL) async throws -> ExtractedAudio {
    let asset = AVURLAsset(url: recording)
    let tracks = try await audioTracks(asset)
    if tracks.isEmpty { throw Failure(code: "no_audio", message: tr("В записи нет звука", "The recording has no audio")) }
    let roles = streamRoles(tracks.map(\.isDefault))
    var result = ExtractedAudio(everyone: folder.appendingPathComponent("audio.wav"))
    var everyone: [Float] = []
    if let roles {
        let microphone = try await decode(tracks[roles.microphone].track, of: asset)
        result.microphone = folder.appendingPathComponent("microphone.wav")
        try writeWAV(microphone, to: result.microphone!)
        var system = try await decode(tracks[roles.system].track, of: asset)
        result.system = folder.appendingPathComponent("system.wav")
        try writeWAV(system, to: result.system!)
        result.levels = Levels(microphone: frameLevels(microphone), system: frameLevels(system))
        mix(&system, microphone)
        everyone = system
        log("audio: \(tracks.count) audio track(s), microphone \(roles.microphone), system \(roles.system) → \(result.everyone.path)")
    } else {
        for item in tracks { mix(&everyone, try await decode(item.track, of: asset)) }
        log("audio: \(tracks.count) audio track(s), all mixed → \(result.everyone.path)")
    }
    try writeWAV(everyone, to: result.everyone)
    return result
}

/// WAVs left by a job that crashed: hundreds of MB for a long recording.
func removeStaleTemporaryFolders() {
    let files = FileManager.default
    let folder = files.temporaryDirectory
    for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("MeetRecASR-") {
        let url = folder.appendingPathComponent(name)
        if let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 6 * 3600 {
            try? files.removeItem(at: url)
            log("Removed a stale temporary folder \(name)")
        }
    }
}

/// The samples of a 16 kHz mono WAV written by `extractAudio`.
func readWAV(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw AudioError(message: "cannot read \(url.lastPathComponent)")
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// Recognises the user's pieces of the microphone track, put one after another with short pauses:
/// one pass (the engine hears the context, the language is found from the user's own speech), times
/// mapped back to the recording.
func recogniseChunks(_ wav: URL, _ chunks: [(Double, Double)]) async throws -> (segments: [Segment], language: String?, seconds: Double) {
    guard !chunks.isEmpty else { return ([], nil, 0) }
    let started = Date()
    let audio = try readWAV(wav)
    let places = joinedChunks(chunks)
    var joined: [Float] = []
    let pause = [Float](repeating: 0, count: Int(joinPause * Double(sampleRate)))
    for (start, end) in chunks {
        let from = min(Int(start * Double(sampleRate)), audio.count), to = min(Int(end * Double(sampleRate)), audio.count)
        joined += audio[from..<max(from, to)]
        joined += pause
    }
    let joinedURL = wav.deletingLastPathComponent().appendingPathComponent("microphone-joined.wav")
    try writeWAV(joined, to: joinedURL)
    let found = try await recognise(joinedURL)
    let segments = withoutLoops(splitByPiece(found, places))
    for segment in segments { log("microphone [\(formatTime(segment.start))]: \(segment.text)") }
    return (segments, guessLanguage(found), Date().timeIntervalSince(started))
}

func loadSpeakers(_ url: URL?) -> [String: [[Double]]] {
    guard let url, let data = try? Data(contentsOf: url),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[Double]]] else { return [:] }
    return json
}

func transcribeCommand(_ options: TranscribeOptions) async throws {
    let recording = options.recording
    guard FileManager.default.fileExists(atPath: recording.path) else {
        throw Failure(code: "not_found", message: tr("Запись не найдена: \(recording.path)", "Recording not found: \(recording.path)"))
    }
    let started = Date()
    let me = options.me
    removeStaleTemporaryFolders()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRecASR-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    temporaryFolder = temporary
    defer {
        try? FileManager.default.removeItem(at: temporary)
        temporaryFolder = nil
    }

    emit("phase", ["name": tr("Извлечение звука", "Extracting audio")])
    let audio = try await extractAudio(recording, into: temporary)
    let levels = !options.noDiarization && !me.isEmpty ? audio.levels : nil
    // The user's track apart (headphones), else the mixed way (speakers, one track, no name).
    var chunks: [(Double, Double)]?
    if let levels, !options.mixed {
        let echo = echoRatio(levels.microphone, levels.system)
        if echo <= echoLimit {
            chunks = speechChunks(levels.microphone)
            let minutes = chunks!.reduce(0) { $0 + $1.1 - $1.0 } / 60
            log("Microphone apart: echo \(Int((echo * 100).rounded()))%, \(chunks!.count) piece(s), \(String(format: "%.1f", minutes)) min of the user's speech")
        } else {
            log("Microphone hears the other side (echo \(Int((echo * 100).rounded()))% > \(Int(echoLimit * 100))%, speakers?): mixed transcription")
        }
    }

    var segments: [Segment]
    var asrSeconds: Double
    var mine: (segments: [Segment], language: String?, seconds: Double)?
    var diarization: Diarization?
    let asrStarted = Date()
    if options.noDiarization {
        emit("phase", ["name": tr("Распознавание речи", "Recognizing speech")])
        segments = try await recognise(audio.everyone, report: Throttle("asr").report)
        asrSeconds = Date().timeIntervalSince(asrStarted)
    } else {
        emit("phase", ["name": tr("Распознавание речи и разбивка по ролям", "Recognizing speech and speakers")])
        // One after the other, each in its own process: one model at a time keeps the Mac cooler
        // (and quieter) at the cost of a longer run; nothing waits for the transcript.
        let others = chunks != nil ? audio.system! : audio.everyone
        segments = try await recognise(others, report: Throttle("asr").report)
        asrSeconds = Date().timeIntervalSince(asrStarted)
        if let chunks { mine = try await recogniseChunks(audio.microphone!, chunks) }
        diarization = try await diarize(others, report: Throttle("diarization").report)
    }
    let language = guessLanguage(segments + (mine?.segments ?? []))
    segments = withoutLoops(segments)

    emit("phase", ["name": tr("Сохранение", "Saving")])
    var speakersSummary: [[String: Any]] = []
    var lines: [(start: Double, text: String)]
    var dropped = 0
    var usedEngine = engine
    if let diarization {
        var (names, scores) = matchSpeakers(diarization.embeddings, loadSpeakers(options.speakers), threshold: options.threshold)
        if mine != nil {
            names = withoutMe(names, me: me)
        } else if let levels {
            let shares = microphoneShares(diarization.turns, levels)
            let named = nameMicrophoneSpeakers(names, shares, me: me)
            names = named.names
            for (label, value) in shares.sorted(by: { $0.key < $1.key }) {
                scores[label]?.microphone = rounded(value.share, 2)
                log("\(label): \(Int((value.share * 100).rounded()))% of \(Int(value.seconds.rounded()))s through the microphone\(named.mine.contains(label) ? " → \(me)" : "")")
            }
        }
        var speaking: [String: Double] = [:]
        for turn in diarization.turns { speaking[turn.speaker, default: 0] += turn.end - turn.start }
        let merged = options.oneOther
            ? mergeOtherSide(names, speaking, me: me)
            : mergeStrayVoices(names, speaking, me: me, scores: scores.mapValues(\.score))
        if merged != names {
            let changed = names.keys.sorted().filter { merged[$0] != names[$0] }
            if options.oneOther {
                log("One other person: \(changed.joined(separator: ", ")) → \(merged)")
            } else {
                log("Stray voice: \(changed.map { "\($0) (\(Int((speaking[$0] ?? 0).rounded()))s)" }.joined(separator: ", ")) → \(merged)")
            }
        }
        names = merged
        if let mine {
            (lines, dropped) = buildSplitLines(segments, mine.segments, diarization.turns, names, me: me)
            let mineSeconds = chunks!.reduce(0) { $0 + $1.1 - $1.0 }
            speakersSummary.append(["label": "microphone", "name": me, "minutes": rounded(mineSeconds / 60, 1), "best": me, "score": 1.0])
            log("microphone: \(me) (\(Int(mineSeconds.rounded()))s in \(chunks!.count) pieces, \(mine.segments.count) phrase(s), language \(mine.language ?? "-"), \(Int(mine.seconds.rounded()))s)")
        } else {
            (lines, dropped) = buildLines(segments, diarization.turns, names, me: me, levels: levels)
        }
        for label in stableSorted(speaking.keys.sorted(), by: { speaking[$0]! > speaking[$1]! }) {
            let match = scores[label] ?? Score(name: nil, score: -1)
            speakersSummary.append(["label": label, "name": names[label] ?? label, "minutes": rounded(speaking[label]! / 60, 1),
                                    "best": match.name ?? NSNull(), "score": match.score])
            log("\(label): \(names[label] ?? label) (\(String(format: "%.1f", speaking[label]! / 60)) min; best \(match.name ?? "None") \(match.score))")
        }
        if let runFile = options.runFile {
            try writeRun(runFile, recording: recording, names: names, scores: scores, diarization: diarization, microphoneApart: mine != nil)
        }
    } else {
        lines = segments.map { ($0.start, "[\(formatTime($0.start))] \($0.text)") }
        usedEngine = "Parakeet Ultra"
    }

    let markers = loadMarkers(recording)
    let mutes = loadMutes(recording, speech: mine?.segments.map(\.start) ?? [])
    let text = insertMarkers(lines, markers + mutes)
    if !markers.isEmpty { log("Inserted \(markers.count) marker(s)") }
    if !mutes.isEmpty { log("Inserted \(mutes.count) microphone mute(s)") }
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "dd MMM yyyy 'at' HH:mm:ss"
    let header = [
        "# Transcription: \(recording.lastPathComponent)",
        "- Date: \(date.string(from: Date()))",
        "- Engine: \(usedEngine)",
        "- Language: \(language)",
    ]
    try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (header.joined(separator: "\n") + "\n\n" + text.joined(separator: "\n\n") + "\n")
        .write(to: options.output, atomically: true, encoding: .utf8)
    var timing = "ASR \(Int(asrSeconds.rounded()))s"
    if let mine { timing += " + microphone \(Int(mine.seconds.rounded()))s" }
    if let diarization { timing += ", diarization \(Int(diarization.seconds.rounded()))s" }
    let total = Date().timeIntervalSince(started)
    log("Transcript \(options.output.path): language \(language), \(text.count) lines, dropped \(dropped), \(timing), total \(Int(total.rounded()))s")
    emit("done", ["output": options.output.path, "language": language, "lines": text.count - markers.count - mutes.count,
                  "dropped": dropped, "seconds": Int(total.rounded()), "speakers": speakersSummary])
}

/// The speakers of this run for "Подписать спикеров…" (`run.json` in the recording's folder).
func writeRun(_ url: URL, recording: URL, names: [String: String], scores: [String: Score], diarization: Diarization,
              microphoneApart: Bool) throws {
    var scoreObjects: [String: Any] = [:]
    for (label, score) in scores {
        var object: [String: Any] = ["name": score.name ?? NSNull(), "score": score.score]
        if let microphone = score.microphone { object["microphone"] = microphone }
        scoreObjects[label] = object
    }
    let run: [String: Any] = [
        "recording": recording.lastPathComponent,
        "names": names,
        "scores": scoreObjects,
        "turns": diarization.turns.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker] },
        "embeddings": diarization.embeddings,
        "seconds": diarization.seconds,
        "microphoneApart": microphoneApart,
    ]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: run, options: [.withoutEscapingSlashes]).write(to: url, options: .atomic)
}

// MARK: - enroll-sample

/// Stores the voice in a short solo recording as a reference embedding for `name`.
func enrollCommand(_ arguments: [String]) async throws {
    var wavPath: String?, name: String?, speakers: String?
    var i = 0
    while i < arguments.count {
        switch arguments[i] {
        case "--name" where i + 1 < arguments.count: i += 1; name = arguments[i]
        case "--speakers" where i + 1 < arguments.count: i += 1; speakers = arguments[i]
        default: wavPath = arguments[i]
        }
        i += 1
    }
    guard let wavPath, let name, let speakers else {
        throw Failure(code: "usage", message: "enroll-sample <wav> --name <Name> --speakers <file>")
    }
    let wav = URL(fileURLWithPath: wavPath)
    guard FileManager.default.fileExists(atPath: wav.path) else {
        throw Failure(code: "not_found", message: tr("Файл образца не найден: \(wav.path)", "Sample file not found: \(wav.path)"))
    }
    emit("phase", ["name": tr("Анализ образца голоса", "Analyzing the voice sample")])
    let diarization = try await diarize(wav)
    if diarization.turns.isEmpty {
        throw Failure(code: "no_speech", message: tr("В образце не найдена речь. Говорите громче или ближе к микрофону.",
                                                     "No speech found in the sample. Speak louder or closer to the microphone."))
    }
    var speaking: [String: Double] = [:]
    for turn in diarization.turns { speaking[turn.speaker, default: 0] += turn.end - turn.start }
    let label = speaking.max { $0.value < $1.value }!.key
    let seconds = speaking[label]!
    if seconds < 5 {
        throw Failure(code: "too_short", message: tr("Слишком мало речи в образце (\(Int(seconds.rounded())) с). Нужно хотя бы 10 секунд.",
                                                     "Too little speech in the sample (\(Int(seconds.rounded())) s). At least 10 seconds are needed."))
    }
    guard let embedding = diarization.embeddings[label] else {
        throw Failure(code: "no_speech", message: tr("Не удалось получить образец голоса", "Could not get a voice print"))
    }
    let file = URL(fileURLWithPath: speakers)
    var references = loadSpeakers(file)
    references[name, default: []].append(embedding)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: references, options: [.sortedKeys]).write(to: file, options: .atomic)
    log("Enrolled \(name): \(Int(seconds.rounded()))s of speech, now \(references[name]!.count) sample(s)")
    emit("done", ["name": name, "samples": references[name]!.count, "speech_seconds": Int(seconds.rounded())])
}
