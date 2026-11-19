import XCTest
@testable import MeetRec

/// The transcript in a recording's tip: no file header, speakers and times split off, the search
/// hit first, a summary section preferred.
final class TranscriptPreviewTests: XCTestCase {
    private let transcript = """
    # Transcription: 2026-11-18 10-04-09 Lesson.mov
    - Date: 18 Nov 2026 at 10:51:53
    - Engine: Parakeet Ultra + FluidAudio diarization
    - Language: en

    [00:00:00] Мария: Yep, and so here we are.

    ⭐ [00:00:20] Отметка 1

    [00:00:39] Alex: I think should I use only one

    [00:00:48] Мария: It's your choice, no rules here.
    """

    func testSkipsHeaderAndSplitsLines() {
        let preview = TranscriptPreview.parse(transcript)
        XCTAssertFalse(preview.isSummary)
        XCTAssertEqual(preview.lines.first, .init(time: "00:00:00", speaker: "Мария", text: "Yep, and so here we are."))
        XCTAssertEqual(preview.lines[1], .init(text: "⭐ [00:00:20] Отметка 1"))
        XCTAssertEqual(preview.lines.count, 4)
        XCTAssertEqual(preview.words, 6 + 7 + 6)
    }

    func testMonologueLinesHaveNoSpeaker() {
        let text = "# Transcription: x.mov\n- Speaker: Dima\n\n[00:00:00] Так, значит: вот этот\n\n[00:00:12] Ещё один\n"
        let preview = TranscriptPreview.parse(text)
        XCTAssertEqual(preview.lines, [.init(time: "00:00:00", text: "Так, значит: вот этот"), .init(time: "00:00:12", text: "Ещё один")])
        XCTAssertEqual(preview.words, 4 + 2)
    }

    func testStartsAtSearchHit() {
        let preview = TranscriptPreview.parse(transcript, query: "RULES")
        XCTAssertEqual(preview.lines.map(\.speaker), ["Мария"])
        XCTAssertEqual(preview.lines.first?.time, "00:00:48")
    }

    func testSummaryFirst() {
        let text = transcript.replacingOccurrences(of: "- Language: en\n", with: "- Language: en\n\n## Резюме\n- Обсудили бонусы\n- Договорились о следующем уроке\n\n## Транскрипт\n")
        let preview = TranscriptPreview.parse(text)
        XCTAssertTrue(preview.isSummary)
        XCTAssertEqual(preview.lines.map(\.text), ["• Обсудили бонусы", "• Договорились о следующем уроке"])
        XCTAssertEqual(preview.words, 19)
    }
}
