import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon's RegisterEventHotKey (needs no permissions).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            me.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ choice: HotKeyChoice) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x4D504C53), id: 1) // 'MPLS'
        RegisterEventHotKey(choice.keyCode, choice.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
