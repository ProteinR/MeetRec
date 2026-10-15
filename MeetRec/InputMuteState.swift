import CoreAudio
import Foundation

/// Whether an input device is muted at the system level: the mute flag set by a keyboard mic-mute key
/// (or Control Center), or input volume pulled to zero. ScreenCaptureKit then delivers pure silence,
/// which is intentional and must not be reported as a broken microphone.
enum InputMuteState {
    /// `uid` is the CoreAudio device UID (= `AVCaptureDevice.uniqueID`); nil means the default input.
    static func isMuted(uid: String?) -> Bool {
        guard let device = deviceID(uid: uid) else { return false }
        var mute: UInt32 = 0
        if read(device, kAudioDevicePropertyMute, &mute), mute != 0 { return true }
        var volume: Float32 = 1
        if read(device, kAudioDevicePropertyVolumeScalar, &volume), volume < 0.01 { return true }
        return false
    }

    private static func deviceID(uid: String?) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = AudioDeviceID(kAudioObjectUnknown)
        if let uid, !uid.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var cfUID = uid as CFString
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
                AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
            }
            if status == noErr, device != kAudioObjectUnknown { return device }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func read<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }
}
