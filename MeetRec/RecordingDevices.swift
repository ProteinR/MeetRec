import Foundation
import CoreGraphics

/// What can be recorded and with what: displays, microphones, the output resolution.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
}

struct MicrophoneInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case native, p1440, p1080, p720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return String(localized: "Как у монитора")
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}
