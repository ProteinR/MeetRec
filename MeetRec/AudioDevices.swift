import AVFoundation
import CoreAudio
import Foundation

/// Which microphone is in use, from CoreAudio: the system default input and the input devices a
/// calling app is capturing from right now (process objects, macOS 14.4+, no permission needed).
/// UIDs are CoreAudio device UIDs, the same strings as `AVCaptureDevice.uniqueID` and
/// ScreenCaptureKit's `microphoneCaptureDeviceID`.
enum AudioDevices {
    static func defaultInputUID() -> String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        guard getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &device),
              device != kAudioObjectUnknown else { return nil }
        return uid(of: device)
    }

    /// Input devices the app (matched by bundle ID prefix) is capturing from, without loopbacks.
    static func inputsUsed(by app: MeetingApp) -> [String] {
        var uids: [String] = []
        for process in processObjects() {
            var running: UInt32 = 0
            guard getProperty(process, kAudioProcessPropertyIsRunningInput, &running), running != 0,
                  let bundle = stringProperty(process, kAudioProcessPropertyBundleID), app.matches(bundle) else { continue }
            // The device list must be asked for in the input scope; the global scope returns nothing.
            for device in deviceList(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) where hasInput(device) {
                if let uid = uid(of: device), !uid.hasPrefix("MSLoopbackDriverDevice"), !uids.contains(uid) {
                    uids.append(uid)
                }
            }
        }
        return uids
    }

    static func name(of uid: String?) -> String {
        guard let uid, !uid.isEmpty else { return AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "по умолчанию") }
        return AVCaptureDevice(uniqueID: uid)?.localizedName ?? uid
    }

    // MARK: - CoreAudio

    private static func processObjects() -> [AudioObjectID] {
        deviceList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    /// The property returns a +1 CFString; take ownership so it is released.
    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) == noErr
        }
    }
}
