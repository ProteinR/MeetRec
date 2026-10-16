import XCTest
@testable import MeetRec

/// Speaker renaming in transcripts, window titles, meeting apps and rules.
final class TranscriptAndRulesTests: XCTestCase {
    private let transcript = """
    # Transcription: x.mov
    - Date: 16 Oct 2026

    [00:00:00] Dima: hello

    [00:00:05] Speaker 1: there

    ⭐ [00:00:06] Отметка

    [00:00:07] Speaker 1: again

    [00:00:09] Speaker 2: other

    """

    func testRenameSpeakerJoinsNeighbouringLines() {
        let result = SpeakerNaming.rename("Speaker 1", to: "Dima", in: transcript)
        XCTAssertTrue(result.contains("[00:00:00] Dima: hello there"))
        // The marker separates turns, so the line after it stays its own.
        XCTAssertTrue(result.contains("⭐ [00:00:06] Отметка\n\n[00:00:07] Dima: again"))
        XCTAssertTrue(result.contains("[00:00:09] Speaker 2: other"))
        XCTAssertFalse(result.contains("Speaker 1"))
        XCTAssertTrue(result.hasSuffix("\n"))
    }

    func testRenameSpeakerLeavesOthersAlone() {
        let result = SpeakerNaming.rename("Speaker 3", to: "Falk", in: transcript)
        XCTAssertEqual(result, transcript)
    }

    func testRenameDoesNotTouchNamesInsideText() {
        let text = "[00:00:01] Speaker 1: I told Speaker 1: no\n"
        XCTAssertEqual(SpeakerNaming.rename("Speaker 1", to: "Elena", in: text), "[00:00:01] Elena: I told Speaker 1: no\n")
    }

    func testMeetingTitleClean() {
        XCTAssertEqual(MeetingTitle.clean("Weekly sync | Microsoft Teams"), "Weekly sync")
        XCTAssertEqual(MeetingTitle.clean("Weekly sync | Calendar | Microsoft Teams"), "Weekly sync")
        XCTAssertEqual(MeetingTitle.clean("(11) Vimbox - Google Chrome"), "(11) Vimbox")
        XCTAssertEqual(MeetingTitle.tabKey("(3) • Английский Skysmart 🔊 - Google Chrome"), "Английский Skysmart")
        XCTAssertEqual(MeetingTitle.tabKey("Английский Skysmart"), "Английский Skysmart")
        XCTAssertEqual(MeetingTitle.tabKey("🔊"), "")
    }

    func testMeetingAppsMatchTheirProcesses() throws {
        let teams = try XCTUnwrap(MeetingApp.all.first { $0.id == "teams" })
        let browser = try XCTUnwrap(MeetingApp.all.first { $0.id == "browser" })
        let telegram = try XCTUnwrap(MeetingApp.all.first { $0.id == "telegram" })
        XCTAssertTrue(teams.matches("com.microsoft.teams2.modulehost"))
        XCTAssertTrue(browser.matches("com.google.Chrome.helper"))
        XCTAssertTrue(browser.matches("com.brave.Browser.helper"))
        XCTAssertTrue(browser.matches("com.apple.WebKit.GPU"))
        XCTAssertFalse(browser.matches("com.anthropic.claudefordesktop.helper"))
        XCTAssertFalse(browser.matches("com.apple.CoreSpeech"))
        XCTAssertTrue(telegram.matches("ru.keepcoder.Telegram"))
        XCTAssertFalse(teams.asks)
        XCTAssertTrue(browser.asks && telegram.asks)
    }

    func testMeetingWording() throws {
        let teams = try XCTUnwrap(MeetingApp.all.first { $0.id == "teams" })
        let browser = try XCTUnwrap(MeetingApp.all.first { $0.id == "browser" })
        XCTAssertEqual(teams.noun, "встреча")
        XCTAssertEqual(browser.noun, "звонок")
        XCTAssertEqual(browser.promptTitle(reminder: false), "Похоже, идёт звонок в браузере")
        XCTAssertEqual(teams.promptTitle(reminder: true), "Идёт встреча в Teams, запись не ведётся")
    }

    func testRulesRoundTripAndKeys() throws {
        let rule = BrowserRule(keyword: "Vimbox", title: "Skyeng")
        let decoded = try JSONDecoder().decode([BrowserRule].self, from: JSONEncoder().encode([rule]))
        XCTAssertEqual(decoded, [rule])
        XCTAssertEqual(CopyRule.ruleKey(rule.id.uuidString), "rule:\(rule.id.uuidString)")
        let copy = CopyRule(app: "teams", folder: "/tmp/meetings")
        XCTAssertEqual(try JSONDecoder().decode(CopyRule.self, from: JSONEncoder().encode(copy)), copy)
    }

    @MainActor
    func testElapsedText() {
        let live = LiveRecording()
        live.update(elapsed: 65.9)
        XCTAssertEqual(live.elapsedText, "01:05")
        live.update(elapsed: 3725.2)
        XCTAssertEqual(live.elapsedText, "1:02:05")
    }
}

/// The live recording status: what counts as a problem and what does not.
final class HealthTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func tracker(mic: Bool = true, system: Bool = true) -> HealthTracker {
        HealthTracker(startedAt: start, microphoneOn: mic, systemAudioOn: system, microphoneName: "Mic", displayName: "Display")
    }

    private func status(at seconds: TimeInterval, micPeak: Float, luma: Int? = 200, file: URL? = nil) -> LiveStatus {
        var status = LiveStatus()
        let now = start.addingTimeInterval(seconds)
        status.micPeak = micPeak
        status.systemPeak = 0
        status.lastMicBuffer = now
        status.lastSystemBuffer = now
        status.lastScreenSample = now
        status.frameMaxLuma = luma
        status.fileURL = file
        return status
    }

    /// Feeds one snapshot per second and returns the last health.
    private func run(_ tracker: inout HealthTracker, seconds: Int, micPeak: Float, luma: Int? = 200, file: URL? = nil) -> RecordingHealth {
        var health: RecordingHealth!
        for second in 0...seconds {
            let at = TimeInterval(second)
            health = tracker.update(with: status(at: at, micPeak: micPeak, luma: luma, file: file), now: start.addingTimeInterval(at))
        }
        return health
    }

    func testListeningQuietlyIsNotAProblem() {
        var tracker = tracker()
        // Room noise around -50 dB: the user listens, the microphone works.
        let health = run(&tracker, seconds: 90, micPeak: 0.003)
        XCTAssertEqual(health.microphone.state, .ok)
        XCTAssertLessThan(health.micSilentFor, 2)
        XCTAssertFalse(health.hasProblem)
    }

    func testDeadSilenceIsFlagged() {
        var tracker = tracker()
        let health = run(&tracker, seconds: 70, micPeak: 0)
        XCTAssertEqual(health.microphone.state, .quiet)
        XCTAssertGreaterThanOrEqual(health.micSilentFor, 60)
    }

    func testMutedMicrophoneIsIntentional() {
        var tracker = tracker()
        var health: RecordingHealth!
        for second in 0...70 {
            let at = TimeInterval(second)
            health = tracker.update(with: status(at: at, micPeak: 0), micMuted: true, now: start.addingTimeInterval(at))
        }
        XCTAssertLessThan(health.micSilentFor, 2)
        XCTAssertTrue(health.microphone.detail.contains("выключен кнопкой"))
    }

    func testBlackScreenAfterThirtySeconds() {
        var tracker = tracker()
        XCTAssertEqual(run(&tracker, seconds: 10, micPeak: 0.1, luma: 16).screen.state, .ok)
        var later = self.tracker()
        let health = run(&later, seconds: 40, micPeak: 0.1, luma: 16)
        XCTAssertGreaterThanOrEqual(health.blackFor, 30)
        XCTAssertEqual(health.screen.state, .quiet)
    }

    func testFileThatStopsGrowingIsAProblem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: file.path, contents: Data("frozen".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        var tracker = tracker()
        let health = run(&tracker, seconds: 35, micPeak: 0.1, file: file)
        XCTAssertGreaterThanOrEqual(health.fileStalledFor, HealthTracker.fileStalledAfter)
        XCTAssertEqual(health.file.state, .noSignal)
        XCTAssertTrue(health.hasProblem)
    }

    func testLowDiskIsShown() {
        var tracker = tracker()
        let health = tracker.update(with: status(at: 1, micPeak: 0.1), freeSpace: 1_000_000_000, now: start.addingTimeInterval(1))
        XCTAssertTrue(health.diskLow)
        XCTAssertEqual(health.file.state, .noSignal)
    }
}

final class WindowFitTests: XCTestCase {
    func testWideWindowIsCentredVertically() {
        // 1815×892 window into a 2560×1440 frame: full width, equal bars above and below.
        let rect = ScreenRecorder.centeredRect(content: CGRect(x: 1869, y: 408, width: 1815, height: 892), width: 2560, height: 1440)
        XCTAssertEqual(rect.width, 2560)
        XCTAssertEqual(rect.height, 1258)
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 91)
    }

    func testTallWindowIsCentredHorizontally() {
        let rect = ScreenRecorder.centeredRect(content: CGRect(x: 0, y: 0, width: 800, height: 1000), width: 1920, height: 1080)
        XCTAssertEqual(rect.height, 1080)
        XCTAssertEqual(rect.width, 864)
        XCTAssertEqual(rect.minX, 528)
        XCTAssertEqual(rect.minY, 0)
    }
}
