import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overview = Overview()
    private let missionControl = NativeMissionControl()
    private let swipe = SwipeGesture()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var showItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey { [weak self] in self?.overview.toggle() }

        let settings = Settings.shared
        settings.$hotKey.combineLatest(settings.$isRecordingHotKey).sink { [weak self] spec, recording in
            if recording { self?.hotKey?.unregister() } else { self?.hotKey?.register(spec) }
            self?.showItem?.title = "Window Overview  \(spec.label)"
        }.store(in: &subscriptions)
        swipe.onSwipeUp = { [weak self] in self?.overview.show() }
        swipe.onSwipeDown = { [weak self] in self?.overview.dismiss() }
        swipe.claimsSwipeDown = { [weak self] in self?.overview.isVisible ?? false }
        swipe.systemOwnsGestures = { [weak self] in self?.missionControl.isActive ?? false }
        settings.$swipeOpensOverview.sink { [weak self] on in
            if on { self?.swipe.start() } else { self?.swipe.stop() }
        }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.overview.settingsChanged() }
        }.store(in: &subscriptions)

        setUpStatusItem()
        setUpEditMenu()
        missionControl.start()

        if !Permissions.accessibility || !Permissions.screenRecording {
            showPreferences()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Mission Plus")

        let menu = NSMenu()
        let show = NSMenuItem(title: "Window Overview  \(Settings.shared.hotKey.label)", action: #selector(showOverview), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        showItem = show
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mission Plus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// An accessory app shows no menu bar, but its main menu still supplies key equivalents.
    /// Without an Edit menu, ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z do nothing in text fields.
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem()) // the app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func showOverview() {
        // Let the menu finish closing first, so the overview can take focus.
        DispatchQueue.main.async { self.overview.show() }
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Mission Plus Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = window
        }
        NSApp.activate()
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
