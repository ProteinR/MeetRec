import Foundation

/// The start of a transcript for a recording's tip: the lines people said, without the file's
/// header ("# Transcription: …", "- Date: …"). Where the search query is found, the lines start
/// there. A summary section ("## Резюме", "## Summary": written by `Summarizer` or by hand) comes
/// first when the file has one.
struct TranscriptPreview: Equatable {
    struct Line: Equatable {
        /// "00:12:34"; nil for summary text and notes without a time.
        var time: String?
        var speaker: String?
        var text: String
    }

    var lines: [Line]
    var words: Int
    /// The lines are the file's summary, not what was said.
    var isSummary = false
    /// What transcribed it ("Parakeet Ultra + FluidAudio diarization"), from the file's header.
    var engine: String?

    /// Enough to fill the tip; the rest is cut off there anyway.
    static let maxLines = 14
    static var summaryTitles: [String] { SummaryText.summaryTitles }

    static func load(_ url: URL, query: String = "") -> TranscriptPreview? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, query: query)
    }

    static func parse(_ text: String, query: String = "") -> TranscriptPreview {
        let rows = text.components(separatedBy: .newlines)
        var spoken: [Line] = []
        var summary: [Line] = []
        var inSummary = false
        var words = 0
        var engine: String?
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            // The summary's own subheadings ("### Решения") stay in it, as plain lines.
            if inSummary && trimmed.hasPrefix("###") {
                summary.append(Line(text: trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inSummary = trimmed.hasPrefix("##") && summaryTitles.contains(title)
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if inSummary {
                // "> MeetRec 0.16.0 · model · tokens · price": not part of what the summary says.
                if trimmed.hasPrefix(">") { continue }
                let plain = trimmed.replacingOccurrences(of: "**", with: "")
                summary.append(Line(text: plain.hasPrefix("- ") ? "• " + plain.dropFirst(2) : plain))
                continue
            }
            // The header's "- Date: …", "- Engine: …".
            if trimmed.hasPrefix("- ") && spoken.isEmpty {
                if trimmed.hasPrefix("- Engine: ") { engine = String(trimmed.dropFirst("- Engine: ".count)) }
                continue
            }
            let line = parseLine(trimmed)
            if line.speaker != nil { words += line.text.split(whereSeparator: \.isWhitespace).count }
            spoken.append(line)
        }
        let query = query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, let hit = spoken.firstIndex(where: { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            return TranscriptPreview(lines: Array(spoken[hit...].prefix(maxLines)), words: words, engine: engine)
        }
        if !summary.isEmpty {
            return TranscriptPreview(lines: Array(summary.prefix(maxLines)), words: words, isSummary: true, engine: engine)
        }
        return TranscriptPreview(lines: Array(spoken.prefix(maxLines)), words: words, engine: engine)
    }

    /// "[00:12:34] Name: text" → time, speaker, text; anything else (markers, mutes) is text.
    static func parseLine(_ row: String) -> Line {
        guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { return Line(text: row) }
        let time = String(row[row.index(after: row.startIndex)..<close])
        guard time.allSatisfy({ $0.isNumber || $0 == ":" }) else { return Line(text: row) }
        let rest = row[row.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if let colon = rest.range(of: ": "), rest.distance(from: rest.startIndex, to: colon.lowerBound) <= 40 {
            return Line(time: time, speaker: String(rest[..<colon.lowerBound]), text: String(rest[colon.upperBound...]))
        }
        return Line(time: time, text: rest)
    }
}
