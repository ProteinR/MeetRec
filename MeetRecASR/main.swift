// MeetRecASR: speech recognition with Parakeet (FluidAudio, CoreML on the Neural Engine) for the
// transcription helper (`Resources/transcribe.py`), which runs it as a child process. The same
// models as Genius Typer's dictation, in FluidAudio's shared cache
// (`~/Library/Application Support/FluidAudio/Models`), so a model downloaded by either app serves both.
//
// Modes (one JSON object per line on stdout):
//   download [ultra|v3]               → {"progress": 0.42} … {"done": true} | {"error": "…"}
//   transcribe <wav> [ultra|v3]       → {"progress": 0.42} … {"words": [[text, start, end, confidence], …],
//                                       "seconds": 12.3} | {"error": "…"}
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

default:
    FileHandle.standardError.write(Data("usage: MeetRecASR download [ultra|v3] | transcribe <wav> [ultra|v3]\n".utf8))
    exit(2)
}
