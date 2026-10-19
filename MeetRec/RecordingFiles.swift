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

    /// A cut pause (`RecorderModel.pauseNote`), not a moment the user marked.
    var isPause: Bool { note == RecorderModel.pauseNote }
    /// "⭐ 12:34" or "⏸ 12:34".
    var label: String { "\(isPause ? "⏸" : "⭐") \(timeText)" }

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
    /// Timestamp MeetRec (and OBS) put into file names. It always comes first, so Finder sorts
    /// recordings by time; a title follows it: "2026-10-16 14-03-22 Weekly sync".
    static let timestampPattern = #"\d{4}-\d{2}-\d{2} \d{2}-\d{2}(-\d{2})?"#

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Splits "2026-10-16 14-03-22 Weekly sync" into ("Weekly sync", "2026-10-16 14-03-22"). Also
    /// understands the older "Weekly sync 2026-10-16 14-03-22".
    static func split(_ stem: String) -> (title: String, timestamp: String?) {
        if let range = stem.range(of: "^" + timestampPattern + "( |$)", options: .regularExpression) {
            let timestamp = String(stem[range]).trimmingCharacters(in: .whitespaces)
            return (String(stem[range.upperBound...]).trimmingCharacters(in: .whitespaces), timestamp)
        }
        if let range = stem.range(of: " " + timestampPattern + "$", options: .regularExpression) {
            let timestamp = String(stem[range]).trimmingCharacters(in: .whitespaces)
            return (String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), timestamp)
        }
        return (stem, nil)
    }

    /// "2026-10-16 14-03-22" + "Weekly sync" → "2026-10-16 14-03-22 Weekly sync".
    static func stem(timestamp: String?, title: String) -> String {
        [timestamp, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
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
        // Voice prints of the recording's speakers are kept by recording name (see SpeakerNaming).
        let oldRun = SpeakerNaming.runsDir.appendingPathComponent(oldStem + ".json")
        if FileManager.default.fileExists(atPath: oldRun.path) {
            try? FileManager.default.moveItem(at: oldRun, to: SpeakerNaming.runsDir.appendingPathComponent(newStem + ".json"))
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
        try? FileManager.default.removeItem(at: SpeakerNaming.runURL(for: recording))
        Log.info("Moved to Trash: \(recording.lastPathComponent) (+\(companions.count) related files)", "files")
    }
}

/// Marks a video file as a meeting auto-recording (`com.dmemruk.MeetRec.meetingApp = teams`), set
/// when recording starts. Transcription may run much later (queue, retry, "again"), so the origin must
/// live on the file; an extended attribute survives renames and moving to the Trash.
enum RecordingTag {
    static let attribute = "com.dmemruk.MeetRec.meetingApp"
    /// Id of the browser rule ("Vimbox" → Skyeng) that started the recording.
    static let ruleAttribute = "com.dmemruk.MeetRec.rule"

    static func setMeetingApp(_ appID: String, on url: URL) {
        if write(appID, attribute, url) {
            Log.info("Tagged \(url.lastPathComponent) as \(appID) meeting", "files")
        }
    }

    static func setRule(_ ruleID: String, on url: URL) {
        if write(ruleID, ruleAttribute, url) {
            Log.info("Tagged \(url.lastPathComponent) with browser rule \(ruleID)", "files")
        }
    }

    /// `MeetingApp.id` of the meeting that started the recording; nil for manual recordings.
    static func meetingApp(of url: URL) -> String? { read(attribute, url) }

    static func rule(of url: URL) -> String? { read(ruleAttribute, url) }

    private static func write(_ value: String, _ name: String, _ url: URL) -> Bool {
        let data = Array(value.utf8)
        guard setxattr(url.path, name, data, data.count, 0, 0) == 0 else {
            Log.error("Could not set \(name)=\(value) on \(url.lastPathComponent): errno \(errno)", "files")
            return false
        }
        return true
    }

    private static func read(_ name: String, _ url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &data, size, 0, 0) == size else { return nil }
        return String(decoding: data, as: UTF8.self)
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

    /// Where the window is (global, origin top left), or nil when it is closed, minimised or hidden.
    static func frame(ofWindow windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }),
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return bounds
    }

    static func title(ofWindow windowID: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let title = list.first?[kCGWindowName as String] as? String else { return nil }
        let cleaned = clean(title)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A Teams meeting window and where it is (global screen coordinates, origin top left, like
    /// `CGDisplayBounds`).
    struct MeetingWindow {
        let windowID: CGWindowID
        let title: String
        let bounds: CGRect
        let onScreen: Bool
    }

    /// Open Teams meeting windows (not the main window with its Chat/Calendar sections).
    static func teamsMeetingWindows() -> [MeetingWindow] {
        let teams = MeetingApp.all.first { $0.id == "teams" }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundleIDs: [pid_t: String] = [:]
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 200, bounds.height >= 150 else { return nil }
            let processID = pid_t(pid)
            if bundleIDs[processID] == nil {
                bundleIDs[processID] = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? ""
            }
            guard teams?.matches(bundleIDs[processID] ?? "") == true else { return nil }
            let first = title.components(separatedBy: " | ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !first.isEmpty, !teamsSections.contains(first.lowercased()) else { return nil }
            return MeetingWindow(windowID: CGWindowID(number), title: clean(title), bounds: bounds,
                                 onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// Teams' own hidden windows, open even without a meeting ("Teams NRC" named recordings).
    private static let teamsHelperTitles: Set<String> = ["teams nrc"]

    /// The title of a Teams meeting window, if one is open: a real window (not a tiny or hidden
    /// helper), a visible one first; a minimised meeting window (screen sharing) still counts.
    static func teamsMeeting() -> String? {
        let windows = teamsMeetingWindows().filter { !$0.title.isEmpty && !teamsHelperTitles.contains($0.title.lowercased()) }
        return (windows.first(where: \.onScreen) ?? windows.first)?.title
    }

    /// All Teams windows for the log: title, size, visible — to tell meeting windows from helpers.
    static func describeTeamsWindows() -> String {
        let teams = MeetingApp.all.first { $0.id == "teams" }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "none" }
        let parts: [String] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  teams?.matches(NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? "") == true,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            return "\"\(title)\" \(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.minX)),\(Int(bounds.minY))\(onScreen ? " visible" : "")"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "; ")
    }

    /// A browser tab title without what a page changes on its own: the unread count "(13)", "•" and
    /// emoji such as 🔊. "(3) • Английский Skysmart 🔊 - Google Chrome" → "Английский Skysmart".
    static func tabKey(_ title: String) -> String {
        var text = title
        for suffix in appSuffixes {
            if let range = text.range(of: suffix) { text = String(text[..<range.lowerBound]) }
        }
        if let count = text.range(of: #"^\s*\(\d+\)"#, options: .regularExpression) { text.removeSubrange(count) }
        let kept = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
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
