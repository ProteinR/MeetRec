import Carbon

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility permission.
final class HotKey {
    private static let signature = OSType(0x4D52_4543) // "MREC"
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void
    /// `RegisterEventHotKey`'s result: not `noErr` when another app (or macOS) already owns the keys.
    private(set) var status: OSStatus = noErr
    var isRegistered: Bool { status == noErr && hotKeyRef != nil }

    /// - Parameters:
    ///   - keyCode: virtual key code, e.g. `kVK_ANSI_R`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | optionKey | controlKey`.
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Every hot key installs its own handler on the application target, so each handler must
        // check the pressed key's id and pass other keys on to the next handler.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
