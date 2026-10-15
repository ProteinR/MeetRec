import Foundation
import os

/// Detailed logging to two places:
/// - `~/Library/Logs/MeetRec/meetrec.log` (plain text, rotated at 5 MB, kept as `meetrec.1.log`),
///   easy to read, attach or `tail -f`;
/// - the unified system log, subsystem `com.dmemruk.MeetRec`
///   (`log stream --predicate 'subsystem == "com.dmemruk.MeetRec"'`).
enum Log {
    enum Level: String {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"
    }

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MeetRec", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meetrec.log")
    }()

    private static let maxFileSize = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.dmemruk.MeetRec.log")
    private static let osLog = Logger(subsystem: "com.dmemruk.MeetRec", category: "app")
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func debug(_ message: @autoclosure () -> String, _ category: String = "app") { write(.debug, message(), category) }
    static func info(_ message: @autoclosure () -> String, _ category: String = "app") { write(.info, message(), category) }
    static func warning(_ message: @autoclosure () -> String, _ category: String = "app") { write(.warning, message(), category) }
    static func error(_ message: @autoclosure () -> String, _ category: String = "app") { write(.error, message(), category) }

    /// Describes an error with its domain, code and underlying errors; `localizedDescription` alone
    /// often hides the useful part.
    static func describe(_ error: Error?) -> String {
        guard let error else { return "nil" }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let reason = ns.localizedFailureReason { text += " | reason: \(reason)" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            text += " | underlying: \(describe(underlying))"
        }
        return text
    }

    private static func write(_ level: Level, _ message: String, _ category: String) {
        let date = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        switch level {
        case .debug: osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: osLog.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        queue.async {
            let line = "\(timestamp.string(from: date)) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(category)] (\(thread)) \(message)\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        let path = fileURL.path
        if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > maxFileSize {
            let rotated = fileURL.deletingLastPathComponent().appendingPathComponent("meetrec.1.log")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: fileURL, to: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            manager.createFile(atPath: path, contents: data)
        }
    }
}
