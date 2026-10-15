import AppKit
import Foundation

/// Free space on the recordings volume. A full disk is one of the few ways to lose a recording that
/// the fragmented file cannot protect against, so MeetRec refuses to start or stops in time.
enum DiskSpace {
    /// Below this a recording does not start.
    static let refuseStartBelow: Int64 = 1_000_000_000
    /// Below this the user is warned (at start and while recording).
    static let warnBelow: Int64 = 3_000_000_000
    /// Below this a running recording is stopped so the file is closed properly.
    static let stopBelow: Int64 = 500_000_000

    /// Bytes available for new files on the volume of `url` (what Finder shows, including space macOS
    /// can free by purging caches); nil if unknown.
    static func available(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A moment the user marked during a recording; `time` is seconds from the start of the file.
struct Marker: Codable, Equatable {
    var time: Double
    var note: String?

    var timeText: String {
        let total = Int(time)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Markers live next to the recording as `<name>.markers.json`, written on every new marker so they
/// survive a crash like the fragmented video does. `transcribe.py` puts them into the transcript.
enum MarkerFile {
    static func url(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("markers.json")
    }

    static func load(for recording: URL) -> [Marker] {
        guard let data = try? Data(contentsOf: url(for: recording)) else { return [] }
        return (try? JSONDecoder().decode([Marker].self, from: data)) ?? []
    }

    static func save(_ markers: [Marker], for recording: URL) throws {
        let data = try JSONEncoder().encode(markers)
        try data.write(to: url(for: recording), options: .atomic)
    }
}

/// Naming, renaming and deleting recordings together with their transcripts and markers.
enum RecordingFiles {
    /// Timestamp MeetRec (and OBS) put into file names; kept at the end of every name.
    static let timestampPattern = #"\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d{2})?"#

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Splits "Weekly sync 2026-10-16 14-03-22" into ("Weekly sync", "2026-10-16 14-03-22").
    static func split(_ stem: String) -> (title: String, timestamp: String?) {
        guard let range = stem.range(of: "(^| )" + timestampPattern + "$", options: .regularExpression) else {
            return (stem, nil)
        }
        let title = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let timestamp = String(stem[range]).trimmingCharacters(in: .whitespaces)
        return (title, timestamp)
    }

    /// Makes a meeting or window title safe and short enough for a file name.
    static func sanitize(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "[/:\\\\\\n\\r\\t]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if text.count > 80 {
            text = String(text.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Files that belong to a recording: transcripts (`name.md`, `name (2).md`…) and markers.
    static func companions(of recording: URL) -> [URL] {
        let folder = recording.deletingLastPathComponent()
        let stem = recording.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        return names.filter { name in
            guard name.hasPrefix(stem) else { return false }
            let rest = String(name.dropFirst(stem.count))
            if rest == ".md" || rest == ".markers.json" { return true }
            // "name (2).md" is a second transcript, unless "name (2)" is a separate recording.
            guard rest.range(of: #"^ \(\d+\)\.md$"#, options: .regularExpression) != nil else { return false }
            let otherStem = String(name.dropLast(3))
            return !names.contains(otherStem + ".mov") && !names.contains(otherStem + ".mp4")
        }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// Renames the recording and its companions to `newStem`; returns the new video URL.
    static func rename(_ recording: URL, to newStem: String) throws -> URL {
        let folder = recording.deletingLastPathComponent()
        let oldStem = recording.deletingPathExtension().lastPathComponent
        let target = folder.appendingPathComponent(newStem).appendingPathExtension(recording.pathExtension)
        guard newStem != oldStem else { return recording }
        if FileManager.default.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        let companions = companions(of: recording)
        try FileManager.default.moveItem(at: recording, to: target)
        for file in companions {
            let rest = String(file.lastPathComponent.dropFirst(oldStem.count))
            let destination = folder.appendingPathComponent(newStem + rest)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
            } catch {
                Log.warning("Could not rename \(file.lastPathComponent): \(Log.describe(error))", "files")
            }
        }
        Log.info("Renamed recording \"\(oldStem)\" → \"\(newStem)\" (+\(companions.count) related files)", "files")
        return target
    }

    /// A stem in `folder` that no `.mov` uses yet: "name", "name (2)"…
    static func uniqueStem(_ stem: String, in folder: URL, ext: String = "mov") -> String {
        var candidate = stem
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).appendingPathExtension(ext).path) {
            candidate = "\(stem) (\(index))"
            index += 1
        }
        return candidate
    }

    /// Moves the recording and its companions to the Trash (recoverable from there).
    static func trash(_ recording: URL) throws {
        let companions = companions(of: recording)
        try FileManager.default.trashItem(at: recording, resultingItemURL: nil)
        for file in companions {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        Log.info("Moved to Trash: \(recording.lastPathComponent) (+\(companions.count) related files)", "files")
    }
}

/// Finds a title for the recording: the window chosen for capture, or a running Teams meeting.
enum MeetingTitle {
    /// Teams main-window sections; a window titled like this is not a meeting.
    private static let teamsSections: Set<String> = [
        "chat", "calendar", "activity", "teams", "calls", "files", "apps", "onedrive", "microsoft teams",
        "search", "settings", "meet", "чат", "календарь", "действия", "команды", "звонки", "файлы", "приложения",
    ]
    private static let appSuffixes = [
        " | Microsoft Teams", " - Google Chrome", " — Google Chrome", " - Microsoft Edge", " — Microsoft Edge",
        " - Safari", " — Safari", " - Arc", " - Yandex", " — Яндекс Браузер",
    ]

    struct WindowTitle {
        let windowID: CGWindowID
        let bundleID: String
        let ownerName: String
        let title: String
    }

    /// Titles of all normal windows, including those on other Spaces (window titles need the Screen
    /// Recording permission, which MeetRec has).
    static func windows() -> [WindowTitle] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundleIDs: [pid_t: String] = [:]
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            let processID = pid_t(pid)
            if bundleIDs[processID] == nil {
                bundleIDs[processID] = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? ""
            }
            return WindowTitle(windowID: CGWindowID(number), bundleID: bundleIDs[processID] ?? "",
                               ownerName: info[kCGWindowOwnerName as String] as? String ?? "", title: title)
        }
    }

    static func exists(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }
    }

    static func title(ofWindow windowID: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let title = list.first?[kCGWindowName as String] as? String else { return nil }
        let cleaned = clean(title)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The title of a Teams meeting window, if one is open.
    static func teamsMeeting() -> String? {
        let teams = MeetingApp.all.first { $0.id == "teams" }
        for window in windows() where teams?.matches(window.bundleID) == true {
            let first = window.title.components(separatedBy: " | ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !first.isEmpty, !teamsSections.contains(first.lowercased()) else { continue }
            let cleaned = clean(window.title)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    static func clean(_ title: String) -> String {
        var text = title
        for suffix in appSuffixes {
            if let range = text.range(of: suffix) { text = String(text[..<range.lowerBound]) }
        }
        // Teams: "Weekly sync | Calendar" style leftovers.
        if let first = text.components(separatedBy: " | ").first { text = first }
        return RecordingFiles.sanitize(text)
    }
}
