// MeetRecASR: MeetRec's transcription, run by the app as a child process at background priority.
// Speech recognition with Parakeet and speaker diarization (FluidAudio, CoreML on the Neural
// Engine); the audio is read with AVFoundation. Parakeet is the same model as Genius Typer's
// dictation, in FluidAudio's shared cache (`~/Library/Application Support/FluidAudio/Models`), so a
// model downloaded by either app serves both. Nothing else to install: no Python, no ffmpeg.
//
// Commands for MeetRec (JSON lines {"event": "phase"|"progress"|"done"|"error", …} on stdout):
//   download                         fetch both models
//   transcribe <recording> --output <md> [--no-diarization] [--speakers file] [--run-file file]
//              [--me Name] [--one-other] [--mixed] [--threshold 0.7]
//   enroll-sample <wav> --name <Name> --speakers <file>
//
// Steps run in a child process of this tool (one JSON object per line):
//   asr-download                     → {"progress": 0.42} … {"done": true} | {"error": "…"}
//   asr <wav>                        → {"progress": 0.42} … {"words": [[text, start, end, confidence], …],
//                                      "seconds": 12.3} | {"error": "…"}
//   diarizer-download                → {"done": true} | {"error": "…"}
//   diarize <wav>                    → {"progress": 0.42} … {"turns": [[start, end, speaker], …],
//                                      "embeddings": {speaker: [Float]}, "seconds": 12.3} | {"error": "…"}
// Diarization: FluidAudio's offline pipeline (pyannote community-1 segmentation, WeSpeaker
// embeddings, VBx clustering, as CoreML models), turns without overlaps.
// Words keep Parakeet's punctuation and capitals ("Okay,"); times are seconds of the file.
import FluidAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

/// pyannote community-1 settings, with turns that never overlap (one speaker at a time).
let diarizerConfig = OfflineDiarizerConfig(exclusiveSegments: true)

/// A step for a child process: its result, or {"error": …} and exit 1.
func step(_ body: () async throws -> [String: Any]) async {
    do {
        emitJSON(try await body())
    } catch {
        emitJSON(["error": error.localizedDescription])
        exit(1)
    }
}

/// A command for MeetRec: {"event": "error", …} and exit 1 when it fails.
func command(_ body: () async throws -> Void) async {
    forwardTerminationToChildren()
    do {
        try await body()
    } catch let failure as Failure {
        emit("error", ["code": failure.code, "message": failure.message])
        exit(1)
    } catch {
        log("Failed: \(error)")
        emit("error", ["code": "exception", "message": "\(type(of: error)): \(error.localizedDescription)"])
        exit(1)
    }
}

switch arguments.first {
case "download":
    await command { try await downloadCommand() }

case "transcribe":
    await command { try await transcribeCommand(TranscribeOptions(Array(arguments.dropFirst()))) }

case "enroll-sample":
    await command { try await enrollCommand(Array(arguments.dropFirst())) }

case "asr-download":
    await step {
        try await AsrModels.download(version: .ultra) { emitJSON(["progress": $0.fractionCompleted]) }
        return ["done": true]
    }

case "asr" where arguments.count >= 2:
    await step {
        let start = Date()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .ultra))
        let progress = Task {
            for try await value in await manager.transcriptionProgressStream {
                emitJSON(["progress": value])
            }
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(URL(fileURLWithPath: arguments[1]), decoderState: &state)
        progress.cancel()
        // Words from Parakeet's sub-word tokens, each with the lowest confidence of its tokens.
        var words: [[Any]] = []
        for timing in result.tokenTimings ?? [] {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            if isWordBoundary(token) || words.isEmpty {
                words.append([stripWordBoundaryPrefix(token), timing.startTime, timing.endTime, timing.confidence])
            } else {
                words[words.count - 1][0] = (words[words.count - 1][0] as! String) + token
                words[words.count - 1][2] = timing.endTime
                words[words.count - 1][3] = min(words[words.count - 1][3] as! Float, timing.confidence)
            }
        }
        return ["words": words.filter { !($0[0] as! String).isEmpty }, "seconds": Date().timeIntervalSince(start)]
    }

case "diarizer-download":
    await step {
        try await OfflineDiarizerManager(config: diarizerConfig).prepareModels()
        return ["done": true]
    }

case "diarize" where arguments.count >= 2:
    await step {
        let start = Date()
        let manager = OfflineDiarizerManager(config: diarizerConfig)
        try await manager.prepareModels()
        let result = try await manager.process(URL(fileURLWithPath: arguments[1])) { done, total in
            if total > 0 { emitJSON(["progress": Double(done) / Double(total)]) }
        }
        let turns: [[Any]] = result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { [Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId] }
        var embeddings: [String: [Float]] = [:]
        for speaker in Set(result.segments.map(\.speakerId)) {
            if let embedding = result.speakerDatabase?[speaker] { embeddings[speaker] = embedding }
        }
        return ["turns": turns, "embeddings": embeddings, "seconds": Date().timeIntervalSince(start)]
    }

default:
    log("usage: MeetRecASR download | transcribe <recording> --output <md> [options] | enroll-sample <wav> --name <Name> --speakers <file>")
    exit(2)
}
