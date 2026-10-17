import AVFoundation
import CoreGraphics

/// Live signal information for the "recording status" panel. Peaks are linear (0…1) and are reset
/// each time a snapshot is taken, so they hold the loudest moment since the previous UI tick.
struct LiveStatus {
    var micPeak: Float = 0
    var systemPeak: Float = 0
    var lastMicBuffer: Date?
    var lastSystemBuffer: Date?
    /// Any screen sample, including "idle" ones: proves the stream is alive even on a static screen.
    var lastScreenSample: Date?
    var videoFrames = 0
    var width = 0
    var height = 0
    var fileURL: URL?
    /// When the first video frame started the file: marker times are counted from here.
    var sessionStartedAt: Date?
    /// Brightest sampled luma (0…255) of the latest checked frame; nil before the first check.
    var frameMaxLuma: Int?
}

/// A window that can be recorded instead of the whole display.
struct CaptureWindow: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    let bundleID: String

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

struct RecordingOptions {
    var displayID: CGDirectDisplayID
    var fps: Int
    /// Output height limit in pixels; nil keeps the display's native resolution.
    var maxHeight: Int?
    var codec: AVVideoCodecType
    var systemAudio: Bool
    var microphone: Bool
    /// `AVCaptureDevice.uniqueID`; nil uses the system default microphone.
    var microphoneID: String?
    var outputURL: URL
    /// Record only this window from the first frame (chosen in the panel); nil = the whole display.
    var windowID: CGWindowID? = nil
}

enum RecorderError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case notRecording
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Монитор не найден"
        case .windowNotFound: return "Окно не найдено — возможно, оно закрыто"
        case .notRecording: return "Запись не идёт"
        case .writer(let message): return "Не удалось начать запись: \(message)"
        }
    }
}
