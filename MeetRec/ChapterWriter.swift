import AVFoundation
import CoreMedia

/// Finishes a recording file after it was written: the moments marked during the recording become
/// chapters (QuickTime: View → Next Chapter; IINA, VLC), and microphone + system audio get a mixed
/// track that comes first, so every player plays both sides (most play only the first audio track).
///
/// Audio layout of a finished file: 1 — mix (default, the only enabled one), 2 — microphone,
/// 3 — system audio; all three in one alternate group. The recorder itself writes [system, microphone].
///
/// The fragmented recording cannot get tracks added in place, so the file is copied (video and the
/// separate audio tracks without re-encoding, AVAssetReader → AVAssetWriter; the mix is encoded) and
/// the copy replaces the original only after it was read back and checked (tracks, duration,
/// chapters); on any failure the original stays untouched.
enum ChapterWriter {
    enum Failure: LocalizedError {
        case noVideo, notEnoughSpace, writer(String), verification(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "В записи нет видеодорожки"
            case .notEnoughSpace: return "Недостаточно места на диске для глав"
            case .writer(let message): return "Не удалось записать главы: \(message)"
            case .verification(let message): return "Файл с главами не прошёл проверку: \(message)"
            }
        }
    }

    /// "Начало", "⭐ 1 · 12:34", "⏸ Пауза · 20:05", "⭐ 2 · 25:10"…: chapter starts and titles for the
    /// markers; only the user's own markers are numbered.
    static func chapters(for markers: [Marker], duration: Double) -> [(start: Double, title: String)] {
        var seen = Set<Double>()
        let inside = markers
            .filter { $0.time > 0.5 && $0.time < duration - 0.5 }
            .sorted { $0.time < $1.time }
            .filter { seen.insert($0.time).inserted }
        var number = 0
        return [(0, "Начало")] + inside.map { marker in
            if marker.isPause { return (marker.time, "⏸ \(RecorderModel.pauseNote) · \(marker.timeText)") }
            number += 1
            return (marker.time, "⭐ \(number) · \(marker.timeText)")
        }
    }

    /// Adds the markers as chapters to `file` (an older recording; a mixed track it has is kept).
    /// Throws (and leaves the file as it was) on failure.
    static func addChapters(_ markers: [Marker], to file: URL) async throws {
        try await process(file, markers: markers, mix: false)
    }

    /// After a recording: chapters for its markers and the mixed track, in one copy. Does nothing when
    /// there is neither (no markers, not both audio tracks).
    static func finish(_ file: URL, markers: [Marker]) async throws {
        try await process(file, markers: markers, mix: true)
    }

    // MARK: - Private

    private struct Mix {
        let system: AVAssetTrack
        let microphone: AVAssetTrack
        let gainDB: Float
    }

    private static func process(_ file: URL, markers: [Marker], mix wantsMix: Bool) async throws {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw Failure.noVideo }
        let audio = tracks.filter { $0.mediaType == .audio }
        var allEnabled = true
        for track in audio where !(try await track.load(.isEnabled)) { allEnabled = false }
        // Exactly the recorder's two tracks, nothing mixed yet: [system, microphone].
        var mix: Mix?
        if wantsMix, audio.count == 2, allEnabled {
            let gain = try await AudioMixer.microphoneGain(asset: asset, microphone: audio[1], system: audio[0])
            mix = Mix(system: audio[0], microphone: audio[1], gainDB: gain)
        }
        guard !markers.isEmpty || mix != nil else { return }

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if let free = DiskSpace.available(at: file), free < size + DiskSpace.stopBelow { throw Failure.notEnoughSpace }

        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent).finishing.mov")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let started = Date()
        let chapterList = markers.isEmpty ? [] : chapters(for: markers, duration: duration.seconds)
        try await remux(asset, tracks: tracks, duration: duration, chapters: chapterList, mix: mix, to: temporary)
        try await verify(temporary, mediaTracks: tracks.count + (mix == nil ? 0 : 1), duration: duration,
                         chapters: !chapterList.isEmpty, mixed: mix != nil)

        // Tags live in extended attributes; carry them over explicitly.
        let app = RecordingTag.meetingApp(of: file)
        let rule = RecordingTag.rule(of: file)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        if let app { RecordingTag.setMeetingApp(app, on: file) }
        if let rule { RecordingTag.setRule(rule, on: file) }
        let took = String(format: "%.1f", Date().timeIntervalSince(started))
        if !markers.isEmpty {
            Log.info("Chapters added to \(file.lastPathComponent): \(markers.count) marker(s)", "recorder")
        }
        if let mix {
            Log.info("Mixed audio track added to \(file.lastPathComponent): microphone \(String(format: "%+.1f", mix.gainDB)) dB", "recorder")
        }
        Log.info("File finished in \(took) s: \(file.lastPathComponent)", "recorder")
    }

    private static func remux(_ asset: AVURLAsset, tracks: [AVAssetTrack], duration: CMTime,
                              chapters: [(start: Double, title: String)], mix: Mix?, to output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var feeds: [(SampleQueue, AVAssetWriterInput)] = []
        var videoInput: AVAssetWriterInput?
        var audioInputs: [AVAssetWriterInput] = []
        var defaultAudio: AVAssetWriterInput?

        func passthrough(_ track: AVAssetTrack, name: String? = nil) async throws -> AVAssetWriterInput {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { throw Failure.writer("cannot read \(track.mediaType.rawValue)") }
            reader.add(readerOutput)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if let name {
                input.metadata = [trackName(name)]
            } else {
                input.metadata = try await track.load(.metadata)
            }
            guard writer.canAdd(input) else { throw Failure.writer("cannot write \(track.mediaType.rawValue)") }
            writer.add(input)
            feeds.append((SampleQueue(readerOutput), input))
            return input
        }

        for track in tracks where track.mediaType == .video {
            let input = try await passthrough(track)
            if videoInput == nil { videoInput = input }
        }

        // The mix is read by its own reader: it decodes and mixes both tracks, which the main reader
        // copies as they are.
        var mixReader: AVAssetReader?
        if let mix {
            let mixing = try AVAssetReader(asset: asset)
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: [mix.system, mix.microphone],
                                                        audioSettings: AudioMixer.pcmSettings(sampleRate: AudioMixer.sampleRate, channels: 2))
            // Mixer volumes stay at or below 1: the system side is lowered by the gain and the sum is
            // raised by it again (AudioMixer.apply), which leaves the microphone louder by the gain.
            let gain = pow(10, mix.gainDB / 20)
            let audioMix = AVMutableAudioMix()
            let systemParameters = AVMutableAudioMixInputParameters(track: mix.system)
            systemParameters.setVolume(1 / gain, at: .zero)
            let microphoneParameters = AVMutableAudioMixInputParameters(track: mix.microphone)
            microphoneParameters.setVolume(1, at: .zero)
            audioMix.inputParameters = [systemParameters, microphoneParameters]
            mixOutput.audioMix = audioMix
            guard mixing.canAdd(mixOutput) else { throw Failure.writer("cannot mix audio") }
            mixing.add(mixOutput)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioMixer.aacSettings)
            input.expectsMediaDataInRealTime = false
            input.metadata = [trackName("Микрофон + звук системы")]
            guard writer.canAdd(input) else { throw Failure.writer("cannot write the mix") }
            writer.add(input)
            feeds.append((SampleQueue(mixOutput) { AudioMixer.apply(gain: gain, to: $0) }, input))
            audioInputs.append(input)
            defaultAudio = input
            mixReader = mixing
            audioInputs.append(try await passthrough(mix.microphone, name: "Микрофон"))
            audioInputs.append(try await passthrough(mix.system, name: "Звук системы"))
        } else {
            // A file mixed earlier keeps its layout: its mix (the only enabled audio track) stays the
            // default. The recorder's own two tracks are both enabled and stay ungrouped.
            let audio = tracks.filter { $0.mediaType == .audio }
            let grouped = !(try await audio.asyncAllEnabled())
            for track in audio {
                let input = try await passthrough(track)
                audioInputs.append(input)
                if grouped, defaultAudio == nil, try await track.load(.isEnabled) { defaultAudio = input }
            }
        }
        // One group, one default: players play the mix; QuickTime would otherwise play all three.
        if let defaultAudio, audioInputs.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: defaultAudio)
            guard writer.canAdd(group) else { throw Failure.writer("cannot group audio tracks") }
            writer.add(group)
        }

        if !chapters.isEmpty {
            let format = try textFormat()
            let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            chapterInput.marksOutputTrackAsEnabled = false
            // Chapter titles are read by language; without one some players ignore them.
            chapterInput.languageCode = "rus"
            chapterInput.extendedLanguageTag = "ru"
            guard let videoInput, writer.canAdd(chapterInput) else { throw Failure.writer("cannot add chapters") }
            writer.add(chapterInput)
            videoInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            var samples: [CMSampleBuffer] = []
            for (index, chapter) in chapters.enumerated() {
                let end = index + 1 < chapters.count ? chapters[index + 1].start : duration.seconds
                samples.append(try textSample(chapter.title, start: CMTime(seconds: chapter.start, preferredTimescale: 600),
                                              duration: CMTime(seconds: max(end - chapter.start, 0.1), preferredTimescale: 600),
                                              format: format))
            }
            feeds.append((SampleQueue(samples), chapterInput))
        }

        guard reader.startReading() else { throw Failure.writer(Log.describe(reader.error)) }
        if let mixReader, !mixReader.startReading() { throw Failure.writer(Log.describe(mixReader.error)) }
        guard writer.startWriting() else { throw Failure.writer(Log.describe(writer.error)) }
        writer.startSession(atSourceTime: .zero)
        // All inputs are fed at once: the writer interleaves them and stalls an input that runs ahead.
        await withTaskGroup(of: Void.self) { group in
            for (source, input) in feeds {
                group.addTask { await feed(input, from: source) }
            }
        }
        await writer.finishWriting()
        guard reader.status == .completed, mixReader.map({ $0.status == .completed }) ?? true, writer.status == .completed else {
            throw Failure.writer("reader \(reader.status.rawValue) \(Log.describe(reader.error)), mix \(mixReader.map { "\($0.status.rawValue) \(Log.describe($0.error))" } ?? "-"), writer \(writer.status.rawValue) \(Log.describe(writer.error))")
        }
    }

    private static func trackName(_ name: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeUserDataTrackName
        item.value = name as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// Hands samples to an input whenever it is ready; returns once all were appended.
    private static func feed(_ input: AVAssetWriterInput, from source: SampleQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.dmemruk.MeetRec.chapters")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = source.next(), input.append(sample) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    private static func verify(_ file: URL, mediaTracks: Int, duration: CMTime, chapters: Bool, mixed: Bool) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.load(.tracks)
        let media = tracks.filter { $0.mediaType == .video || $0.mediaType == .audio }.count
        guard media == mediaTracks else { throw Failure.verification("\(media) of \(mediaTracks) tracks") }
        let newDuration = try await asset.load(.duration)
        guard abs(newDuration.seconds - duration.seconds) < 1 else {
            throw Failure.verification(String(format: "duration %.1f s instead of %.1f s", newDuration.seconds, duration.seconds))
        }
        if chapters {
            let locales = try await asset.load(.availableChapterLocales)
            guard !locales.isEmpty else { throw Failure.verification("no chapters") }
        }
        if mixed {
            let audio = tracks.filter { $0.mediaType == .audio }
            guard let first = audio.first, try await first.load(.isEnabled) else { throw Failure.verification("mix is not the default") }
            let mixDuration = try await first.load(.timeRange).duration.seconds
            guard mixDuration > duration.seconds - 2 else {
                throw Failure.verification(String(format: "mix %.1f s of %.1f s", mixDuration, duration.seconds))
            }
        }
    }

    /// 3GPP timed text (the usual chapter format in QuickTime movies).
    private static func textFormat() throws -> CMFormatDescription {
        let color: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                      kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor: color,
                kCMTextFormatDescriptionStyle_FontSize: 12] as [CFString: Any],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Failure.writer("text format \(status)") }
        return format
    }

    /// One chapter title: a big-endian UInt16 length followed by UTF-8 text.
    private static func textSample(_ text: String, start: CMTime, duration: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8)
        var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                        blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.writer("block \(status)") }
        status = CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        guard status == noErr else { throw Failure.writer("block data \(status)") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.writer("sample \(status)") }
        return sample
    }
}

/// Samples for one writer input: prepared ones or a reader output, optionally changed on the way.
private final class SampleQueue: @unchecked Sendable {
    private var samples: [CMSampleBuffer]
    private let output: AVAssetReaderOutput?
    private let transform: ((CMSampleBuffer) -> Void)?

    init(_ samples: [CMSampleBuffer]) {
        self.samples = samples
        output = nil
        transform = nil
    }

    init(_ output: AVAssetReaderOutput, transform: ((CMSampleBuffer) -> Void)? = nil) {
        samples = []
        self.output = output
        self.transform = transform
    }

    /// Called only from the input's own serial queue.
    func next() -> CMSampleBuffer? {
        if let output {
            guard let sample = output.copyNextSampleBuffer() else { return nil }
            transform?(sample)
            return sample
        }
        return samples.isEmpty ? nil : samples.removeFirst()
    }
}

private extension Array where Element == AVAssetTrack {
    func asyncAllEnabled() async throws -> Bool {
        for track in self where !(try await track.load(.isEnabled)) { return false }
        return true
    }
}
