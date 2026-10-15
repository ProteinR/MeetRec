import AppKit
import SwiftUI

/// Relaunches MeetRec if it crashes, and tells the app on the next launch that a recording was cut.
///
/// - While MeetRec runs, a `running` flag file exists; a normal quit removes it.
/// - A small launchd agent (`~/Library/LaunchAgents/com.dmemruk.MeetRec.watchdog.plist`) checks every
///   10 s: flag present but no MeetRec process → MeetRec crashed → `open` it again.
/// - While recording, `recording.json` names the file. If it is still there on launch, the previous
///   run died mid-recording: the file (fragmented, so readable) is reported and the recording resumes.
@MainActor
enum Watchdog {
    static let label = "com.dmemruk.MeetRec.watchdog"
    static let checkInterval = 10

    /// What the previous run was recording when it died.
    struct InterruptedRecording: Codable {
        var file: String
        var autoAppID: String?
        var startedAt: Date
    }

    private static var stateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec", isDirectory: true)
    }
    private static var runningFlag: URL { stateDir.appendingPathComponent("running") }
    private static var recordingState: URL { stateDir.appendingPathComponent("recording.json") }
    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Call once at launch. Returns the recording the previous run was writing if it crashed.
    static func appLaunched(enabled: Bool) -> InterruptedRecording? {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: runningFlag.path) {
            Log.warning("Previous MeetRec run did not quit normally (crash, force quit or kill)")
        }
        var interrupted: InterruptedRecording?
        if let data = try? Data(contentsOf: recordingState) {
            interrupted = try? JSONDecoder().decode(InterruptedRecording.self, from: data)
            try? FileManager.default.removeItem(at: recordingState)
        }
        FileManager.default.createFile(atPath: runningFlag.path, contents: Data("\(getpid())".utf8))
        setAgent(enabled: enabled)
        return interrupted
    }

    /// Normal quit: no relaunch.
    static func appWillTerminate() {
        try? FileManager.default.removeItem(at: runningFlag)
        try? FileManager.default.removeItem(at: recordingState)
    }

    static func recordingStarted(file: URL, autoAppID: String?) {
        let state = InterruptedRecording(file: file.path, autoAppID: autoAppID, startedAt: Date())
        do {
            try JSONEncoder().encode(state).write(to: recordingState, options: .atomic)
        } catch {
            Log.warning("Could not save recording state: \(Log.describe(error))")
        }
    }

    static func recordingStopped() {
        try? FileManager.default.removeItem(at: recordingState)
    }

    /// Installs (or removes) the launchd agent that relaunches MeetRec after a crash.
    static func setAgent(enabled: Bool) {
        let uid = getuid()
        if !enabled {
            guard FileManager.default.fileExists(atPath: agentPlist.path) else { return }
            launchctl(["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(at: agentPlist)
            Log.info("Crash watchdog removed")
            return
        }
        let app = Bundle.main.bundleURL.path
        let log = Log.fileURL.path
        // Paths are single-quoted for sh; none of them contain a single quote.
        let script = "[ -f '\(runningFlag.path)' ] && ! /usr/bin/pgrep -qx MeetRec && "
            + "{ echo \"$(date '+%Y-%m-%d %H:%M:%S.000') WARN  [watchdog] MeetRec is not running, relaunching\" >> '\(log)'; "
            + "/usr/bin/open '\(app)'; }; exit 0"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", script],
            "StartInterval": checkInterval,
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: agentPlist)) == data, launchctl(["print", "gui/\(uid)/\(label)"], quiet: true) == 0 {
            return // already installed and loaded
        }
        do {
            try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: agentPlist, options: .atomic)
        } catch {
            Log.error("Could not write watchdog agent: \(Log.describe(error))")
            return
        }
        launchctl(["bootout", "gui/\(uid)/\(label)"], quiet: true)
        let status = launchctl(["bootstrap", "gui/\(uid)", agentPlist.path])
        Log.info("Crash watchdog \(status == 0 ? "installed" : "failed to load (launchctl \(status))"): \(agentPlist.path)")
    }

    @discardableResult
    private static func launchctl(_ arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if !quiet { Log.warning("launchctl \(arguments.joined(separator: " ")) failed: \(Log.describe(error))") }
            return -1
        }
        return process.terminationStatus
    }
}
