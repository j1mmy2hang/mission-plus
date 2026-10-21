import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overview = Overview()
    private let missionControl = NativeMissionControl()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var showItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey { [weak self] in self?.overview.toggle() }

        let settings = Settings.shared
        settings.$hotKey.sink { [weak self] choice in
            self?.hotKey?.register(choice)
            self?.showItem?.title = "Window Overview  \(choice.label)"
        }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.overview.settingsChanged() }
        }.store(in: &subscriptions)

        setUpStatusItem()
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
