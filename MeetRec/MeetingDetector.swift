import AppKit
import CoreAudio
import Foundation

/// A calling app MeetRec knows about. Detection is generic (the app holds the microphone), but each
/// app is enabled only after it has been checked for false positives.
struct MeetingApp: Identifiable, Hashable {
    let id: String
    let name: String
    /// Matched as prefixes of CoreAudio process bundle IDs, so helper processes count too
    /// (Teams captures audio from `com.microsoft.teams2.helper` / `.modulehost`).
    let bundlePrefixes: [String]
    let supported: Bool
    /// Why an app is not supported yet.
    var note: String?

    static let all: [MeetingApp] = [
        MeetingApp(id: "teams", name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"], supported: true),
        MeetingApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom.xos"], supported: false, note: "скоро"),
        MeetingApp(id: "telegram", name: "Telegram", bundlePrefixes: ["ru.keepcoder.Telegram", "org.telegram.desktop"], supported: false,
                   note: "скоро: держит микрофон и для голосовых сообщений"),
        MeetingApp(id: "slack", name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"], supported: false, note: "скоро"),
        MeetingApp(id: "webex", name: "Webex", bundlePrefixes: ["Cisco-Systems.Spark"], supported: false, note: "скоро"),
        MeetingApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime"], supported: false, note: "скоро"),
        MeetingApp(id: "discord", name: "Discord", bundlePrefixes: ["com.hnc.Discord"], supported: false, note: "скоро"),
    ]

    /// The main bundle ID, used to check whether the app is installed.
    var mainBundleID: String { bundlePrefixes[0] }

    var isInstalled: Bool {
        bundlePrefixes.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    func matches(_ bundleID: String) -> Bool {
        bundlePrefixes.contains { bundleID.hasPrefix($0) }
    }
}

/// Watches which processes are capturing from a microphone (CoreAudio process objects, macOS 14.4+;
/// no extra permission) and reports meeting start/end for the enabled apps.
///
/// - start: an enabled app has held the microphone for `startAfter` seconds;
/// - end: it has released it for `endAfter` seconds. Muting inside Teams keeps the mic open, so a
///   muted participant does not end the meeting.
@MainActor
final class MeetingDetector {
    static let startAfter: TimeInterval = 5
    static let endAfter: TimeInterval = 15
    private static let pollInterval: TimeInterval = 1

    var onMeetingStarted: ((MeetingApp) -> Void)?
    var onMeetingEnded: ((MeetingApp) -> Void)?
    /// Human-readable current state for the UI, e.g. "Teams держит микрофон 3 с".
    var onStatus: ((String?) -> Void)?

    private var enabledApps: [MeetingApp] = []
    private var timer: Timer?
    private var activeApp: MeetingApp?
    private var activeSince: Date?
    private var inactiveSince: Date?
    private var meetingApp: MeetingApp?
    private var lastHolders: Set<String> = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    var isRunning: Bool { timer != nil }
    /// The app whose meeting is going on now (held the microphone long enough), if any.
    var currentMeeting: MeetingApp? { meetingApp }

    func start(apps: [MeetingApp]) {
        enabledApps = apps
        guard !apps.isEmpty else {
            stop()
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            Log.info("Meeting detection on for: \(apps.map(\.name).joined(separator: ", "))", "meetings")
        }
        poll()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        activeApp = nil
        activeSince = nil
        inactiveSince = nil
        meetingApp = nil
        onStatus?(nil)
        Log.info("Meeting detection off", "meetings")
    }

    // MARK: - Private

    private func poll() {
        let holders = Self.microphoneHolders(excluding: ownPID)
        if holders != lastHolders {
            Log.info("Microphone holders: \(holders.isEmpty ? "none" : holders.sorted().joined(separator: ", "))", "meetings")
            lastHolders = holders
        }
        let now = Date()
        let holding = enabledApps.first { app in holders.contains(where: app.matches) }

        if let holding {
            inactiveSince = nil
            if activeApp != holding {
                activeApp = holding
                activeSince = now
                Log.info("\(holding.name) took the microphone", "meetings")
            }
            let held = now.timeIntervalSince(activeSince ?? now)
            if meetingApp == nil {
                if held >= Self.startAfter {
                    meetingApp = holding
                    Log.info("Meeting started in \(holding.name) (mic held \(Int(held)) s)", "meetings")
                    onMeetingStarted?(holding)
                } else {
                    onStatus?("\(Self.shortName(holding)) взял микрофон · \(Int(held)) с")
                }
            }
            if meetingApp != nil {
                onStatus?("Идёт встреча в \(Self.shortName(meetingApp!))")
            }
        } else {
            if let app = activeApp {
                Log.info("\(app.name) released the microphone", "meetings")
                activeApp = nil
                activeSince = nil
            }
            if let meeting = meetingApp {
                if inactiveSince == nil { inactiveSince = now }
                let released = now.timeIntervalSince(inactiveSince!)
                if released >= Self.endAfter {
                    Log.info("Meeting ended in \(meeting.name) (mic released \(Int(released)) s)", "meetings")
                    meetingApp = nil
                    inactiveSince = nil
                    onMeetingEnded?(meeting)
                    onStatus?("Жду встречу")
                } else {
                    onStatus?("\(Self.shortName(meeting)) отпустил микрофон · стоп через \(Int(Self.endAfter - released)) с")
                }
            } else {
                onStatus?("Жду встречу")
            }
        }
    }

    private static func shortName(_ app: MeetingApp) -> String {
        app.id == "teams" ? "Teams" : app.name
    }

    /// Bundle IDs of processes currently capturing audio input, from CoreAudio's process objects.
    static func microphoneHolders(excluding ownPID: pid_t) -> Set<String> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var result = Set<String>()
        for object in objects {
            var running: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            var pid: pid_t = 0
            if read(object, kAudioProcessPropertyPID, &pid), pid == ownPID { continue }
            if let bundle = bundleID(object), !bundle.isEmpty {
                result.insert(bundle)
            } else {
                result.insert("pid:\(pid)")
            }
        }
        return result
    }

    /// The property returns a +1 CFString; take ownership so it is released.
    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
