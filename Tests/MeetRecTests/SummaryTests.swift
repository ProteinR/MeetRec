import XCTest
@testable import MeetRec

final class SummaryTests: XCTestCase {
    private let transcript = """
    # Transcription: 2026-11-19 10-00-00 Sync.mov
    - Date: 19 Nov 2026 at 10:30:00
    - Engine: Parakeet Ultra
    - Language: en

    [00:00:01] Dima: Hi, let's start.

    [00:00:05] Speaker 2: Sure, the release is on Friday.

    """

    func testInsertsSummaryUnderHeaderWithTranscriptHeading() {
        let result = SummaryText.inserting("Release on Friday.\n\n### Decisions\n- Ship it", into: transcript,
                                           heading: "Суммаризация", transcriptHeading: "Транскрипт")
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines[4], "")
        XCTAssertEqual(lines[5], "## Суммаризация")
        XCTAssertTrue(result.contains("### Decisions\n- Ship it\n\n## Транскрипт\n\n[00:00:01] Dima: Hi, let's start."))
        XCTAssertTrue(result.hasPrefix("# Transcription: 2026-11-19 10-00-00 Sync.mov\n- Date:"))
        XCTAssertEqual(SummaryText.summary(of: result), "Release on Friday.\n\n### Decisions\n- Ship it")
    }

    func testRerunReplacesAnOldResumeHeading() {
        let old = SummaryText.inserting("Old.", into: transcript, heading: "Резюме", transcriptHeading: "Транскрипт")
        let new = SummaryText.inserting("New.", into: old, heading: "Суммаризация", transcriptHeading: "Транскрипт")
        XCTAssertFalse(new.contains("## Резюме"))
        XCTAssertFalse(new.contains("Old."))
        XCTAssertEqual(SummaryText.summary(of: new), "New.")
    }

    func testReplacingKeepsOneSummaryAndOneTranscriptHeading() {
        let first = SummaryText.inserting("Old.", into: transcript, heading: "Суммаризация", transcriptHeading: "Транскрипт")
        let second = SummaryText.inserting("New.", into: first, heading: "Суммаризация", transcriptHeading: "Транскрипт")
        XCTAssertEqual(second.components(separatedBy: "## Суммаризация").count, 2)
        XCTAssertEqual(second.components(separatedBy: "## Транскрипт").count, 2)
        XCTAssertFalse(second.contains("Old."))
        XCTAssertEqual(SummaryText.summary(of: second), "New.")
        XCTAssertEqual(SummaryText.removingSummary(second).contains("[00:00:05] Speaker 2"), true)
    }

    func testPreviewShowsSummaryWithSubheadings() {
        let text = SummaryText.inserting("About the release.\n\n### Action items\n- **Dima**: send notes", into: transcript,
                                         heading: "Summary", transcriptHeading: "Transcript")
        let preview = TranscriptPreview.parse(text)
        XCTAssertTrue(preview.isSummary)
        XCTAssertEqual(preview.lines.map(\.text), ["About the release.", "Action items", "• Dima: send notes"])
        XCTAssertEqual(preview.words, 9)
    }

    func testCleanedDropsFenceAndOwnTitle() {
        XCTAssertEqual(SummaryText.cleaned("```markdown\n# Summary\n\nText.\n## Decisions\n- A\n```"), "Text.\n### Decisions\n- A")
    }

    func testSpeakerRenameReachesSummary() {
        let text = SummaryText.inserting("- **Speaker 2**: ships on Friday; Speaker 21 does not.", into: transcript,
                                         heading: "Суммаризация", transcriptHeading: "Транскрипт")
        let renamed = SpeakerNaming.rename("Speaker 2", to: "Anna", in: text)
        XCTAssertTrue(renamed.contains("- **Anna**: ships on Friday; Speaker 21 does not."))
        XCTAssertTrue(renamed.contains("[00:00:05] Anna: Sure"))
    }

    func testAnthropicRequestAndAnswer() throws {
        let request = try SummaryClient.request(provider: .anthropic, baseURL: "https://api.anthropic.com/v1/", key: "k",
                                                model: "claude-opus-5-5", system: "S", transcript: "T")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "S")
        XCTAssertEqual(body["fallbacks"] as? String, "default")

        let answer = try SummaryClient.parse(provider: .anthropic, status: 200, data: Data("""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Sum"},{"type":"text","text":"mary"}],
         "stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":2}}
        """.utf8))
        XCTAssertEqual(answer.text, "Summary")
        XCTAssertFalse(answer.truncated)
        XCTAssertThrowsError(try SummaryClient.parse(provider: .anthropic, status: 200, data: Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)))
        XCTAssertThrowsError(try SummaryClient.parse(provider: .anthropic, status: 401,
                                                     data: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))) {
            XCTAssertTrue($0.localizedDescription.contains("invalid x-api-key"))
        }
    }

    func testOpenAICompatibleRequestAndAnswer() throws {
        let local = try SummaryClient.request(provider: .local, baseURL: "http://localhost:11434/v1", key: nil,
                                              model: "llama3", system: "S", transcript: "T")
        XCTAssertEqual(local.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        let openRouter = try SummaryClient.request(provider: .openrouter, baseURL: SummaryProvider.openrouter.defaultBaseURL,
                                                   key: "k", model: "openrouter/auto", system: "S", transcript: "T")
        XCTAssertEqual(openRouter.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: openRouter.httpBody!) as? [String: Any])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }, ["system", "user"])

        let answer = try SummaryClient.parse(provider: .openai, status: 200, data: Data("""
        {"choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"length"}]}
        """.utf8))
        XCTAssertEqual(answer.text, "Hello")
        XCTAssertTrue(answer.truncated)
    }

    func testModelListsHaveReadableNames() throws {
        let anthropic = try SummaryClient.parseModels(provider: .anthropic, status: 200, data: Data("""
        {"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}]}
        """.utf8))
        XCTAssertEqual(anthropic.map(\.name), ["Claude Opus 5.5", "Claude Haiku 5.5"])
        let openAI = try SummaryClient.parseModels(provider: .openai, status: 200, data: Data("""
        {"data":[{"id":"text-embedding-3-large"},{"id":"gpt-5"},{"id":"gpt-5-mini"},{"id":"whisper-1"}]}
        """.utf8))
        XCTAssertEqual(openAI.map(\.id), ["gpt-5-mini", "gpt-5"])
        XCTAssertThrowsError(try SummaryClient.parseModels(provider: .openai, status: 401, data: Data(#"{"error":{"message":"bad key"}}"#.utf8)))
    }

    func testUsageLineAndPrices() throws {
        XCTAssertEqual(try XCTUnwrap(SummaryPricing.anthropicCost(model: "claude-opus-5-5", input: 1_000_000, output: 100_000)), 6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SummaryPricing.anthropicCost(model: "claude-opus-4-5-20251101", input: 1_000_000, output: 0)), 5, accuracy: 1e-9)
        XCTAssertNil(SummaryPricing.anthropicCost(model: "claude-unknown", input: 1, output: 1))
        XCTAssertEqual(SummaryUsage.money(0.07312), "$0.073")
        XCTAssertEqual(SummaryUsage.money(12.346), "$12.35")
        XCTAssertEqual(APIKeyStore.masked("sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ-xyz9"), "sk-ant-api03…xyz9")

        let usage = SummaryUsage(date: Date(), appVersion: "0.16.0", provider: "anthropic", model: "claude-opus-5-5",
                                 modelName: "Claude Opus 5.5", inputTokens: 14230, outputTokens: 812, costUSD: 0.07316)
        let text = SummaryText.inserting("Short.", into: transcript, heading: "Суммаризация", transcriptHeading: "Транскрипт", meta: usage.metaLine)
        XCTAssertTrue(text.contains("## Суммаризация\n\n> MeetRec 0.16.0 · Claude Opus 5.5 (claude-opus-5-5) · "))
        XCTAssertTrue(text.contains("$0.073\n\nShort.\n\n## Транскрипт"))
        XCTAssertEqual(TranscriptPreview.parse(text).lines.map(\.text), ["Short."])
        XCTAssertEqual(TranscriptPreview.parse(text).engine, "Parakeet Ultra")
        // A rerun replaces the meta line with the summary.
        let again = SummaryText.inserting("Again.", into: text, heading: "Суммаризация", transcriptHeading: "Транскрипт", meta: "x")
        XCTAssertFalse(again.contains("MeetRec 0.16.0"))
    }

    func testOpenRouterReportsCost() throws {
        let answer = try SummaryClient.parse(provider: .openrouter, status: 200, data: Data("""
        {"model":"anthropic/claude-sonnet-5.5","choices":[{"message":{"content":"Hi"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":1000,"completion_tokens":50,"cost":0.0025}}
        """.utf8))
        XCTAssertEqual(answer.model, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(answer.inputTokens, 1000)
        XCTAssertEqual(answer.reportedCost, 0.0025)
    }
}
