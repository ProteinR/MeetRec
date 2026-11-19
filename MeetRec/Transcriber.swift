import AVFoundation
import Foundation
import SwiftUI

/// Runs `MeetRecASR` (bundled in Contents/MacOS: audio, speech recognition, speaker diarization and
/// the transcript, nothing to install), one job at a time.
///
/// Models live in FluidAudio's cache (`~/Library/Application Support/FluidAudio/Models`: Parakeet,
/// shared with Genius Typer, and the speaker diarization models), downloaded by `MeetRecASR`.
/// Speaker voices live in `~/Library/Application Support/MeetRec/speakers.json`.
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
    @AppStorage("myName") var myName = ""
    /// JSON of `copyRules`.
    @AppStorage("transcriptCopyRules") private var copyRulesJSON = ""

    /// Shorter meeting recordings are not copied: a Teams test call also takes the microphone.
    static let minimumMeetingDuration: TimeInterval = 120

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

    private static let fluidModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    /// Parakeet Ultra in FluidAudio's cache, shared with Genius Typer's dictation.
    static let parakeetDir = fluidModels.appendingPathComponent("parakeet-ultra", isDirectory: true)
    /// FluidAudio's offline speaker diarization (CoreML).
    static let diarizerDir = fluidModels.appendingPathComponent("speaker-diarization", isDirectory: true)

    let stateDir: URL
    var speakersFile: URL { stateDir.appendingPathComponent("speakers.json") }
    var runsDir: URL { stateDir.appendingPathComponent("runs") }

    private var currentProcess: Process?

    private init() {
        stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        loadKnownSpeakers()
        migrateCopyRules()
        if myName.isEmpty {
            myName = NSFullUserName().split(separator: " ").first.map(String.init) ?? String(localized: "Я")
        }
        refreshModels()
    }

    // MARK: - Models

    func refreshModels() {
        if case .downloading = modelsState { return }
        let files = FileManager.default
        let ready = files.fileExists(atPath: Self.parakeetDir.appendingPathComponent("Encoder.mlmodelc").path)
            && files.fileExists(atPath: Self.diarizerDir.appendingPathComponent("Segmentation.mlmodelc").path)
        modelsState = ready ? .ready : .missing
        Log.info("Transcription models: \(ready ? "ready" : "missing") (cache \(Self.fluidModels.path))", "transcribe")
    }

    func downloadModels() {
        guard modelsState != .ready, job == .idle || isFailed else { return }
        modelsState = .downloading(String(localized: "Подготовка…"))
        Log.info("Model download started", "transcribe")
        Task {
            let result = await runHelper(["download"]) { [weak self] event in
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
        guard transcribeAfterRecording, !Profiling.isActive else { return }
        guard modelsState == .ready else {
            Log.warning("Auto-transcription skipped for \(file.lastPathComponent): models not downloaded", "transcribe")
            job = .failed(String(localized: "Модели не скачаны — транскрибация пропущена"))
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
    nonisolated static func existingTranscript(for recording: URL) -> URL? {
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
        job = .running(file: file, phase: String(localized: "Запуск…"), startedAt: Date())
        progress = nil
        var stageProgress: [String: Double] = [:]
        let useDiarization = diarization
        var arguments = ["transcribe", file.path, "--output", output.path,
                         "--speakers", speakersFile.path, "--run-file", SpeakerNaming.runURL(for: file).path]
        if !diarization { arguments.append("--no-diarization") }
        // Whoever speaks into the microphone track is the user, whatever the voice match says.
        let me = myName.trimmingCharacters(in: .whitespaces)
        if !me.isEmpty { arguments += ["--me", me] }
        if let ruleID = RecordingTag.rule(of: file),
           BrowserRule.saved().first(where: { $0.id.uuidString == ruleID })?.oneOther == true {
            arguments.append("--one-other")
        }
        Log.info("Transcription started: \(file.lastPathComponent) diarization=\(diarization) → \(output.path)", "transcribe")

        Task {
            var summary: String?
            let result = await runHelper(arguments) { [weak self] event in
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
                await copyMeetingTranscript(output, of: file)
            case .failure(let message):
                job = .failed(message)
                progress = nil
                failures[file.path] = message
                Log.error("Transcription failed for \(file.lastPathComponent): \(message)", "transcribe")
            }
            startNextIfIdle()
        }
    }

    // MARK: - Copy rules

    /// Where transcripts of a meeting app's recordings are also copied ("Teams → docs/meetings").
    /// Several rules may name the same app (copied to each folder).
    var copyRules: [CopyRule] {
        get { (try? JSONDecoder().decode([CopyRule].self, from: Data(copyRulesJSON.utf8))) ?? [] }
        set {
            copyRulesJSON = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? "[]"
            Log.info("Transcript copy rules: " + newValue.map { "\($0.app) → \($0.folder.isEmpty ? "(no folder)" : $0.folder)" }
                .joined(separator: "; "), "transcribe")
        }
    }

    /// Folders the transcript of `recording` is copied to, from its tags: the meeting app ("teams")
    /// and, for a recording started by a browser rule, that rule ("rule:<id>").
    func copyFolders(for recording: URL) -> [URL] {
        var keys: Set<String> = []
        if let app = RecordingTag.meetingApp(of: recording) { keys.insert(app) }
        if let rule = RecordingTag.rule(of: recording) { keys.insert(CopyRule.ruleKey(rule)) }
        let folders = copyRules.filter { keys.contains($0.app) && !$0.folder.isEmpty }.map(\.folder)
        return Array(NSOrderedSet(array: folders)).compactMap { $0 as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The single "meeting transcripts folder" of earlier versions becomes the rule "Teams → folder".
    private func migrateCopyRules() {
        guard copyRulesJSON.isEmpty else { return }
        let old = UserDefaults.standard.string(forKey: "meetingTranscriptsFolder") ?? ""
        copyRules = old.isEmpty ? [] : [CopyRule(app: "teams", folder: old)]
        UserDefaults.standard.removeObject(forKey: "meetingTranscriptsFolder")
    }

    /// Meeting recordings (started automatically or from the call question): also copies the
    /// transcript to each folder of the copy rules for that app, as `<video name>.md`. The copy there
    /// may get edited (Meeting Summary), so it is never overwritten; the original next to the video
    /// stays the one MeetRec uses. A failed copy does not fail transcription.
    private func copyMeetingTranscript(_ transcript: URL, of recording: URL) async {
        let folders = copyFolders(for: recording)
        guard !folders.isEmpty else {
            Log.debug("Transcript not copied: no copy rule for \(recording.lastPathComponent) (\(RecordingTag.meetingApp(of: recording) ?? "manual recording"))", "transcribe")
            return
        }
        let duration = (try? await AVURLAsset(url: recording).load(.duration).seconds) ?? 0
        guard duration >= Self.minimumMeetingDuration else {
            Log.info("Transcript not copied: \(recording.lastPathComponent) is only \(Int(duration)) s (test call?)", "transcribe")
            return
        }
        for folder in folders {
            let destination = folder.appendingPathComponent(recording.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("md")
            if FileManager.default.fileExists(atPath: destination.path) {
                Log.info("Transcript not copied: \(destination.path) already exists (kept as is)", "transcribe")
                continue
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: transcript, to: destination)
                Log.info("Transcript copied: \(transcript.path) → \(destination.path)", "transcribe")
            } catch {
                Log.warning("Transcript copy to \(destination.path) failed: \(Log.describe(error))", "transcribe")
                Notifier.shared.send(id: "meetrec-copy-failed", title: String(localized: "Транскрипт встречи не скопирован"),
                                     body: String(localized: "Не удалось скопировать в «\(folder.lastPathComponent)»: \(error.localizedDescription). Он лежит рядом с видео."))
            }
        }
    }

    /// Folder picker for a copy rule; nil if cancelled.
    func chooseFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// `<recording>.md` next to the video; never overwrites an existing transcript, nor takes the name
    /// of a separate recording's transcript ("name (2).md" of "name (2).mov" in the flat layout).
    static func transcriptURL(for recording: URL) -> URL {
        let base = recording.deletingPathExtension()
        var candidate = base.appendingPathExtension("md")
        var index = 2
        let manager = FileManager.default
        while manager.fileExists(atPath: candidate.path)
                || (index > 2 && ["mov", "mp4"].contains { manager.fileExists(atPath: candidate.deletingPathExtension().appendingPathExtension($0).path) }) {
            candidate = URL(fileURLWithPath: base.path + " (\(index))").appendingPathExtension("md")
            index += 1
        }
        return candidate
    }

    private static func describe(done event: [String: Any]) -> String {
        var parts: [String] = []
        if let lines = event["lines"] as? Int { parts.append(String(localized: "\(lines) реплик")) }
        if let language = event["language"] as? String { parts.append(String(localized: "язык \(language)")) }
        if let seconds = event["seconds"] as? Int { parts.append(String(localized: "за \(seconds) с")) }
        if let speakers = event["speakers"] as? [[String: Any]], !speakers.isEmpty {
            let names = speakers.compactMap { $0["name"] as? String }
            let list = Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", ")
            parts.append(String(localized: "говорили: \(list)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Voice sample

    func enrollSample(_ wav: URL) async -> Bool {
        let name = myName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            enrollMessage = String(localized: "Укажите своё имя")
            return false
        }
        guard modelsState == .ready else {
            enrollMessage = String(localized: "Сначала скачайте модели")
            return false
        }
        enrollMessage = String(localized: "Анализ образца…")
        Log.info("Enrolling voice sample for \(name): \(wav.path)", "transcribe")
        var samples: Int?
        let result = await runHelper(["enroll-sample", wav.path, "--name", name, "--speakers", speakersFile.path]) { event in
            if event["event"] as? String == "done" { samples = event["samples"] as? Int }
        }
        loadSpeakers()
        switch result {
        case .success:
            enrollMessage = String(localized: "Голос сохранён (\(samples ?? speakerSamples[name] ?? 1) образц.)")
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

    private func loadKnownSpeakers() {
        loadSpeakers()
        Log.info("Known voices: \(speakerSamples.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "))", "transcribe")
    }

    // MARK: - Process

    enum HelperResult { case success, failure(String) }

    /// MeetRecASR next to MeetRec's executable; `MEETREC_ASR` points at another build.
    private static var helperPath: String {
        ProcessInfo.processInfo.environment["MEETREC_ASR"]
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MeetRecASR").path
    }

    /// Runs the helper and forwards its JSON events to `onEvent` on the main actor. stderr goes to the log.
    private func runHelper(_ arguments: [String], onEvent: @escaping ([String: Any]) -> Void) async -> HelperResult {
        let helper = Self.helperPath
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            return .failure(String(localized: "MeetRecASR не найден в приложении"))
        }

        let process = Process()
        // Darwin background priority (inherited by the helper's child processes): efficiency cores,
        // low GPU and disk priority, so the Mac heats up less and other apps stay smooth. Slower, and
        // nothing waits for a transcript. `taskpolicy` execs the helper, so the process (and
        // cancelling: the helper ends its child with it) is the same.
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = ["-b", helper] + arguments
        var environment = ProcessInfo.processInfo.environment
        // The helper's messages and the marker lines in the transcript follow the app's language.
        environment["MEETREC_LANGUAGE"] = Bundle.main.preferredLocalizations.first ?? "ru"
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

        Log.info("Running: taskpolicy \(process.arguments!.joined(separator: " "))", "transcribe")
        var load: TranscriptionLoadMonitor?
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                currentProcess = process
                load = TranscriptionLoadMonitor(pid: process.processIdentifier)
                load?.start()
            } catch {
                Log.error("Could not start helper: \(Log.describe(error))", "transcribe")
                continuation.resume(returning: -1)
            }
        }
        load?.stop()
        currentProcess = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        Log.info("Helper exited with status \(status) (\(process.terminationReason == .uncaughtSignal ? "signal" : "exit"))", "transcribe")

        if status == 0 { return .success }
        if process.terminationReason == .uncaughtSignal { return .failure(String(localized: "Отменено")) }
        return .failure(collector.errorMessage ?? collector.lastStderr ?? String(localized: "Ошибка помощника (код \(status))"))
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

/// "Copy transcripts of <app> recordings to <folder>".
struct CopyRule: Codable, Identifiable, Equatable {
    var id = UUID()
    /// `MeetingApp.id` matched against the recording's meeting tag, or `rule:<BrowserRule id>`.
    var app: String
    var folder: String

    static func ruleKey(_ ruleID: String) -> String { "rule:\(ruleID)" }
}
