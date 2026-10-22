import AppKit

/// Takes over the trackpad's Mission Control swipe (three or four fingers up) to open the overview instead.
///
/// The system delivers that swipe as a "dock control" event (CGEventType 30) whose fields describe it:
/// 110 = HID event type (23 = dock swipe), 123 = motion (1 horizontal, 2 vertical),
/// 132 = phase (1 began, 2 changed, 4 ended, 8 cancelled), 124 = progress (negative = upward).
/// Swallowing every event of a gesture, from its first, keeps Mission Control from starting at all.
final class SwipeGesture {
    private static let dockControlType: UInt32 = 30
    private enum Field {
        static let hidType = CGEventField(rawValue: 110)!
        static let motion = CGEventField(rawValue: 123)!
        static let progress = CGEventField(rawValue: 124)!
        static let phase = CGEventField(rawValue: 132)!
    }

    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?
    /// When true, swipes down are taken too (to close the overview); otherwise they go to the system.
    var claimsSwipeDown: () -> Bool = { false }
    /// When true (native Mission Control is open), every swipe goes to the system so it can close normally.
    var systemOwnsGestures: () -> Bool = { false }

    private var tap: CFMachPort?
    /// Whether the vertical gesture in progress is being swallowed.
    private var swallowing = false

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << Self.dockControlType,
            callback: { _, type, event, refcon in
                let me = Unmanaged<SwipeGesture>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        swallowing = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.dockControlType,
              event.getIntegerValueField(Field.hidType) == 23,
              event.getIntegerValueField(Field.motion) == 2 // vertical; Space swipes pass untouched
        else { return Unmanaged.passUnretained(event) }

        let phase = event.getIntegerValueField(Field.phase)
        if phase == 1 {
            // Decide once, at the start, so the system never sees half a gesture.
            let progress = event.getDoubleValueField(Field.progress)
            swallowing = false
            if !systemOwnsGestures() {
                if progress < 0 {
                    swallowing = true
                    DispatchQueue.main.async { self.onSwipeUp?() }
                } else if progress > 0, claimsSwipeDown() {
                    swallowing = true
                    DispatchQueue.main.async { self.onSwipeDown?() }
                }
            }
        }
        let swallow = swallowing
        if phase == 4 || phase == 8 { swallowing = false }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
