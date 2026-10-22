import AppKit
import ApplicationServices

/// One window thumbnail inside the system's Mission Control.
private struct Thumb {
    let wid: CGWindowID
    /// Global coordinates with the origin at the top-left of the primary screen (AX / CoreGraphics style).
    let frame: CGRect
    let element: AXUIElement
}

/// Adds close/minimize buttons and keyboard shortcuts to the real Mission Control.
///
/// On macOS 26+ Mission Control is drawn by WindowManager.app, which exposes it to Accessibility as
/// an `mc.display` group whose AXButtons are the thumbnails; each carries a `wid` attribute (the CGWindowID).
final class NativeMissionControl {
    private var wmElement: AXUIElement?
    private var wmPid: pid_t = 0
    private var timer: Timer?
    private var tap: CFMachPort?

    private(set) var isActive = false
    private var thumbs: [Thumb] = []
    private var hovered: Thumb?
    private var overlays: [ButtonOverlay] = []
    /// Button pressed with the mouse and waiting for mouse-up.
    private var pendingButton: TrafficLights.Kind?

    private let settings = Settings.shared

    func start() {
        guard timer == nil else { return }
        schedule(interval: 0.12)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        setActive(false)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Reading Mission Control

    private func windowManager() -> AXUIElement? {
        if let wmElement, NSRunningApplication(processIdentifier: wmPid)?.isTerminated == false { return wmElement }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return nil }
        wmPid = app.processIdentifier
        wmElement = AXUIElementCreateApplication(wmPid)
        AXUIElementSetMessagingTimeout(wmElement!, 0.25)
        return wmElement
    }

    private func readThumbs() -> [Thumb]? {
        guard let wm = windowManager() else { return nil }
        let displays = children(of: wm).filter { string($0, "AXIdentifier") == "mc.display" }
        guard !displays.isEmpty else { return nil }
        var result: [Thumb] = []
        for display in displays {
            for button in children(of: display) {
                var value: AnyObject?
                guard AXUIElementCopyAttributeValue(button, "wid" as CFString, &value) == .success,
                      let wid = (value as? NSNumber)?.uint32Value,
                      let frame = frame(of: button), frame.width > 4 else { continue }
                result.append(Thumb(wid: wid, frame: frame, element: button))
            }
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success, let value else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(value as! AXValue, .cgRect, &rect)
        return rect
    }

    // MARK: State

    private func poll() {
        guard AXIsProcessTrusted() else {
            setActive(false)
            return
        }
        ensureTap()
        if let found = readThumbs() {
            thumbs = found
            setActive(true)
            updateHover()
        } else {
            setActive(false)
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        pendingButton = nil
        if active {
            overlays = NSScreen.screens.map { ButtonOverlay(screen: $0) }
            overlays.forEach { $0.orderFrontRegardless() }
            schedule(interval: 1.0 / 60) // track thumbnails smoothly while Mission Control animates
        } else {
            overlays.forEach { $0.orderOut(nil) }
            overlays = []
            thumbs = []
            hovered = nil
            if timer != nil { schedule(interval: 0.12) }
        }
    }

    /// The mouse location in top-left-origin global coordinates.
    private var mouse: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func updateHover() {
        let p = mouse
        // Keep the current thumbnail while the pointer is on its buttons, which stick out past the corner.
        if let current = hovered, let fresh = thumbs.first(where: { $0.wid == current.wid }),
           fresh.frame.insetBy(dx: -16, dy: -16).contains(p),
           !thumbs.contains(where: { $0.wid != fresh.wid && $0.frame.contains(p) }) {
            hovered = fresh
        } else {
            hovered = thumbs.first { $0.frame.contains(p) }
        }
        refreshLights(pointer: p)
    }

    /// Pushes the hovered thumbnail and the pointer's position over the lights to the overlays.
    private func refreshLights(pointer p: CGPoint) {
        guard let thumb = hovered else {
            overlays.forEach { $0.hideLights() }
            return
        }
        let pill = pillRect(for: thumb)
        let over = TrafficLights.Kind.allCases.first { buttonRect($0, for: thumb).contains(p) }
        for overlay in overlays {
            overlay.showLights(at: pill, for: thumb.wid, hovered: over, groupHovered: pill.contains(p), pressed: pendingButton)
        }
    }

    /// The glass capsule's rect for a thumbnail, in top-left-origin global coordinates.
    private func pillRect(for thumb: Thumb) -> CGRect {
        CGRect(x: thumb.frame.minX - TrafficLights.cornerOffset, y: thumb.frame.minY - TrafficLights.cornerOffset,
               width: TrafficLights.size.width, height: TrafficLights.size.height)
    }

    private func buttonRect(_ kind: TrafficLights.Kind, for thumb: Thumb) -> CGRect {
        TrafficLights.hitRect(kind).offsetBy(dx: pillRect(for: thumb).minX, dy: pillRect(for: thumb).minY)
    }

    // MARK: Event tap

    private func ensureTap() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<NativeMissionControl>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isActive else { return Unmanaged.passUnretained(event) }
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .leftMouseDown:
            updateHover()
            guard let thumb = hovered else { return pass }
            for kind in TrafficLights.Kind.allCases where buttonRect(kind, for: thumb).contains(event.location) {
                pendingButton = kind
                refreshLights(pointer: event.location)
                return nil
            }
            return pass
        case .leftMouseUp:
            guard let kind = pendingButton else { return pass }
            pendingButton = nil
            // Releasing off the light cancels, like a real button.
            if let thumb = hovered, buttonRect(kind, for: thumb).contains(event.location) {
                perform(kind == .close ? .closeWindow : .minimizeWindow, on: thumb)
            } else {
                refreshLights(pointer: event.location)
            }
            return nil
        case .otherMouseDown:
            return hovered?.frame.contains(event.location) == true ? nil : pass
        case .otherMouseUp:
            // Middle-click closes, like a browser tab.
            guard let thumb = hovered, thumb.frame.contains(event.location) else { return pass }
            perform(.closeWindow, on: thumb)
            return nil
        case .keyDown:
            return handleKey(event) ? nil : pass
        default:
            return pass
        }
    }

    private func handleKey(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        updateHover()
        for shortcut in Shortcut.allCases where shortcut.matches(event) {
            guard settings.isEnabled(shortcut) else { return false } // disabled: let Mission Control have it
            perform(shortcut, on: hovered)
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        switch Int(event.keyCode) {
        case 123: return move(dx: -1, dy: 0)
        case 124: return move(dx: 1, dy: 0)
        case 125: return move(dx: 0, dy: 1)  // y grows downward here
        case 126: return move(dx: 0, dy: -1)
        case 36, 76: // Return / Enter opens the highlighted window
            guard let thumb = hovered else { return false }
            AXUIElementPerformAction(thumb.element, kAXPressAction as CFString)
            return true
        default:
            return false
        }
    }

    /// Arrow keys move the pointer onto the neighbouring thumbnail, so Mission Control's own highlight follows.
    private func move(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !thumbs.isEmpty else { return false }
        let target: Thumb?
        if let current = hovered {
            let origin = CGPoint(x: current.frame.midX, y: current.frame.midY)
            target = thumbs.filter { $0.wid != current.wid }.compactMap { t -> (Thumb, CGFloat)? in
                let vx = t.frame.midX - origin.x, vy = t.frame.midY - origin.y
                let along = vx * dx + vy * dy
                guard along > 1 else { return nil }
                return (t, along + abs(vx * dy - vy * dx) * 2)
            }.min { $0.1 < $1.1 }?.0
        } else {
            target = thumbs.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        }
        guard let target else { return true }
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        hovered = target
        refreshLights(pointer: point)
        return true
    }

    // MARK: Actions

    private func perform(_ shortcut: Shortcut, on thumb: Thumb?) {
        let all = thumbs.compactMap { Windows.item(withID: $0.wid) }
        let item = thumb.flatMap { Windows.item(withID: $0.wid) }
        switch shortcut {
        case .closeWindow: item.map(Windows.close)
        case .minimizeWindow: item.map(Windows.minimize)
        case .hideApp: item.map(Windows.hide)
        case .quitApp: item.map(Windows.quit)
        case .closeAll: all.forEach(Windows.close)
        case .minimizeAll: all.forEach(Windows.minimize)
        case .hideOthers:
            guard let item else { return }
            Set(all.map(\.pid)).subtracting([item.pid]).forEach { NSRunningApplication(processIdentifier: $0)?.hide() }
        case .fullScreen:
            guard let thumb, let item else { return }
            AXUIElementPerformAction(thumb.element, kAXPressAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Windows.toggleFullScreen(item) }
        }
        if [.closeWindow, .minimizeWindow, .hideApp, .quitApp].contains(shortcut) {
            hovered = nil
            overlays.forEach { $0.hideLights() }
        }
    }
}

/// A transparent, click-through window above Mission Control that draws the traffic lights.
private final class ButtonOverlay: NSWindow {
    private let lights = TrafficLights()
    private var shownFor: CGWindowID?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView = content
        content.addSubview(lights)
    }

    /// Places the lights at `pill` (top-left-origin global coordinates) and mirrors the pointer state.
    func showLights(at pill: CGRect, for wid: CGWindowID, hovered: TrafficLights.Kind?, groupHovered: Bool, pressed: TrafficLights.Kind?) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = NSRect(x: pill.minX, y: primaryHeight - pill.maxY, width: pill.width, height: pill.height)
        guard frame.contains(NSPoint(x: global.midX, y: global.midY)) else {
            hideLights()
            return
        }
        lights.frame = convertFromScreen(global)
        lights.hoveredKind = hovered
        lights.groupHovered = groupHovered
        lights.pressedKind = pressed
        if shownFor != wid {
            // Moving to another thumbnail: pop in afresh there rather than sliding across.
            if lights.isShown { lights.replayAppear() } else { lights.setShown(true) }
            shownFor = wid
        }
    }

    func hideLights() {
        shownFor = nil
        lights.setShown(false)
    }
}
