import XCTest
@testable import MeetRec

/// File names, companions (transcripts, markers), tags and renames: mistakes here lose the link
/// between a video and its transcript.
final class RecordingFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRecTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func touch(_ name: String, _ text: String = "x") -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
        return url
    }

    // MARK: - Names

    func testSplitTimestampFirst() {
        let parts = RecordingFiles.split("2026-10-16 14-03-22 Weekly sync")
        XCTAssertEqual(parts.timestamp, "2026-10-16 14-03-22")
        XCTAssertEqual(parts.title, "Weekly sync")
    }

    func testSplitOlderTitleFirst() {
        let parts = RecordingFiles.split("HZM 2026-04-23 15-20-32")
        XCTAssertEqual(parts.timestamp, "2026-04-23 15-20-32")
        XCTAssertEqual(parts.title, "HZM")
    }

    func testSplitTimestampOnlyAndNoTimestamp() {
        XCTAssertEqual(RecordingFiles.split("2026-10-16 14-03-22").title, "")
        XCTAssertEqual(RecordingFiles.split("2026-10-16 14-03-22").timestamp, "2026-10-16 14-03-22")
        let plain = RecordingFiles.split("Lecture")
        XCTAssertEqual(plain.title, "Lecture")
        XCTAssertNil(plain.timestamp)
    }

    func testStemKeepsTimestampFirst() {
        XCTAssertEqual(RecordingFiles.stem(timestamp: "2026-10-16 14-03-22", title: "Skyeng"), "2026-10-16 14-03-22 Skyeng")
        XCTAssertEqual(RecordingFiles.stem(timestamp: "2026-10-16 14-03-22", title: ""), "2026-10-16 14-03-22")
        XCTAssertEqual(RecordingFiles.stem(timestamp: nil, title: "Lecture"), "Lecture")
    }

    func testTimestampFormat() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
        XCTAssertEqual(RecordingFiles.timestamp(date), "2026-01-02 03-04-05")
    }

    func testSanitize() {
        XCTAssertEqual(RecordingFiles.sanitize("Plan: Q3/Q4  review."), "Plan Q3 Q4 review")
        XCTAssertEqual(RecordingFiles.sanitize(String(repeating: "a", count: 120)).count, 80)
    }

    func testUniqueStem() {
        _ = touch("2026-10-16 14-03-22 Sync.mov")
        XCTAssertEqual(RecordingFiles.uniqueStem("2026-10-16 14-03-22 Sync", in: folder), "2026-10-16 14-03-22 Sync (2)")
        XCTAssertEqual(RecordingFiles.uniqueStem("2026-10-16 14-03-22 Other", in: folder), "2026-10-16 14-03-22 Other")
    }

    // MARK: - Companions and rename

    func testCompanionsIncludeTranscriptVersionsAndMarkers() {
        let video = touch("rec.mov")
        _ = touch("rec.md")
        _ = touch("rec (2).md")
        _ = touch("rec.markers.json")
        _ = touch("rec.mutes.json")
        _ = touch("record.md") // different recording that only shares the prefix
        let names = Set(RecordingFiles.companions(of: video).map(\.lastPathComponent))
        XCTAssertEqual(names, ["rec.md", "rec (2).md", "rec.markers.json", "rec.mutes.json"])
    }

    func testMuteFileRoundTrip() throws {
        let video = touch("rec.mov")
        let spans = [MuteSpan(start: 12.5, end: 40), MuteSpan(start: 61, end: nil)]
        try MuteFile.save(spans, for: video)
        XCTAssertEqual(MuteFile.load(for: video), spans)
        XCTAssertEqual(MuteFile.url(for: video).lastPathComponent, "rec.mutes.json")
    }

    func testCompanionsSkipTranscriptOfSeparateRecording() {
        let video = touch("rec.mov")
        _ = touch("rec.md")
        _ = touch("rec (2).mov")
        _ = touch("rec (2).md") // belongs to "rec (2).mov"
        let names = Set(RecordingFiles.companions(of: video).map(\.lastPathComponent))
        XCTAssertEqual(names, ["rec.md"])
    }

    func testRenameMovesCompanionsAndKeepsTag() throws {
        let video = touch("2026-10-16 14-03-22.mov")
        _ = touch("2026-10-16 14-03-22.md", "transcript")
        _ = touch("2026-10-16 14-03-22.markers.json", "[]")
        RecordingTag.setMeetingApp("teams", on: video)

        let renamed = try RecordingFiles.rename(video, to: "2026-10-16 14-03-22 Weekly sync")

        XCTAssertEqual(renamed.lastPathComponent, "2026-10-16 14-03-22 Weekly sync.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-10-16 14-03-22 Weekly sync.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-10-16 14-03-22 Weekly sync.markers.json").path))
        XCTAssertEqual(RecordingTag.meetingApp(of: renamed), "teams", "the meeting tag must survive a rename")
    }

    func testRenameRefusesToOverwrite() {
        let video = touch("a.mov")
        _ = touch("b.mov")
        XCTAssertThrowsError(try RecordingFiles.rename(video, to: "b"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    // MARK: - Tags

    func testTags() {
        let video = touch("rec.mov")
        XCTAssertNil(RecordingTag.meetingApp(of: video))
        XCTAssertNil(RecordingTag.rule(of: video))
        RecordingTag.setMeetingApp("browser", on: video)
        RecordingTag.setRule("RULE-1", on: video)
        XCTAssertEqual(RecordingTag.meetingApp(of: video), "browser")
        XCTAssertEqual(RecordingTag.rule(of: video), "RULE-1")
    }

    // MARK: - Transcript lookup

    @MainActor
    func testExistingTranscriptIsTheNewestVersion() {
        let video = touch("rec.mov")
        XCTAssertNil(Transcriber.existingTranscript(for: video))
        _ = touch("rec.md")
        XCTAssertEqual(Transcriber.existingTranscript(for: video)?.lastPathComponent, "rec.md")
        _ = touch("rec (2).md")
        XCTAssertEqual(Transcriber.existingTranscript(for: video)?.lastPathComponent, "rec (2).md")
    }

    @MainActor
    func testExistingTranscriptIgnoresSeparateRecording() {
        let video = touch("rec.mov")
        _ = touch("rec.md")
        _ = touch("rec (2).mov")
        _ = touch("rec (2).md")
        XCTAssertEqual(Transcriber.existingTranscript(for: video)?.lastPathComponent, "rec.md")
    }

    // MARK: - Markers

    func testMarkerTimeText() {
        XCTAssertEqual(Marker(time: 65.9).timeText, "01:05")
        XCTAssertEqual(Marker(time: 3725).timeText, "1:02:05")
    }

    func testMarkerFileRoundTrip() throws {
        let video = touch("rec.mov")
        XCTAssertEqual(MarkerFile.load(for: video), [])
        try MarkerFile.save([Marker(time: 12), Marker(time: 340.5)], for: video)
        XCTAssertEqual(MarkerFile.url(for: video).lastPathComponent, "rec.markers.json")
        XCTAssertEqual(MarkerFile.load(for: video).map(\.time), [12, 340.5])
    }

    // MARK: - Disk space

    func testDiskSpaceIsKnownForMissingSubfolder() {
        XCTAssertNotNil(DiskSpace.available(at: folder.appendingPathComponent("not/yet/created")))
    }
}

extension RecordingFilesTests {
    func testBrowserRuleShowsTheFileNameItGives() {
        let date = ISO8601DateFormatter().date(from: "2026-10-17T10:03:22Z")!
        let stamp = RecordingFiles.timestamp(date)
        XCTAssertEqual(BrowserRulesEditor.exampleFileName(title: " Skyeng ", date: date), "\(stamp) Skyeng.mov")
        XCTAssertEqual(BrowserRulesEditor.exampleFileName(title: "", date: date), "\(stamp).mov")
    }
}

/// The free space during a recording: the slow exact value once a minute, the cheap one in between.
final class FreeSpaceEstimateTests: XCTestCase {
    func testMovesTheExactValueByThePlainChange() {
        var estimate = FreeSpaceEstimate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var exactCalls = 0
        // macOS could purge 5 GB more than the plain free space shows.
        var plain: Int64 = 10_000_000_000
        func check(_ seconds: TimeInterval) -> Int64? {
            estimate.check(exact: { exactCalls += 1; return plain + 5_000_000_000 }, plain: { plain },
                           now: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(check(0), 15_000_000_000)
        plain -= 300_000_000 // the recording wrote 300 MB
        XCTAssertEqual(check(10), 14_700_000_000)
        XCTAssertEqual(exactCalls, 1)
        plain -= 100_000_000
        XCTAssertEqual(check(61), 14_600_000_000)
        XCTAssertEqual(exactCalls, 2)
    }

    func testPlainFreeSpaceIsReadable() throws {
        let free = try XCTUnwrap(DiskSpace.plain(at: FileManager.default.temporaryDirectory.appendingPathComponent("missing/deeper")))
        XCTAssertGreaterThan(free, 0)
    }
}
