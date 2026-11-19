import CoreGraphics
import XCTest
@testable import MeetRec

/// The panel's strips: a renamed recording keeps its cached preview, a changed file gets a new one,
/// black frames are not taken as posters, and pages of a big folder count every recording.
final class ThumbnailTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRecThumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testKeyFollowsTheFileNotItsName() throws {
        let file = folder.appendingPathComponent("a.mov")
        try Data("one".utf8).write(to: file)
        let key = try XCTUnwrap(Thumbnails.key(for: file))
        let renamed = folder.appendingPathComponent("b.mov")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertEqual(Thumbnails.key(for: renamed), key)
        try Data("changed".utf8).write(to: renamed)
        XCTAssertNotEqual(Thumbnails.key(for: renamed), key)
        XCTAssertNil(Thumbnails.key(for: file))
    }

    func testDarkFrame() throws {
        XCTAssertTrue(Thumbnails.isDark(try image(gray: 0.02)))
        XCTAssertFalse(Thumbnails.isDark(try image(gray: 0.5)))
    }

    @MainActor
    func testPageCountsAllRecordingsAndTranscripts() throws {
        for index in 0..<5 {
            let video = RecordingFiles.newRecording("2026-10-1\(index) 10-00-00", in: folder)
            try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: video)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: Double(index) * 60)], ofItemAtPath: video.path)
            if index.isMultiple(of: 2) {
                try Data("text".utf8).write(to: video.deletingPathExtension().appendingPathExtension("md"))
            }
        }
        let page = RecordingsStore.page(from: folder, limit: 2)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.transcribed, 3)
        XCTAssertEqual(page.items.first?.date, Date(timeIntervalSince1970: 240))
    }

    private func image(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return try XCTUnwrap(context.makeImage())
    }
}
