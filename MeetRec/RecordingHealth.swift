import Foundation

enum SignalState: Equatable {
    /// Signal arrives and is audible / frames arrive.
    case ok
    /// Buffers arrive but they are silent. Normal for system audio; worth a look for a microphone.
    case quiet
    /// Nothing arrives at all: wrong or disconnected device, revoked permission, stalled stream.
    case noSignal
    /// Source switched off in settings.
    case off
}

struct SignalHealth: Equatable {
    var title: String
    var detail: String
    /// Smoothed peak level in dBFS (-60…0); nil for sources without a level (screen, file).
    var levelDB: Float?
    var state: SignalState
}

struct RecordingHealth: Equatable {
    var microphone: SignalHealth
    var systemAudio: SignalHealth
    var screen: SignalHealth
    var file: SignalHealth
    /// Seconds since the microphone delivered any sound (dead silence), / system audio had speech.
    var micSilentFor: TimeInterval = 0
    var systemSilentFor: TimeInterval = 0
    /// Seconds the file has not grown although data should be arriving.
    var fileStalledFor: TimeInterval = 0
    /// Seconds the recorded picture has been completely black.
    var blackFor: TimeInterval = 0
    var diskLow = false

    var hasProblem: Bool {
        [microphone, systemAudio, screen, file].contains { $0.state == .noSignal }
    }
}

/// The fast-changing part of a recording (timer, level meters, CPU). Kept apart from `RecorderModel`
/// so only the views showing it redraw on every tick, not the whole panel with the recordings list.
@MainActor
final class LiveRecording: ObservableObject {
    /// Whole seconds, so the timer views redraw once a second.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var health: RecordingHealth?
    @Published private(set) var load: SystemLoad?

    var elapsedText: String {
        let total = Int(elapsed)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    func update(elapsed: TimeInterval) {
        let whole = elapsed.rounded(.down)
        if whole != self.elapsed { self.elapsed = whole }
    }

    func update(health: RecordingHealth?) {
        if health != self.health { self.health = health }
    }

    func update(load: SystemLoad?) {
        if load != self.load { self.load = load }
    }
}

/// Turns raw `LiveStatus` snapshots into what the UI shows. Called ~5 times a second while recording.
struct HealthTracker {
    static let floorDB: Float = -60
    /// No buffers for this long means the source is dead.
    static let noSignalAfter: TimeInterval = 2.5
    /// A microphone that stayed below the speech threshold this long is flagged as quiet.
    static let micQuietAfter: TimeInterval = 30
    static let speechThresholdDB: Float = -45
    static let silenceThresholdDB: Float = -55
    /// Below this the microphone delivers no sound at all, not even room noise: a wrong or broken
    /// device. Listening quietly in a meeting stays above it.
    static let deadSilenceDB: Float = -58
    /// Fragments are written every 5 s, so a healthy file grows at least that often.
    static let fileStalledAfter: TimeInterval = 30
    static let blackAfter: TimeInterval = 30
    /// 420v video range: black is 16; anything visible on screen is well above this.
    static let blackLuma = 24

    let startedAt: Date
    let microphoneOn: Bool
    let systemAudioOn: Bool
    /// The device being recorded; changes when the microphone is switched mid-recording.
    var microphoneName: String
    /// What the screen row names: the display, or the window recorded on its own.
    var displayName: String

    private var micDB = HealthTracker.floorDB
    private var systemDB = HealthTracker.floorDB
    private var lastLoudMic: Date
    private var lastLoudSystem: Date
    private var lastFrameCount = 0
    private var lastFrameCountAt: Date
    private var fps: Double = 0
    private var lastFileSize: Int64 = -1
    private var lastFileGrowth: Date
    private var blackSince: Date?

    init(startedAt: Date, microphoneOn: Bool, systemAudioOn: Bool, microphoneName: String, displayName: String) {
        self.startedAt = startedAt
        self.microphoneOn = microphoneOn
        self.systemAudioOn = systemAudioOn
        self.microphoneName = microphoneName
        self.displayName = displayName
        self.lastLoudMic = startedAt
        self.lastLoudSystem = startedAt
        self.lastFrameCountAt = startedAt
        self.lastFileGrowth = startedAt
    }

    /// - Parameter micMuted: the input is muted at the system level (keyboard mute key); silence is then
    ///   intentional, and the "quiet" timer restarts when it is unmuted.
    /// - Parameter freeSpace: bytes free on the recordings volume, shown in the file row.
    mutating func update(with status: LiveStatus, micMuted: Bool = false, freeSpace: Int64? = nil,
                         now: Date = Date()) -> RecordingHealth {
        let running = now.timeIntervalSince(startedAt)

        let micPeak = Self.decibels(status.micPeak)
        micDB = Self.smooth(current: micDB, new: micPeak)
        // "Loud" here means any real sound: only a dead-silent device is a problem, not listening.
        if micPeak > Self.deadSilenceDB || micMuted { lastLoudMic = now }
        let systemPeak = Self.decibels(status.systemPeak)
        systemDB = Self.smooth(current: systemDB, new: systemPeak)
        if systemPeak > Self.speechThresholdDB { lastLoudSystem = now }

        let elapsedSinceCount = now.timeIntervalSince(lastFrameCountAt)
        if elapsedSinceCount >= 1 {
            fps = Double(status.videoFrames - lastFrameCount) / elapsedSinceCount
            lastFrameCount = status.videoFrames
            lastFrameCountAt = now
        }

        // Microphone
        var micState: SignalState = .ok
        var micDetail = microphoneName
        if !microphoneOn {
            micState = .off
            micDetail = "выключен"
        } else if micMuted {
            micState = .quiet
            micDetail = "\(microphoneName) — выключен кнопкой"
        } else if Self.isDead(status.lastMicBuffer, now: now, running: running) {
            micState = .noSignal
            micDetail = "\(microphoneName) — нет сигнала"
        } else if running > Self.micQuietAfter, now.timeIntervalSince(lastLoudMic) > Self.micQuietAfter {
            micState = .quiet
            micDetail = "\(microphoneName) — полная тишина \(Int(now.timeIntervalSince(lastLoudMic))) с"
        }

        // System audio: silence is normal (nothing playing), so it is never a problem by itself.
        var systemState: SignalState = .ok
        var systemDetail = "идёт"
        if !systemAudioOn {
            systemState = .off
            systemDetail = "выключен"
        } else if Self.isDead(status.lastSystemBuffer, now: now, running: running) {
            systemState = .noSignal
            systemDetail = "нет сигнала"
        } else if systemDB <= Self.silenceThresholdDB {
            systemState = .quiet
            systemDetail = "тишина"
        }

        // Screen: idle samples count as alive, a static screen is fine.
        var screenState: SignalState = .ok
        var screenDetail = "\(displayName) · \(status.width)×\(status.height) · \(Int(fps.rounded())) к/с"
        if Self.isDead(status.lastScreenSample, now: now, running: running) {
            screenState = .noSignal
            screenDetail = "\(displayName) — кадры не приходят"
        }

        let bytes = status.fileURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }
        let fileSize = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        if let bytes, bytes != lastFileSize {
            lastFileSize = bytes
            lastFileGrowth = now
        }
        // Audio buffers arrive even in silence, so with any audio track the file must keep growing.
        // Video-only recordings of a static screen legitimately stand still.
        let expectsGrowth = status.fileURL != nil
            && ((microphoneOn && status.lastMicBuffer != nil) || (systemAudioOn && status.lastSystemBuffer != nil))
        let stalledFor = expectsGrowth ? now.timeIntervalSince(lastFileGrowth) : 0

        if let luma = status.frameMaxLuma, luma <= Self.blackLuma {
            if blackSince == nil { blackSince = now }
        } else {
            blackSince = nil
        }
        let blackFor = blackSince.map { now.timeIntervalSince($0) } ?? 0
        if screenState == .ok, blackFor >= Self.blackAfter {
            screenState = .quiet
            screenDetail = "\(displayName) — чёрный экран \(Int(blackFor)) с"
        }

        var fileDetail = "\(fileSize) · \(status.fileURL?.lastPathComponent ?? "")"
        var fileState = SignalState.ok
        let diskLow = freeSpace.map { $0 < DiskSpace.warnBelow } ?? false
        if let freeSpace {
            fileDetail = "\(fileSize) · свободно \(DiskSpace.format(freeSpace))"
            if diskLow {
                fileState = .noSignal
                fileDetail = "\(fileSize) · мало места: \(DiskSpace.format(freeSpace))"
            }
        }
        if stalledFor >= Self.fileStalledAfter {
            fileState = .noSignal
            fileDetail = "\(fileSize) — файл не растёт \(Int(stalledFor)) с"
        }

        return RecordingHealth(
            microphone: SignalHealth(title: "Микрофон", detail: micDetail, levelDB: microphoneOn ? micDB : nil, state: micState),
            systemAudio: SignalHealth(title: "Звук системы", detail: systemDetail, levelDB: systemAudioOn ? systemDB : nil, state: systemState),
            screen: SignalHealth(title: "Экран", detail: screenDetail, levelDB: nil, state: screenState),
            file: SignalHealth(title: "Файл", detail: fileDetail, levelDB: nil, state: fileState),
            micSilentFor: now.timeIntervalSince(lastLoudMic),
            systemSilentFor: now.timeIntervalSince(lastLoudSystem),
            fileStalledFor: stalledFor,
            blackFor: blackFor,
            diskLow: diskLow
        )
    }

    private static func isDead(_ last: Date?, now: Date, running: TimeInterval) -> Bool {
        guard let last else { return running > noSignalAfter + 1 }
        return now.timeIntervalSince(last) > noSignalAfter
    }

    private static func decibels(_ peak: Float) -> Float {
        guard peak > 0 else { return floorDB }
        return max(20 * log10(peak), floorDB)
    }

    /// Instant attack, slow release, like a hardware level meter.
    private static func smooth(current: Float, new: Float) -> Float {
        new >= current ? new : max(new, current - 3)
    }
}
