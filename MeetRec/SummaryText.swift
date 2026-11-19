import Foundation

/// The summary section of a transcript file, as plain text functions (tested without a network).
///
/// A summary is written into the transcript itself, right under its header, so the tip, Quick Look
/// and the copy in a meetings folder all show it first:
///
///     # Transcription: …
///     - Date: …
///
///     ## Резюме
///
///     <summary>
///
///     ## Транскрипт
///
///     [00:00:01] Dima: …
enum SummaryText {
    /// Titles that make a level-2 heading the summary (also written by hand or by other tools).
    static let summaryTitles = ["резюме", "summary", "meeting summary", "краткое содержание", "итоги"]
    /// Titles of the heading put before the spoken lines when a summary is added.
    static let transcriptTitles = ["транскрипт", "transcript", "transcription"]

    /// The title of a level-2 heading ("## Резюме" → "резюме"); nil for any other line, "###" included.
    static func level2Title(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { return nil }
        return trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func hasSummary(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { level2Title($0).map(summaryTitles.contains) ?? false }
    }

    /// The text without its summary section (to send it again, or to replace it).
    static func removingSummary(_ text: String) -> String {
        var kept: [String] = []
        var inSummary = false
        for line in text.components(separatedBy: "\n") {
            if let title = level2Title(line) {
                inSummary = summaryTitles.contains(title)
                if inSummary { continue }
            } else if line.hasPrefix("# ") {
                inSummary = false
            }
            if !inSummary { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// The summary only ("## Резюме" up to the next level-2 heading), without its heading.
    static func summary(of text: String) -> String? {
        var lines: [String] = []
        var inSummary = false
        for line in text.components(separatedBy: "\n") {
            if let title = level2Title(line) {
                if inSummary { break }
                inSummary = summaryTitles.contains(title)
                continue
            }
            if inSummary { lines.append(line) }
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Puts `summary` under the file's header ("# …" and "- …" lines), replacing an earlier summary,
    /// and a transcript heading before the spoken lines unless one is there already.
    /// `meta` (app version, model, tokens, price) goes under the heading as a quote line.
    static func inserting(_ summary: String, into text: String, heading: String, transcriptHeading: String,
                          meta: String? = nil) -> String {
        let lines = removingSummary(text).components(separatedBy: "\n")
        var headerEnd = 0
        while headerEnd < lines.count {
            let line = lines[headerEnd]
            guard line.hasPrefix("# ") || line.hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            headerEnd += 1
        }
        var header = Array(lines[..<headerEnd])
        while header.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { header.removeLast() }
        let rest = Array(lines[headerEnd...])
        let hasTranscriptHeading = rest.first.flatMap(level2Title).map(transcriptTitles.contains) ?? false

        var result = header
        if !result.isEmpty { result.append("") }
        result += ["## \(heading)", ""]
        if let meta, !meta.isEmpty { result += ["> \(meta)", ""] }
        result += [summary.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if !hasTranscriptHeading && !rest.isEmpty { result += ["## \(transcriptHeading)", ""] }
        result += rest
        var joined = result.joined(separator: "\n")
        if !joined.hasSuffix("\n") { joined += "\n" }
        return joined
    }

    /// Spoken words in the transcript (lines "[hh:mm:ss] Name: text"), to skip summarising a test.
    static func spokenWords(_ text: String) -> Int {
        TranscriptPreview.parse(removingSummary(text)).words
    }

    /// A model's answer cleaned up: no code fence around it, no top heading of its own.
    static func cleaned(_ answer: String) -> String {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        }
        // "# Summary" / "## Резюме" at the top would end the section early or repeat its heading.
        while let first = lines.first, first.hasPrefix("# ") || level2Title(first) != nil
                || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        // Level-2 headings inside would end the section in the file: one level down.
        return lines.map { level2Title($0) != nil ? "#" + $0.trimmingCharacters(in: .whitespaces) : $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
