import AppKit

/// A borderless full-screen window that can take keyboard focus.
/// A non-activating panel: it takes keyboard focus at once, like Spotlight, without asking macOS to switch apps
/// (activation requests from a background app can be delayed or refused, which left the search field unfocused).
private final class OverviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Receives keyboard and mouse input for the overview and forwards it to the controller.
private final class OverviewInputView: NSView {
    weak var controller: Overview?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { controller?.dismiss() } // click on empty space
    // Typing while the search field isn't focused (e.g. after a click) goes to the field.
    override func keyDown(with event: NSEvent) { controller?.typeIntoSearch(event) }
    // Window shortcuts (⌘W, ⌘M…) arrive here before the Edit menu; anything else (⌘A, ⌘V…) falls through to it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleShortcut(event) == true { return true }
        // Text editing keys go straight to the search field, without relying on the app's Edit menu.
        if event.modifierFlags.intersection([.command, .option, .control]) == .command,
           let action = Self.editActions[event.charactersIgnoringModifiers ?? ""] {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let editActions: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
        "x": #selector(NSText.cut(_:)), "z": Selector(("undo:")), "Z": Selector(("redo:")),
    ]
}

/// The window overview: shows every window on the current Space and lets you act on them.
final class Overview {
    private var window: OverviewWindow?
    private var inputView: OverviewInputView?
    private var searchBar: SearchBar?
    private var emptyLabel: NSTextField?
    /// The blur, dim and search bar: faded on their own so thumbnails can stay opaque.
    private var backdrop: [NSView] = []

    private var items: [WindowItem] = []
    private var views: [CGWindowID: ThumbnailView] = [:]
    private var thumbnailCache: [CGWindowID: CGImage] = [:]
    /// Pixel width of the sharpest capture requested this session, per window (see `ensureResolution`).
    private var requestedWidth: [CGWindowID: CGFloat] = [:]
    /// Pixel width of the sharpest capture shown this session, so a slower, smaller capture can't replace it.
    private var shownWidth: [CGWindowID: Int] = [:]
    private var selectedID: CGWindowID?
    private var filter = "" { didSet { filterChanged() } }
    private var previousApp: NSRunningApplication?
    private var lastMouse: NSPoint?
    private var resignObserver: Any?
    private var isDismissing = false
    /// Windows just closed, minimized or hidden, and when. Apps can take a while to actually close a window,
    /// so a resync shouldn't bring these back until they've had time to go.
    private var recentlyRemoved: [CGWindowID: Date] = [:]
    private static let removalGrace: TimeInterval = 2

    private let settings = Settings.shared
    var isVisible: Bool { window != nil }

    // MARK: Show / dismiss

    func toggle() { isVisible ? dismiss() : show() }

    func show() {
        guard window == nil else { return }
        guard AXIsProcessTrusted() else {
            Permissions.requestAccessibility()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        requestedWidth = [:]
        shownWidth = [:]
        recentlyRemoved = [:]
        items = Windows.current()
        for item in items { item.thumbnail = thumbnailCache[item.id] }
        filter = ""
        selectedID = nil

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]

        let window = OverviewWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setFrame(screen.frame, display: false)

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root

        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)

        let dim = NSView(frame: root.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
        dim.autoresizingMask = [.width, .height]
        root.addSubview(dim)

        let input = OverviewInputView(frame: root.bounds)
        input.wantsLayer = true
        input.autoresizingMask = [.width, .height]
        input.controller = self
        root.addSubview(input)

        let searchBar = SearchBar()
        searchBar.onChange = { [weak self] text in self?.filter = text }
        searchBar.onCommand = { [weak self] selector in self?.handleCommand(selector) ?? false }
        input.addSubview(searchBar)
        let emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.font = .systemFont(ofSize: 20, weight: .medium)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.7)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        input.addSubview(emptyLabel)

        self.window = window
        self.inputView = input
        self.searchBar = searchBar
        self.emptyLabel = emptyLabel
        self.backdrop = [blur, dim, searchBar, emptyLabel]

        // Thumbnails start exactly where the real windows are, then fly into the grid.
        // Added back to front, so overlapping windows stack as they do on screen.
        for item in items.reversed() { addView(for: item, startingAt: window.convertFromScreen(item.frame)) }

        window.makeKeyAndOrderFront(nil)
        searchBar.focus()

        let local = window.convertPoint(fromScreen: mouse)
        relayout(animated: true)
        selectedID = item(atImagePoint: local, useTargets: true)?.id
        updateHighlight()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            window.animator().alphaValue = 1
        }


        // Clicking another app or switching with ⌘⇥ takes keyboard focus away: close. Right after opening,
        // though, focus can bounce away and back (e.g. the menu-bar menu closing), so take it back instead.
        let shownAt = Date()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(shownAt) < 0.6 {
                DispatchQueue.main.async {
                    window.makeKeyAndOrderFront(nil)
                    self.searchBar?.focus()
                }
            } else {
                self.dismiss(restoreFocus: false)
            }
        }
    }

    /// Closes the overview. Every thumbnail flies back onto its real window; with `focus`, that window
    /// lands on top and comes to the front.
    func dismiss(focus: WindowItem? = nil, restoreFocus: Bool = true) {
        guard let window, let stageHost = inputView?.layer, !isDismissing else { return }
        isDismissing = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil

        // Fly flat snapshots rather than the live views: plain layers are animated by the render server,
        // with no per-frame layout, so app activation on the main thread can't make them stutter.
        let stage = CALayer()
        stage.frame = stageHost.bounds
        var flights: [(layer: CALayer, from: CGRect, to: CGRect)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageHost.addSublayer(stage)
        let backToFront = items.reversed().filter { $0.id != focus?.id } + (focus.map { [$0] } ?? [])
        for item in backToFront {
            guard let view = views[item.id], targets[item.id] != nil else { continue }
            let layer = CALayer()
            if let thumbnail = item.thumbnail {
                layer.contents = thumbnail
                layer.contentsGravity = .resize
            } else {
                layer.contents = item.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                layer.contentsGravity = .center
                layer.backgroundColor = NSColor(white: 0.2, alpha: 0.85).cgColor
            }
            layer.masksToBounds = true
            let to = window.convertFromScreen(item.frame)
            // The model holds the final state; the explicit animations below supply the motion.
            layer.frame = to
            layer.cornerRadius = 12 // close to a real window's corners at the hand-off
            stage.addSublayer(layer)
            flights.append((layer, view.imageRectInSuperview, to))
            view.isHidden = true
        }
        CATransaction.commit()

        // Explicit animations: these layers were created in this same event, so they have never been on screen,
        // and Core Animation skips implicit animations for such layers (the snapshots would just jump into place).
        let duration: CFTimeInterval = 0.36
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
        for flight in flights {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: NSPoint(x: flight.from.midX, y: flight.from.midY))
            position.toValue = NSValue(point: NSPoint(x: flight.to.midX, y: flight.to.midY))
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = NSValue(rect: NSRect(origin: .zero, size: flight.from.size))
            bounds.toValue = NSValue(rect: NSRect(origin: .zero, size: flight.to.size))
            let corner = CABasicAnimation(keyPath: "cornerRadius")
            corner.fromValue = 10
            corner.toValue = 12
            let group = CAAnimationGroup()
            group.animations = [position, bounds, corner]
            group.duration = duration
            group.timingFunction = timing
            flight.layer.add(group, forKey: "flight")
        }
        // The blur shows the real windows through it, so keep it until the snapshots have nearly landed:
        // any ghost then sits where its snapshot is arriving.
        let fading = backdrop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.6) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration * 0.4
                for view in fading { view.animator().alphaValue = 0 }
            }
        }
        // Remove the overlay once the snapshots have landed on the real windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            window.orderOut(nil)
            guard let self else { return }
            self.window = nil
            self.inputView = nil
            self.views = [:]
            self.items = []
            self.backdrop = []
            self.isDismissing = false
        }

        // Raise the window now, under the overlay, so it is in front by the time its snapshot lands.
        if let focus {
            Windows.focus(focus)
        } else if restoreFocus, let previousApp, previousApp.processIdentifier != getpid(),
                  NSWorkspace.shared.frontmostApplication != previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
    }

    // MARK: Views and layout

    private func addView(for item: WindowItem, startingAt rect: CGRect) {
        let view = ThumbnailView(item: item, imageRect: rect)
        view.showsTitleAlways = settings.alwaysShowTitles
        view.onOpen = { [weak self] in self?.dismiss(focus: item) }
        view.onClose = { [weak self] in self?.perform(.closeWindow, on: item) }
        view.onMinimize = { [weak self] in self?.perform(.minimizeWindow, on: item) }
        inputView?.addSubview(view, positioned: .below, relativeTo: searchBar)
        views[item.id] = view
    }

    private var visibleItems: [WindowItem] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.appName.localizedCaseInsensitiveContains(filter) }
    }

    /// Target image rects for the currently visible items, in window coordinates.
    private var targets: [CGWindowID: CGRect] = [:]

    private func relayout(animated: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = visibleItems
        let searchGap: CGFloat = 24
        let topInset = searchGap * 2 + SearchBar.size.height
        let visibleFrame = window.convertFromScreen(screen.visibleFrame)
        let area = NSRect(x: visibleFrame.minX + 50, y: visibleFrame.minY + 40,
                          width: visibleFrame.width - 100, height: visibleFrame.height - 40 - topInset)
        let rects = Layout.arrange(visible.map(\.frame), in: area, spacing: 36, labelSpace: ThumbnailView.bottomInset)
        targets = Dictionary(uniqueKeysWithValues: zip(visible.map(\.id), rects))
        ensureResolution()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.3 : 0
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            for item in items {
                guard let view = views[item.id] else { continue }
                if let rect = targets[item.id] {
                    view.animator().frame = ThumbnailView.frame(forImageRect: rect)
                    view.animator().alphaValue = 1
                } else {
                    view.animator().alphaValue = 0
                }
            }
        }

        let bounds = inputView?.bounds ?? .zero
        if let searchBar {
            searchBar.frame.origin = NSPoint(x: (bounds.width - SearchBar.size.width) / 2,
                                             y: visibleFrame.maxY - searchGap - SearchBar.size.height)
            searchBar.setCount(matching: visible.count, total: items.count)
        }
        if let emptyLabel {
            emptyLabel.stringValue = filter.isEmpty ? "No open windows on this Space" : "No windows match “\(filter)”"
            emptyLabel.isHidden = !visible.isEmpty
            emptyLabel.sizeToFit()
            emptyLabel.setFrameOrigin(NSPoint(x: bounds.midX - emptyLabel.frame.width / 2, y: area.midY - emptyLabel.frame.height / 2))
        }
    }

    private func updateHighlight() {
        for (id, view) in views { view.isHighlighted = id == selectedID }
    }

    /// Captures each visible window at the size its thumbnail is drawn (never more than the window's own pixels),
    /// and again whenever a thumbnail grows well past its image, e.g. when a search leaves fewer, larger thumbnails.
    /// Cached images from earlier sessions only fill in until this session's capture arrives.
    private func ensureResolution() {
        guard let window, !isDismissing else { return }
        let scale = window.backingScaleFactor
        var sizes: [CGWindowID: CGSize] = [:]
        for item in visibleItems {
            guard let rect = targets[item.id] else { continue }
            let width = (min(rect.width, item.frame.width) * scale).rounded()
            // 15% headroom, so small layout shifts don't trigger recaptures.
            guard width > (requestedWidth[item.id] ?? 0) * 1.15 else { continue }
            requestedWidth[item.id] = width
            sizes[item.id] = CGSize(width: width, height: (width * item.frame.height / item.frame.width).rounded())
        }
        Windows.captureThumbnails(sizes: sizes) { [weak self] id, image in
            guard let self, image.width >= self.shownWidth[id] ?? 0 else { return }
            self.shownWidth[id] = image.width
            self.thumbnailCache[id] = image
            self.items.first { $0.id == id }?.thumbnail = image
            self.views[id]?.setThumbnail(image)
        }
    }

    /// Re-reads the window list after an action, so windows that refused to close (unsaved changes) come back.
    private func resync(after delay: TimeInterval = 0.45) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let window = self.window, !self.isDismissing else { return }
            let now = Date()
            self.recentlyRemoved = self.recentlyRemoved.filter { now.timeIntervalSince($0.value) < Self.removalGrace }
            let fresh = Windows.current().filter { self.recentlyRemoved[$0.id] == nil }
            let freshIDs = Set(fresh.map(\.id))
            for item in self.items where !freshIDs.contains(item.id) {
                self.views.removeValue(forKey: item.id)?.removeFromSuperview()
            }
            var added: [WindowItem] = []
            for item in fresh where self.views[item.id] == nil {
                item.thumbnail = self.thumbnailCache[item.id]
                self.addView(for: item, startingAt: window.convertFromScreen(item.frame))
                added.append(item)
            }
            self.items = fresh
            if let selectedID = self.selectedID, !freshIDs.contains(selectedID) { self.selectedID = nil }
            self.relayout(animated: true)
            self.updateHighlight()
        }
    }

    private func filterChanged() {
        guard window != nil else { return }
        relayout(animated: true)
        if let selectedID, targets[selectedID] != nil { return }
        selectedID = visibleItems.first?.id
        updateHighlight()
    }

    // MARK: Input

    private func item(atImagePoint point: NSPoint, useTargets: Bool = false) -> WindowItem? {
        visibleItems.first { item in
            let rect = useTargets ? targets[item.id] : views[item.id]?.imageRectInSuperview
            return rect?.insetBy(dx: -4, dy: -4).contains(point) ?? false
        }
    }

    func mouseMoved(to point: NSPoint) {
        // Ignore the synthetic move AppKit sends when the window appears; only real movement changes selection.
        if let lastMouse, hypot(lastMouse.x - point.x, lastMouse.y - point.y) < 1 { return }
        lastMouse = point
        let hovered = item(atImagePoint: point)?.id
        if hovered != selectedID {
            selectedID = hovered
            updateHighlight()
        }
    }

    private var selectedItem: WindowItem? { items.first { $0.id == selectedID } }

    /// Window shortcuts (⌘W, ⌘M…), from anywhere in the overview.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        for shortcut in Shortcut.allCases where shortcut.matches(event) {
            if settings.isEnabled(shortcut) { perform(shortcut, on: selectedItem) }
            return true
        }
        return false
    }

    /// Navigation keys typed in the search field. Arrows move between windows rather than the caret;
    /// word- and line-wise moves (⌥←, ⌘←) and shift-selection still edit the text.
    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): move(dx: -1, dy: 0)
        case #selector(NSResponder.moveRight(_:)): move(dx: 1, dy: 0)
        case #selector(NSResponder.moveUp(_:)): move(dx: 0, dy: 1)
        case #selector(NSResponder.moveDown(_:)): move(dx: 0, dy: -1)
        case #selector(NSResponder.insertTab(_:)): cycle(backwards: false)
        case #selector(NSResponder.insertBacktab(_:)): cycle(backwards: true)
        case #selector(NSResponder.insertNewline(_:)):
            if let item = selectedItem ?? visibleItems.first { dismiss(focus: item) }
        case #selector(NSResponder.cancelOperation(_:)):
            if filter.isEmpty { dismiss() } else { searchBar?.clear() }
        default:
            return false
        }
        return true
    }

    func typeIntoSearch(_ event: NSEvent) {
        guard let searchBar else { return }
        searchBar.focus()
        searchBar.field.currentEditor()?.keyDown(with: event)
    }

    private func cycle(backwards: Bool) {
        let visible = orderedVisible()
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID }
        let next = index.map { ($0 + (backwards ? -1 : 1) + visible.count) % visible.count } ?? 0
        selectedID = visible[next].id
        updateHighlight()
    }

    /// Visible items in reading order (top-to-bottom, left-to-right) of the grid.
    private func orderedVisible() -> [WindowItem] {
        visibleItems.sorted {
            let a = targets[$0.id] ?? .zero, b = targets[$1.id] ?? .zero
            return abs(a.midY - b.midY) > 10 ? a.midY > b.midY : a.midX < b.midX
        }
    }

    /// Arrow-key navigation: picks the nearest thumbnail in the pressed direction.
    private func move(dx: CGFloat, dy: CGFloat) {
        guard let current = selectedID.flatMap({ targets[$0] }) else {
            selectedID = orderedVisible().first?.id
            updateHighlight()
            return
        }
        let origin = CGPoint(x: current.midX, y: current.midY)
        var best: (id: CGWindowID, score: CGFloat)?
        for (id, rect) in targets where id != selectedID {
            let vx = rect.midX - origin.x, vy = rect.midY - origin.y
            let along = vx * dx + vy * dy
            guard along > 1 else { continue }
            let across = abs(vx * dy - vy * dx)
            let score = along + across * 2
            if best == nil || score < best!.score { best = (id, score) }
        }
        if let best {
            selectedID = best.id
            updateHighlight()
        }
    }

    // MARK: Actions

    func perform(_ shortcut: Shortcut, on item: WindowItem?) {
        switch shortcut {
        case .closeWindow:
            guard let item else { return }
            Windows.close(item); remove([item])
        case .minimizeWindow:
            guard let item else { return }
            Windows.minimize(item); remove([item])
        case .hideApp:
            guard let item else { return }
            Windows.hide(item); remove(items.filter { $0.pid == item.pid })
        case .quitApp:
            guard let item else { return }
            Windows.quit(item); remove(items.filter { $0.pid == item.pid })
        case .closeAll:
            let targets = visibleItems
            targets.forEach(Windows.close); remove(targets)
        case .minimizeAll:
            let targets = visibleItems
            targets.forEach(Windows.minimize); remove(targets)
        case .hideOthers:
            guard let item else { return }
            var hidden = Set<pid_t>()
            for other in items where other.pid != item.pid && hidden.insert(other.pid).inserted { Windows.hide(other) }
            remove(items.filter { $0.pid != item.pid })
        case .fullScreen:
            guard let item else { return }
            dismiss(focus: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Windows.toggleFullScreen(item) }
            return
        }
        resync()
        resync(after: Self.removalGrace + 0.1) // brings back windows that refused (e.g. a "Save changes?" sheet)
    }

    /// Removes windows from the overview right away, with a shrink-and-fade, then reflows the grid.
    private func remove(_ removed: [WindowItem]) {
        let ids = Set(removed.map(\.id))
        guard !ids.isEmpty else { return }
        for id in ids { recentlyRemoved[id] = Date() }
        let removedViews = ids.compactMap { views.removeValue(forKey: $0) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            for view in removedViews {
                view.animator().alphaValue = 0
                view.animator().frame = view.frame.insetBy(dx: view.frame.width * 0.1, dy: view.frame.height * 0.1)
            }
        }, completionHandler: {
            removedViews.forEach { $0.removeFromSuperview() }
        })

        // Move the highlight to the nearest remaining window so repeated ⌘W keeps working.
        let ordered = orderedVisible()
        let oldIndex = ordered.firstIndex { $0.id == selectedID } ?? 0
        items.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) {
            let remaining = ordered.filter { !ids.contains($0.id) }
            self.selectedID = remaining.isEmpty ? nil : remaining[min(oldIndex, remaining.count - 1)].id
        }
        relayout(animated: true)
        updateHighlight()
    }

    /// Applies changed preferences to an open overview.
    func settingsChanged() {
        for view in views.values {
            view.showsTitleAlways = settings.alwaysShowTitles
        }
    }
}
