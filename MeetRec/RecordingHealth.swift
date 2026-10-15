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
    /// Seconds since the microphone / system audio last had speech-level sound.
    var micSilentFor: TimeInterval = 0
    var systemSilentFor: TimeInterval = 0

    var hasProblem: Bool {
        [microphone, systemAudio, screen, file].contains { $0.state == .noSignal }
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

    let startedAt: Date
    let microphoneOn: Bool
    let systemAudioOn: Bool
    let microphoneName: String
    /// What the screen row names: the display, or the window recorded on its own.
    var displayName: String

    private var micDB = HealthTracker.floorDB
    private var systemDB = HealthTracker.floorDB
    private var lastLoudMic: Date
    private var lastLoudSystem: Date
    private var lastFrameCount = 0
    private var lastFrameCountAt: Date
    private var fps: Double = 0

    init(startedAt: Date, microphoneOn: Bool, systemAudioOn: Bool, microphoneName: String, displayName: String) {
        self.startedAt = startedAt
        self.microphoneOn = microphoneOn
        self.systemAudioOn = systemAudioOn
        self.microphoneName = microphoneName
        self.displayName = displayName
        self.lastLoudMic = startedAt
        self.lastLoudSystem = startedAt
        self.lastFrameCountAt = startedAt
    }

    /// - Parameter micMuted: the input is muted at the system level (keyboard mute key); silence is then
    ///   intentional, and the "quiet" timer restarts when it is unmuted.
    /// - Parameter freeSpace: bytes free on the recordings volume, shown in the file row.
    mutating func update(with status: LiveStatus, micMuted: Bool = false, freeSpace: Int64? = nil,
                         now: Date = Date()) -> RecordingHealth {
        let running = now.timeIntervalSince(startedAt)

        let micPeak = Self.decibels(status.micPeak)
        micDB = Self.smooth(current: micDB, new: micPeak)
        if micPeak > Self.speechThresholdDB || micMuted { lastLoudMic = now }
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
            micDetail = "\(microphoneName) — тихо \(Int(now.timeIntervalSince(lastLoudMic))) с"
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

        let fileSize = status.fileURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }
            .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"

        var fileDetail = "\(fileSize) · \(status.fileURL?.lastPathComponent ?? "")"
        var fileState = SignalState.ok
        if let freeSpace {
            fileDetail = "\(fileSize) · свободно \(DiskSpace.format(freeSpace))"
            if freeSpace < DiskSpace.warnBelow {
                fileState = .noSignal
                fileDetail = "\(fileSize) · мало места: \(DiskSpace.format(freeSpace))"
            }
        }

        return RecordingHealth(
            microphone: SignalHealth(title: "Микрофон", detail: micDetail, levelDB: microphoneOn ? micDB : nil, state: micState),
            systemAudio: SignalHealth(title: "Звук системы", detail: systemDetail, levelDB: systemAudioOn ? systemDB : nil, state: systemState),
            screen: SignalHealth(title: "Экран", detail: screenDetail, levelDB: nil, state: screenState),
            file: SignalHealth(title: "Файл", detail: fileDetail, levelDB: nil, state: fileState),
            micSilentFor: now.timeIntervalSince(lastLoudMic),
            systemSilentFor: now.timeIntervalSince(lastLoudSystem)
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
