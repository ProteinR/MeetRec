import AppKit
import ServiceManagement
import SwiftUI

/// Relaunches MeetRec if it crashes, and tells the app on the next launch that a recording was cut.
///
/// - While MeetRec runs, a `running` flag file exists (pid, then the app's path); a normal quit
///   removes it.
/// - A small launchd agent checks every 10 s: flag present but no MeetRec process → MeetRec crashed →
///   `open` it again. Its plist is inside the app (`Contents/Library/LaunchAgents`, from
///   `LaunchAgents/` in the repository) and registered with `SMAppService.agent`, so Login Items
///   lists it under MeetRec; a plist written to `~/Library/LaunchAgents` showed up as an unknown "sh".
/// - While recording, `recording.json` names the file. If it is still there on launch, the previous
///   run died mid-recording: the file (fragmented, so readable) is reported and the recording resumes.
@MainActor
enum Watchdog {
    /// Not the old agent's label: with the same one, SMAppService took the old agent for its own and
    /// reported it as enabled, so the bundled one was never registered.
    static let label = "com.dmemruk.MeetRec.crashwatchdog"
    private static let legacyLabel = "com.dmemruk.MeetRec.watchdog"
    private static let agent = SMAppService.agent(plistName: "\(label).plist")

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
    /// Where versions before 0.9.1 wrote the agent themselves; removed on launch.
    private static var legacyAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
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
        // The agent reads the second line to reopen exactly this copy.
        FileManager.default.createFile(atPath: runningFlag.path,
                                       contents: Data("\(getpid())\n\(Bundle.main.bundleURL.path)\n".utf8))
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

    /// Registers (or unregisters) the launchd agent that relaunches MeetRec after a crash.
    static func setAgent(enabled: Bool) {
        removeLegacyAgent()
        do {
            if enabled {
                guard agent.status != .enabled else { return }
                try agent.register()
            } else {
                guard agent.status != .notRegistered else { return }
                try agent.unregister()
            }
            Log.info("Crash watchdog \(enabled ? "registered" : "unregistered"): \(describe(agent.status))")
        } catch {
            Log.error("Crash watchdog \(enabled ? "register" : "unregister") failed: \(Log.describe(error)); "
                + "status \(describe(agent.status))")
        }
    }

    /// Unloads and removes the agent older versions wrote to `~/Library/LaunchAgents`.
    private static func removeLegacyAgent() {
        guard FileManager.default.fileExists(atPath: legacyAgentPlist.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(legacyLabel)"], quiet: true)
        try? FileManager.default.removeItem(at: legacyAgentPlist)
        Log.info("Crash watchdog: removed the old agent \(legacyAgentPlist.path)")
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings → Login Items"
        case .notFound: "not found (plist missing from the app)"
        @unknown default: "unknown (\(status.rawValue))"
        }
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
