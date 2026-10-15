import AVFoundation
import Foundation
import SwiftUI

/// Runs `transcribe.py` (bundled in Resources) through `uv`, one job at a time.
///
/// Models live in the standard Hugging Face cache (`~/.cache/huggingface/hub`), shared with the
/// transcribe-meeting / transcribe-lesson skills. Speaker voices live in
/// `~/Library/Application Support/MeetRec/speakers.json`.
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    enum ModelsState: Equatable {
        case checking, missing, downloading(String), ready, failed(String)
    }

    enum JobState: Equatable {
        case idle
        case running(file: URL, phase: String, startedAt: Date)
        case failed(String)
    }

    // Settings
    @AppStorage("transcribeAfterRecording") var transcribeAfterRecording = false
    @AppStorage("diarization") var diarization = true
    @AppStorage("transcriptionLanguage") var language = ""
    @AppStorage("myName") var myName = ""

    // State
    @Published private(set) var modelsState: ModelsState = .checking
    @Published private(set) var job: JobState = .idle
    @Published private(set) var queue: [URL] = []
    @Published private(set) var lastTranscript: URL?
    @Published private(set) var lastSummary: String?
    @Published private(set) var speakerSamples: [String: Int] = [:]
    @Published private(set) var enrollMessage: String?
    /// Overall progress of the running job, 0…1; nil until the helper reports any.
    @Published private(set) var progress: Double?
    /// Last error per recording path, for the recordings list.
    @Published private(set) var failures: [String: String] = [:]
    /// Bumped whenever a transcript is written, so views re-check which recordings have one.
    @Published private(set) var transcriptsVersion = 0

    static let asrRepo = "models--mlx-community--whisper-large-v3-turbo"
    static let diarizationRepo = "models--pyannote--speaker-diarization-community-1"

    let stateDir: URL
    var speakersFile: URL { stateDir.appendingPathComponent("speakers.json") }
    var runsDir: URL { stateDir.appendingPathComponent("runs") }

    private var currentProcess: Process?

    private init() {
        stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        seedSpeakersIfNeeded()
        if myName.isEmpty {
            myName = speakerSamples["Dima"] != nil ? "Dima" : (NSFullUserName().split(separator: " ").first.map(String.init) ?? "Я")
        }
        refreshModels()
    }

    // MARK: - Models

    func refreshModels() {
        if case .downloading = modelsState { return }
        let ready = Self.modelCached(Self.asrRepo, marker: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") })
            && Self.modelCached(Self.diarizationRepo, marker: { $0 == "config.yaml" })
        modelsState = ready ? .ready : .missing
        Log.info("Transcription models: \(ready ? "ready" : "missing") (cache \(Self.hubDir.path))", "transcribe")
    }

    func downloadModels() {
        guard modelsState != .ready, job == .idle || isFailed else { return }
        modelsState = .downloading("Подготовка окружения…")
        Log.info("Model download started", "transcribe")
        Task {
            let result = await runScript(["download"]) { [weak self] event in
                if event["event"] as? String == "phase", let name = event["name"] as? String {
                    self?.modelsState = .downloading(name + "…")
                }
            }
            switch result {
            case .success:
                Log.info("Model download finished", "transcribe")
                modelsState = .ready
                refreshModels()
            case .failure(let message):
                Log.error("Model download failed: \(message)", "transcribe")
                modelsState = .failed(message)
            }
        }
    }

    // MARK: - Jobs

    /// Called when a recording finishes.
    func recordingFinished(_ file: URL) {
        guard transcribeAfterRecording else { return }
        guard modelsState == .ready else {
            Log.warning("Auto-transcription skipped for \(file.lastPathComponent): models not downloaded", "transcribe")
            job = .failed("Модели не скачаны — транскрибация пропущена")
            return
        }
        enqueue(file)
    }

    func enqueue(_ file: URL) {
        guard !queue.contains(file), runningFile != file else { return }
        failures[file.path] = nil
        queue.append(file)
        Log.info("Queued for transcription: \(file.path) (queue \(queue.count))", "transcribe")
        startNextIfIdle()
    }

    func cancelCurrent() {
        guard let process = currentProcess else { return }
        Log.warning("Transcription cancelled by user", "transcribe")
        process.terminate()
    }

    private var isFailed: Bool { if case .failed = job { return true } else { return false } }

    var runningFile: URL? {
        if case .running(let file, _, _) = job { return file }
        return nil
    }

    /// Newest transcript of a recording: `<name>.md` next to it, or `<name> (2).md`… after
    /// "Транскрибировать заново" (older versions are kept, never overwritten).
    static func existingTranscript(for recording: URL) -> URL? {
        let base = recording.deletingPathExtension()
        var found: URL?
        var candidate = base.appendingPathExtension("md")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            found = candidate
            let next = URL(fileURLWithPath: base.path + " (\(index))")
            // "<name> (2).mov" is a separate recording, so "<name> (2).md" is its transcript.
            if ["mov", "mp4"].contains(where: { FileManager.default.fileExists(atPath: next.appendingPathExtension($0).path) }) { break }
            candidate = next.appendingPathExtension("md")
            index += 1
        }
        return found
    }

    private func startNextIfIdle() {
        if case .running = job { return }
        guard !queue.isEmpty else { return }
        let file = queue.removeFirst()
        let output = Self.transcriptURL(for: file)
        job = .running(file: file, phase: "Запуск…", startedAt: Date())
        progress = nil
        var stageProgress: [String: Double] = [:]
        let useDiarization = diarization
        var arguments = ["transcribe", file.path, "--output", output.path,
                         "--speakers", speakersFile.path, "--runs-dir", runsDir.path]
        if !diarization { arguments.append("--no-diarization") }
        if !language.isEmpty { arguments += ["--language", language] }
        Log.info("Transcription started: \(file.lastPathComponent) diarization=\(diarization) language=\(language.isEmpty ? "auto" : language) → \(output.path)", "transcribe")

        Task {
            var summary: String?
            let result = await runScript(arguments) { [weak self] event in
                guard let self else { return }
                switch event["event"] as? String {
                case "phase":
                    if case .running(let name, _, let started) = self.job, let phase = event["name"] as? String {
                        self.job = .running(file: name, phase: phase, startedAt: started)
                    }
                case "progress":
                    if let stage = event["stage"] as? String, let value = event["value"] as? Double {
                        stageProgress[stage] = value
                        let asr = stageProgress["asr"] ?? 0
                        self.progress = useDiarization ? (asr + (stageProgress["diarization"] ?? 0)) / 2 : asr
                    }
                case "done":
                    summary = Self.describe(done: event)
                default:
                    break
                }
            }
            switch result {
            case .success:
                lastTranscript = output
                lastSummary = summary
                job = .idle
                progress = nil
                transcriptsVersion += 1
                Log.info("Transcription finished: \(output.path) — \(summary ?? "")", "transcribe")
            case .failure(let message):
                job = .failed(message)
                progress = nil
                failures[file.path] = message
                Log.error("Transcription failed for \(file.lastPathComponent): \(message)", "transcribe")
            }
            startNextIfIdle()
        }
    }

    /// `<recording>.md` next to the video; never overwrites an existing transcript.
    static func transcriptURL(for recording: URL) -> URL {
        let base = recording.deletingPathExtension()
        var candidate = base.appendingPathExtension("md")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: base.path + " (\(index))").appendingPathExtension("md")
            index += 1
        }
        return candidate
    }

    private static func describe(done event: [String: Any]) -> String {
        var parts: [String] = []
        if let lines = event["lines"] as? Int { parts.append("\(lines) реплик") }
        if let language = event["language"] as? String { parts.append("язык \(language)") }
        if let seconds = event["seconds"] as? Int { parts.append("за \(seconds) с") }
        if let speakers = event["speakers"] as? [[String: Any]], !speakers.isEmpty {
            let names = speakers.compactMap { $0["name"] as? String }
            parts.append("говорили: " + Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Voice sample

    func enrollSample(_ wav: URL) async -> Bool {
        let name = myName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            enrollMessage = "Укажите своё имя"
            return false
        }
        guard modelsState == .ready else {
            enrollMessage = "Сначала скачайте модели"
            return false
        }
        enrollMessage = "Анализ образца…"
        Log.info("Enrolling voice sample for \(name): \(wav.path)", "transcribe")
        var samples: Int?
        let result = await runScript(["enroll-sample", wav.path, "--name", name, "--speakers", speakersFile.path]) { event in
            if event["event"] as? String == "done" { samples = event["samples"] as? Int }
        }
        loadSpeakers()
        switch result {
        case .success:
            enrollMessage = "Голос сохранён (\(samples ?? speakerSamples[name] ?? 1) образц.)"
            Log.info("Voice sample enrolled for \(name): \(samples ?? 0) sample(s)", "transcribe")
            return true
        case .failure(let message):
            enrollMessage = message
            Log.error("Voice enrollment failed: \(message)", "transcribe")
            return false
        }
    }

    func setEnrollMessage(_ text: String?) { enrollMessage = text }

    // MARK: - Speakers

    func loadSpeakers() {
        guard let data = try? Data(contentsOf: speakersFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]] else {
            speakerSamples = [:]
            return
        }
        speakerSamples = json.mapValues(\.count)
    }

    /// First run: start from the voices already confirmed in the transcribe-meeting skill (a copy;
    /// the original file is never written).
    private func seedSpeakersIfNeeded() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: speakersFile.path) {
            let source = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/inventire-meetings/speakers.json")
            if manager.fileExists(atPath: source.path) {
                do {
                    try manager.copyItem(at: source, to: speakersFile)
                    Log.info("Seeded speaker voices from \(source.path)", "transcribe")
                } catch {
                    Log.warning("Could not seed speakers: \(Log.describe(error))", "transcribe")
                }
            }
        }
        loadSpeakers()
        Log.info("Known voices: \(speakerSamples.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "))", "transcribe")
    }

    // MARK: - Process

    enum ScriptResult { case success, failure(String) }

    private static var hubDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    private static func modelCached(_ repo: String, marker: (String) -> Bool) -> Bool {
        let snapshots = hubDir.appendingPathComponent(repo).appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return revisions.contains { revision in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.appendingPathComponent(revision).path)) ?? []
            return files.contains(where: marker)
        }
    }

    private static func findUV() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the helper and forwards its JSON events to `onEvent` on the main actor. stderr goes to the log.
    private func runScript(_ arguments: [String], onEvent: @escaping ([String: Any]) -> Void) async -> ScriptResult {
        guard let uv = Self.findUV() else {
            return .failure("Не найден uv. Установите: brew install uv")
        }
        guard let script = Bundle.main.url(forResource: "transcribe", withExtension: "py") else {
            return .failure("transcribe.py не найден в приложении")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", "--quiet", script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.currentDirectoryURL = stateDir

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            for line in collector.lines(from: handle.availableData, stream: .stdout) {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Log.debug("helper stdout: \(line)", "transcribe")
                    continue
                }
                Log.debug("helper event: \(line)", "transcribe")
                if event["event"] as? String == "error", let message = event["message"] as? String {
                    collector.setError(message)
                }
                Task { @MainActor in onEvent(event) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            for line in collector.lines(from: handle.availableData, stream: .stderr) where !line.isEmpty {
                Log.debug("helper: \(line)", "transcribe")
                collector.rememberStderr(line)
            }
        }

        Log.info("Running: \(uv) \(process.arguments!.joined(separator: " "))", "transcribe")
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                currentProcess = process
            } catch {
                Log.error("Could not start helper: \(Log.describe(error))", "transcribe")
                continuation.resume(returning: -1)
            }
        }
        currentProcess = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        Log.info("Helper exited with status \(status) (\(process.terminationReason == .uncaughtSignal ? "signal" : "exit"))", "transcribe")

        if status == 0 { return .success }
        if process.terminationReason == .uncaughtSignal { return .failure("Отменено") }
        return .failure(collector.errorMessage ?? collector.lastStderr ?? "Ошибка помощника (код \(status))")
    }
}

/// Splits pipe output into lines and keeps the latest error text. Accessed from pipe callbacks.
private final class OutputCollector: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private var buffers: [Stream: String] = [:]
    private var error: String?
    private var stderrTail: [String] = []

    func lines(from data: Data, stream: Stream) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock(); defer { lock.unlock() }
        var buffer = (buffers[stream] ?? "") + text
        var lines: [String] = []
        while let range = buffer.range(of: "\n") {
            lines.append(String(buffer[..<range.lowerBound]))
            buffer = String(buffer[range.upperBound...])
        }
        buffers[stream] = buffer
        return lines
    }

    func setError(_ message: String) { lock.lock(); error = message; lock.unlock() }

    func rememberStderr(_ line: String) {
        lock.lock()
        stderrTail.append(line)
        if stderrTail.count > 5 { stderrTail.removeFirst() }
        lock.unlock()
    }

    var errorMessage: String? { lock.lock(); defer { lock.unlock() }; return error }
    var lastStderr: String? { lock.lock(); defer { lock.unlock() }; return stderrTail.last }
}
