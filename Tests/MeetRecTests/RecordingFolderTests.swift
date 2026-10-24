import XCTest
@testable import MeetRec

/// One folder per recording (`<stem>/<stem>.mov`) and the move of flat recordings into folders: a
/// mistake here separates a video from its transcript or loses its speakers.
final class RecordingFolderTests: XCTestCase {
    private var library: URL!
    private var runs: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetRecFolders-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("Recordings", isDirectory: true)
        runs = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    @discardableResult
    private func touch(_ path: String, in base: URL? = nil, _ text: String = "x") -> URL {
        let url = (base ?? library).appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
        return url
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: library.appendingPathComponent(path).path)
    }

    func testFilesOfARecordingInItsFolder() {
        let video = RecordingFiles.newRecording("2026-10-16 14-03-22", in: library)
        XCTAssertEqual(video.path, library.appendingPathComponent("2026-10-16 14-03-22/2026-10-16 14-03-22.mov").path)
        XCTAssertEqual(RecordingFiles.ownFolder(of: video)?.lastPathComponent, "2026-10-16 14-03-22")
        XCTAssertEqual(RecordingFiles.library(of: video).path, library.path)
        XCTAssertEqual(MarkerFile.url(for: video).lastPathComponent, "markers.json")
        XCTAssertEqual(MuteFile.url(for: video).lastPathComponent, "mutes.json")
        XCTAssertEqual(SpeakerNaming.runURL(for: video).path, video.deletingLastPathComponent().appendingPathComponent("run.json").path)

        let flat = library.appendingPathComponent("rec.mov")
        XCTAssertNil(RecordingFiles.ownFolder(of: flat))
        XCTAssertEqual(MarkerFile.url(for: flat).lastPathComponent, "rec.markers.json")
        XCTAssertEqual(SpeakerNaming.runURL(for: flat).deletingLastPathComponent().lastPathComponent, "runs")
    }

    @MainActor
    func testRecordingsListHasFoldersAndFlatFilesButNotOtherFolders() {
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22.mov")
        touch("2026-10-17 09-00-00.mov")
        touch("Скриншоты/shot.png")
        touch("Other/clip.mov")
        let names = RecordingsStore.load(from: library).map(\.url.lastPathComponent).sorted()
        XCTAssertEqual(names, ["2026-10-16 14-03-22.mov", "2026-10-17 09-00-00.mov"])
    }

    func testRenameRenamesFolderVideoAndTranscripts() throws {
        let video = touch("2026-10-16 14-03-22/2026-10-16 14-03-22.mov")
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22.md")
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22 (2).md")
        touch("2026-10-16 14-03-22/markers.json", in: nil, "[]")
        touch("2026-10-16 14-03-22/run.json", in: nil, "{}")
        RecordingTag.setMeetingApp("teams", on: video)

        let renamed = try RecordingFiles.rename(video, to: "2026-10-16 14-03-22 Weekly sync")

        let stem = "2026-10-16 14-03-22 Weekly sync"
        XCTAssertEqual(renamed.path, library.appendingPathComponent("\(stem)/\(stem).mov").path)
        XCTAssertFalse(exists("2026-10-16 14-03-22"))
        for name in ["\(stem).md", "\(stem) (2).md", "markers.json", "run.json"] {
            XCTAssertTrue(exists("\(stem)/\(name)"), name)
        }
        XCTAssertEqual(RecordingTag.meetingApp(of: renamed), "teams")
        XCTAssertEqual(RecordingFiles.uniqueStem(stem, in: library), "\(stem) (2)", "a folder takes the name too")
    }

    func testRenameRefusesAnExistingFolder() {
        let video = touch("a/a.mov")
        touch("b/b.mov")
        XCTAssertThrowsError(try RecordingFiles.rename(video, to: "b"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testTrashTakesTheWholeFolder() throws {
        let video = touch("2026-10-16 14-03-22/2026-10-16 14-03-22.mov")
        touch("2026-10-16 14-03-22/run.json")
        try RecordingFiles.trash(video)
        XCTAssertFalse(exists("2026-10-16 14-03-22"))
    }

    @MainActor
    func testNewTranscriptVersionInTheFolder() {
        let video = touch("2026-10-16 14-03-22/2026-10-16 14-03-22.mov")
        XCTAssertEqual(Transcriber.transcriptURL(for: video).lastPathComponent, "2026-10-16 14-03-22.md")
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22.md")
        XCTAssertEqual(Transcriber.transcriptURL(for: video).lastPathComponent, "2026-10-16 14-03-22 (2).md")
    }

    @MainActor
    func testFlatTranscriptVersionSkipsASeparateRecordingsName() {
        let video = touch("rec.mov")
        touch("rec.md")
        touch("rec (2).mov")
        XCTAssertEqual(Transcriber.transcriptURL(for: video).lastPathComponent, "rec (3).md")
    }

    // MARK: - Migration

    func testMigrationMovesARecordingWithEverythingThatBelongsToIt() {
        let stem = "2026-10-16 14-03-22 Weekly sync"
        let video = touch("\(stem).mov")
        touch("\(stem).md")
        touch("\(stem) (2).md")
        touch("\(stem).markers.json", in: nil, "[]")
        touch("\(stem).mutes.json", in: nil, "[]")
        touch("\(stem).json", in: runs, "{}")
        RecordingTag.setMeetingApp("teams", on: video)

        let moves = RecordingsMigration.run(in: library, runsDir: runs)

        let target = library.appendingPathComponent("\(stem)/\(stem).mov")
        XCTAssertEqual(moves, [RecordingsMigration.Move(from: video, to: target)])
        for name in ["\(stem).mov", "\(stem).md", "\(stem) (2).md", "markers.json", "mutes.json", "run.json"] {
            XCTAssertTrue(exists("\(stem)/\(name)"), name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [stem])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runs.appendingPathComponent("\(stem).json").path))
        XCTAssertEqual(RecordingTag.meetingApp(of: target), "teams")
        XCTAssertEqual(MarkerFile.url(for: target).deletingLastPathComponent().lastPathComponent, stem)
    }

    func testMigrationLeavesNamesWithoutTimestampAndOthersAlone() {
        touch("Restoring database (SMI).mov")
        touch("HZM 2026-10-01 10-00.mov")
        touch("notes.txt")
        touch("Скриншоты/shot.png")
        XCTAssertTrue(RecordingsMigration.run(in: library, runsDir: runs).isEmpty)
        XCTAssertTrue(exists("Restoring database (SMI).mov"))
        XCTAssertTrue(exists("HZM 2026-10-01 10-00.mov"))
    }

    func testMigrationDoesNotOverwrite() {
        touch("2026-10-16 14-03-22.mov", in: nil, "flat")
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22.mov", in: nil, "in folder")
        XCTAssertTrue(RecordingsMigration.run(in: library, runsDir: runs).isEmpty)
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("2026-10-16 14-03-22.mov"), encoding: .utf8), "flat")
    }

    func testMigrationFinishesAnInterruptedMove() {
        // The transcript went first, then the move stopped: the folder exists without the video.
        touch("2026-10-16 14-03-22/2026-10-16 14-03-22.md")
        touch("2026-10-16 14-03-22.mov")
        XCTAssertEqual(RecordingsMigration.run(in: library, runsDir: runs).count, 1)
        XCTAssertTrue(exists("2026-10-16 14-03-22/2026-10-16 14-03-22.mov"))
        XCTAssertFalse(exists("2026-10-16 14-03-22.mov"))
    }
}
