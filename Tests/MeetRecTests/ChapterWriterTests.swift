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

    /// One grey H.264 frame per second.
    private func writeTinyMovie(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
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
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
