import AVFoundation
import CoreMedia

/// Turns the moments marked during a recording into chapters of the video file, so any player shows
/// them (QuickTime: View → Show Chapters; IINA, VLC).
///
/// The fragmented recording cannot get a track added in place, so the file is copied without
/// re-encoding (AVAssetReader → AVAssetWriter, passthrough; about a second per minute of video) with an
/// extra text track associated with the video as its chapter list. The copy replaces the original only
/// after it was read back and checked (same tracks plus chapters, same duration); on any failure the
/// original stays untouched.
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

    /// "Начало", "⭐ 1 · 12:34", "⭐ 2 · 25:10"…: chapter starts and titles for the markers.
    static func chapters(for markers: [Marker], duration: Double) -> [(start: Double, title: String)] {
        let times = Array(Set(markers.map(\.time).filter { $0 > 0.5 && $0 < duration - 0.5 })).sorted()
        return [(0, "Начало")] + times.enumerated().map { index, time in
            (time, "⭐ \(index + 1) · \(Marker(time: time).timeText)")
        }
    }

    /// Adds the markers as chapters to `file`. Throws (and leaves the file as it was) on failure.
    static func addChapters(_ markers: [Marker], to file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw Failure.noVideo }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if let free = DiskSpace.available(at: file), free < size + DiskSpace.stopBelow { throw Failure.notEnoughSpace }

        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent).chapters.mov")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let started = Date()
        try await remux(asset, tracks: tracks, duration: duration, chapters: chapters(for: markers, duration: duration.seconds),
                        to: temporary)
        try await verify(temporary, against: tracks.count, duration: duration)

        // Tags live in extended attributes; carry them over explicitly.
        let app = RecordingTag.meetingApp(of: file)
        let rule = RecordingTag.rule(of: file)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        if let app { RecordingTag.setMeetingApp(app, on: file) }
        if let rule { RecordingTag.setRule(rule, on: file) }
        Log.info("Chapters added to \(file.lastPathComponent): \(markers.count) marker(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s", "recorder")
    }

    // MARK: - Private

    private static func remux(_ asset: AVURLAsset, tracks: [AVAssetTrack], duration: CMTime,
                              chapters: [(start: Double, title: String)], to output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var videoInput: AVAssetWriterInput?
        for track in tracks {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { throw Failure.writer("cannot read \(track.mediaType.rawValue)") }
            reader.add(readerOutput)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.writer("cannot write \(track.mediaType.rawValue)") }
            writer.add(input)
            pairs.append((readerOutput, input))
            if track.mediaType == .video, videoInput == nil { videoInput = input }
        }
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

        guard reader.startReading() else { throw Failure.writer(Log.describe(reader.error)) }
        guard writer.startWriting() else { throw Failure.writer(Log.describe(writer.error)) }
        writer.startSession(atSourceTime: .zero)
        // All inputs are fed at once: the writer interleaves them and stalls an input that runs ahead.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await feed(chapterInput, from: SampleQueue(samples)) }
            for (readerOutput, input) in pairs {
                group.addTask { await feed(input, from: SampleQueue(readerOutput)) }
            }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            throw Failure.writer("reader \(reader.status.rawValue) \(Log.describe(reader.error)), writer \(writer.status.rawValue) \(Log.describe(writer.error))")
        }
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

    private static func verify(_ file: URL, against mediaTracks: Int, duration: CMTime) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.load(.tracks)
        let media = tracks.filter { $0.mediaType == .video || $0.mediaType == .audio }.count
        guard media == mediaTracks else { throw Failure.verification("\(media) of \(mediaTracks) tracks") }
        let newDuration = try await asset.load(.duration)
        guard abs(newDuration.seconds - duration.seconds) < 1 else {
            throw Failure.verification(String(format: "duration %.1f s instead of %.1f s", newDuration.seconds, duration.seconds))
        }
        let locales = try await asset.load(.availableChapterLocales)
        guard !locales.isEmpty else { throw Failure.verification("no chapters") }
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

/// Samples for one writer input: either prepared ones or a track being read.
private final class SampleQueue: @unchecked Sendable {
    private var samples: [CMSampleBuffer]
    private let output: AVAssetReaderTrackOutput?

    init(_ samples: [CMSampleBuffer]) {
        self.samples = samples
        output = nil
    }

    init(_ output: AVAssetReaderTrackOutput) {
        samples = []
        self.output = output
    }

    /// Called only from the input's own serial queue.
    func next() -> CMSampleBuffer? {
        if let output { return output.copyNextSampleBuffer() }
        return samples.isEmpty ? nil : samples.removeFirst()
    }
}
