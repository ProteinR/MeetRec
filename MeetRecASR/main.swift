// MeetRecASR: speech recognition with Parakeet and speaker diarization (FluidAudio, CoreML on the
// Neural Engine) for the transcription helper (`Resources/transcribe.py`), which runs it as a child
// process. Parakeet is the same model as Genius Typer's dictation, in FluidAudio's shared cache
// (`~/Library/Application Support/FluidAudio/Models`), so a model downloaded by either app serves both.
//
// Modes (one JSON object per line on stdout):
//   download [ultra|v3]               → {"progress": 0.42} … {"done": true} | {"error": "…"}
//   transcribe <wav> [ultra|v3]       → {"progress": 0.42} … {"words": [[text, start, end, confidence], …],
//                                       "seconds": 12.3} | {"error": "…"}
//   download-diarizer                 → {"done": true} | {"error": "…"}
//   diarize <wav>                     → {"progress": 0.42} … {"turns": [[start, end, speaker], …],
//                                       "embeddings": {speaker: [Float]}, "seconds": 12.3} | {"error": "…"}
// Diarization: FluidAudio's offline pipeline (pyannote community-1 segmentation, WeSpeaker
// embeddings, VBx clustering, as CoreML models), turns without overlaps like pyannote's
// `exclusive_speaker_diarization`.
// Words keep Parakeet's punctuation and capitals ("Okay,"); times are seconds of the file.
import FluidAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

let arguments = Array(CommandLine.arguments.dropFirst())

/// "ultra" (Moondream's post-trained v3, the default) or "v3" (NVIDIA's).
func version(_ name: String?) -> AsrModelVersion {
    name == "v3" ? .v3 : .ultra
}

/// pyannote community-1 settings, with turns that never overlap (one speaker at a time).
let diarizerConfig = OfflineDiarizerConfig(exclusiveSegments: true)

switch arguments.first {
case "download":
    do {
        try await AsrModels.download(version: version(arguments.dropFirst().first)) {
            emit(["progress": $0.fractionCompleted])
        }
        emit(["done": true])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }

case "transcribe" where arguments.count >= 2:
    let model = version(arguments.dropFirst(2).first)
    let manager = AsrManager(config: .default)
    do {
        let start = Date()
        let models = try await AsrModels.downloadAndLoad(version: model)
        try await manager.loadModels(models)
        let progress = Task {
            for try await value in await manager.transcriptionProgressStream {
                emit(["progress": value])
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
        emit(["words": words.filter { !($0[0] as! String).isEmpty }, "seconds": Date().timeIntervalSince(start)])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }

case "download-diarizer":
    do {
        try await OfflineDiarizerManager(config: diarizerConfig).prepareModels()
        emit(["done": true])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }

case "diarize" where arguments.count >= 2:
    do {
        let start = Date()
        let manager = OfflineDiarizerManager(config: diarizerConfig)
        try await manager.prepareModels()
        let result = try await manager.process(URL(fileURLWithPath: arguments[1])) { done, total in
            if total > 0 { emit(["progress": Double(done) / Double(total)]) }
        }
        let turns: [[Any]] = result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { [Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId] }
        let speakers = Set(result.segments.map(\.speakerId))
        var embeddings: [String: [Float]] = [:]
        for speaker in speakers {
            if let embedding = result.speakerDatabase?[speaker] { embeddings[speaker] = embedding }
        }
        emit(["turns": turns, "embeddings": embeddings, "seconds": Date().timeIntervalSince(start)])
    } catch {
        emit(["error": error.localizedDescription])
        exit(1)
    }

default:
    FileHandle.standardError.write(Data("usage: MeetRecASR download [ultra|v3] | transcribe <wav> [ultra|v3] | download-diarizer | diarize <wav>\n".utf8))
    exit(2)
}
