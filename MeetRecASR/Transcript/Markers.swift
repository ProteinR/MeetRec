// Markers, pauses and microphone mutes saved during a recording, as lines of the transcript.
import Foundation

/// RecorderModel.pauseNote: where a paused recording was joined up.
let pauseNote = "Пауза"

struct TranscriptMarker: Equatable {
    enum Kind: Equatable {
        /// The user's own marker, or one with a note ("Пауза").
        case note(String?)
        /// The microphone muted until `end` (nil: still muted when the file ended).
        case mute(end: Double?)
    }

    var time: Double
    var kind: Kind
}

/// A file of the recording: `name` in its own folder (`<stem>/<stem>.mov`), or `<stem>.<name>`
/// next to a recording of the older flat layout (RecordingFiles.companion in MeetRec).
func companion(_ recording: URL, _ name: String) -> URL {
    let stem = recording.deletingPathExtension().lastPathComponent
    let folder = recording.deletingLastPathComponent()
    if folder.lastPathComponent == stem { return folder.appendingPathComponent(name) }
    return folder.appendingPathComponent("\(stem).\(name)")
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func readList(_ url: URL, _ what: String) -> [[String: Any]]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    guard let data = try? Data(contentsOf: url),
          let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        log("Ignoring unreadable \(what) file \(url.path)")
        return nil
    }
    return list
}

/// Moments marked during recording (`markers.json` of the recording), sorted by time; note
/// "Пауза" for a cut pause and nil for the user's own markers.
func loadMarkers(_ recording: URL) -> [TranscriptMarker] {
    let url = companion(recording, "markers.json")
    guard let list = readList(url, "markers") else { return [] }
    var markers: [TranscriptMarker] = []
    for item in list {
        guard let time = number(item["time"]) else {
            log("Ignoring unreadable markers file \(url.path)")
            return []
        }
        markers.append(TranscriptMarker(time: time, kind: .note(item["note"] as? String)))
    }
    return stableSorted(markers) { $0.time < $1.time }
}

/// Mutes closer than this are one ("mute, say a word, mute again").
let muteJoin = 10.0
/// Shorter mutes (a cough) are left out.
let muteMin = 5.0

/// When the microphone was muted (`mutes.json` of the recording, seconds of the file), joined when
/// close together (not over the user's `speech` times) and without the short ones.
func loadMutes(_ recording: URL, total: Double? = nil, speech: [Double] = []) -> [TranscriptMarker] {
    let url = companion(recording, "mutes.json")
    guard let list = readList(url, "mutes") else { return [] }
    var spans: [(Double, Double?)] = []
    for item in list {
        guard let start = number(item["start"]) else {
            log("Ignoring unreadable mutes file \(url.path)")
            return []
        }
        spans.append((start, number(item["end"]) ?? total))
    }
    spans = stableSorted(spans) { $0.0 < $1.0 }
    return mergeMutes(spans, speech: speech).map { TranscriptMarker(time: $0.0, kind: .mute(end: $0.1)) }
}

/// (start, end) spans joined over gaps shorter than `join` in which the user did not speak (unmuted
/// for a moment to say "Okay"), then those shorter than `shortest` dropped; an end of nil (still
/// muted when the file ended) is kept as is.
func mergeMutes(_ spans: [(Double, Double?)], join: Double = muteJoin, shortest: Double = muteMin,
                speech: [Double] = []) -> [(Double, Double?)] {
    var merged: [(Double, Double?)] = []
    for (start, end) in spans {
        if let last = merged.last, let lastEnd = last.1, start - lastEnd < join,
           !speech.contains(where: { lastEnd <= $0 && $0 <= start }) {
            merged[merged.count - 1].1 = end.map { max($0, lastEnd) }
        } else {
            merged.append((start, end))
        }
    }
    return merged.filter { $0.1 == nil || $0.1! - $0.0 >= shortest }
}

/// "⭐ [00:12:34] Отметка", "⏸ [00:12:34] Пауза" or "🔇 [00:12:34–00:13:10] Микрофон выключен".
func markerLine(_ marker: TranscriptMarker) -> String {
    switch marker.kind {
    case .mute(let end):
        let until = end.map { "–\(formatTime($0))" } ?? ""
        return "🔇 [\(formatTime(marker.time))\(until)] \(tr("Микрофон выключен", "Microphone muted"))"
    case .note(pauseNote):
        return "⏸ [\(formatTime(marker.time))] \(tr(pauseNote, "Pause"))"
    case .note:
        return "⭐ [\(formatTime(marker.time))] \(tr("Отметка", "TranscriptMarker"))"
    }
}

/// Puts a marker line before the first line that starts at or after each marker.
func insertMarkers(_ lines: [(start: Double, text: String)], _ markers: [TranscriptMarker]) -> [String] {
    var pending = stableSorted(markers) { $0.time < $1.time }[...]
    var result: [String] = []
    for line in lines {
        while let first = pending.first, first.time <= line.start {
            result.append(markerLine(first))
            pending = pending.dropFirst()
        }
        result.append(line.text)
    }
    result += pending.map(markerLine)
    return result
}

/// Sorted, equal elements kept in their order (as Python's `sorted`).
func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
        less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset)
    }.map(\.element)
}
