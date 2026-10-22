import AppKit
import Carbon.HIToolbox

/// The system-wide hotkey that opens the overview.
///
/// Caught primarily in an event tap, which sees key presses before apps and the system's own shortcut
/// handling (a Carbon hotkey alone sometimes lost ⌃⌥↑ to Mission Control's ⌃↑). The Carbon hotkey stays
/// registered as a fallback for when the tap isn't available; a short debounce stops one press firing twice.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var spec: HotKeySpec?
    private var lastFired = Date.distantPast
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            me.fire()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ spec: HotKeySpec) {
        unregister()
        self.spec = spec
        let id = EventHotKeyID(signature: OSType(0x4D504C53), id: 1) // 'MPLS'
        RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        ensureTap()
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        spec = nil
    }

    private func fire() {
        guard Date().timeIntervalSince(lastFired) > 0.25 else { return }
        lastFired = Date()
        DispatchQueue.main.async { self.action() }
    }

    // MARK: Event tap

    private func ensureTap() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard AXIsProcessTrusted() else { return } // retried on the next register
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotKey>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let spec, type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(spec.keyCode),
              Self.carbonModifiers(of: event.flags) == spec.modifiers
        else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { fire() }
        return nil // swallow it, so neither the front app nor Mission Control sees it
    }

    private static func carbonModifiers(of flags: CGEventFlags) -> UInt32 {
        var mods = 0
        if flags.contains(.maskControl) { mods |= controlKey }
        if flags.contains(.maskAlternate) { mods |= optionKey }
        if flags.contains(.maskShift) { mods |= shiftKey }
        if flags.contains(.maskCommand) { mods |= cmdKey }
        return UInt32(mods)
    }
}
