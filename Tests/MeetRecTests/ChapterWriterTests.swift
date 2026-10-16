import AVFoundation
import XCTest
@testable import MeetRec

/// Markers turned into chapters of a real (tiny) movie: the file must keep its media and gain chapters.
final class ChapterWriterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testChapterTitles() {
        let chapters = ChapterWriter.chapters(for: [Marker(time: 754), Marker(time: 0.2), Marker(time: 65), Marker(time: 65)],
                                              duration: 3600)
        XCTAssertEqual(chapters.map(\.start), [0, 65, 754])
        XCTAssertEqual(chapters.map(\.title), ["Начало", "⭐ 1 · 01:05", "⭐ 2 · 12:34"])
    }

    func testAddsChaptersAndKeepsMediaAndTags() async throws {
        let movie = folder.appendingPathComponent("rec.mov")
        try await writeTinyMovie(to: movie, seconds: 4)
        RecordingTag.setMeetingApp("browser", on: movie)
        RecordingTag.setRule("RULE", on: movie)

        try await ChapterWriter.addChapters([Marker(time: 1), Marker(time: 2.5)], to: movie)

        let asset = AVURLAsset(url: movie)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale(identifier: "ru"),
                                                                containingItemsWithCommonKeys: [])
        XCTAssertEqual(groups.map { ($0.timeRange.start.seconds * 10).rounded() / 10 }, [0, 1, 2.5])
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.3)
        XCTAssertEqual(RecordingTag.meetingApp(of: movie), "browser")
        XCTAssertEqual(RecordingTag.rule(of: movie), "RULE")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["rec.mov"], "no temporary file may stay behind")
    }

    func testFileWithoutVideoIsLeftAlone() async throws {
        let notAMovie = folder.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: notAMovie)
        do {
            try await ChapterWriter.addChapters([Marker(time: 1)], to: notAMovie)
            XCTFail("must throw")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: notAMovie), Data("not a movie".utf8))
    }

    func testRecordingGetsMixedTrackFirst() async throws {
        let movie = folder.appendingPathComponent("rec.mov")
        // Like the recorder: system audio (loud) first, then the microphone (10 dB quieter).
        try await writeTinyMovie(to: movie, seconds: 4, audioAmplitudes: [0.3, 0.095])

        try await ChapterWriter.finish(movie, markers: [])

        let asset = AVURLAsset(url: movie)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 3)
        var enabled: [Bool] = []
        for track in audio { enabled.append(try await track.load(.isEnabled)) }
        XCTAssertEqual(enabled, [true, false, false], "only the mix plays by default")
        let mixDuration = try await audio[0].load(.timeRange).duration.seconds
        XCTAssertEqual(mixDuration, 4, accuracy: 0.3)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, ["rec.mov"])

        // Adding chapters later keeps the layout.
        try await ChapterWriter.addChapters([Marker(time: 2)], to: movie)
        let again = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(again.count, 3)
        let firstEnabled = try await again[0].load(.isEnabled)
        let secondEnabled = try await again[1].load(.isEnabled)
        XCTAssertTrue(firstEnabled)
        XCTAssertFalse(secondEnabled)
    }

    func testMicrophoneGain() {
        XCTAssertEqual(AudioMixer.gain(microphone: -32, system: -22), 10)
        XCTAssertEqual(AudioMixer.gain(microphone: -15, system: -22), 0, "never turned down")
        XCTAssertEqual(AudioMixer.gain(microphone: -60, system: -20), AudioMixer.maxGainDB)
        XCTAssertEqual(AudioMixer.gain(microphone: -30, system: nil), 10, "alone: to the target level")
        XCTAssertEqual(AudioMixer.limit(0.5), 0.5)
        XCTAssertLessThanOrEqual(AudioMixer.limit(3), 1)
        XCTAssertGreaterThan(AudioMixer.limit(0.95), 0.9)
        XCTAssertGreaterThanOrEqual(AudioMixer.limit(-3), -1)
    }

    /// One grey H.264 frame per second, plus mono sine audio tracks of the given amplitudes.
    private func writeTinyMovie(to url: URL, seconds: Int, audioAmplitudes: [Float] = []) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        let audioInputs = audioAmplitudes.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            ])
        }
        audioInputs.forEach { writer.add($0) }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // Fed together: the writer interleaves the tracks and stalls one that runs ahead.
        let audioWriting = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (audioInput, amplitude) in zip(audioInputs, audioAmplitudes) {
                    group.addTask { try await Self.writeSine(to: audioInput, amplitude: amplitude, seconds: seconds) }
                }
                try await group.waitForAll()
            }
        }
        defer { audioWriting.cancel() }
        for second in 0...seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
        }
        input.markAsFinished()
        try await audioWriting.value
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private static func writeSine(to input: AVAssetWriterInput, amplitude: Float, seconds: Int) async throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let chunk = 4800
        for index in 0..<(seconds * 10) {
            var data = (0..<chunk).map { amplitude * sin(Float(index * chunk + $0) * 2 * .pi * 440 / 48_000) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: chunk * 4, flags: 0,
                                               blockBufferOut: &block)
            let buffer = try XCTUnwrap(block)
            CMBlockBufferReplaceDataBytes(with: &data, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: chunk * 4)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(index * chunk), timescale: 48_000), packetDescriptions: nil,
                sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            input.append(try XCTUnwrap(sample))
        }
        input.markAsFinished()
    }
}
