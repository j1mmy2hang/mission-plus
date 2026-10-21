import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Private but long-stable API that maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One window on the current Space.
final class WindowItem {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// Frame in Cocoa global coordinates (origin bottom-left of the primary screen).
    let frame: CGRect
    let icon: NSImage?
    let ax: AXUIElement?
    var thumbnail: CGImage?

    init(id: CGWindowID, pid: pid_t, appName: String, title: String, frame: CGRect, icon: NSImage?, ax: AXUIElement?) {
        self.id = id; self.pid = pid; self.appName = appName; self.title = title
        self.frame = frame; self.icon = icon; self.ax = ax
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var displayTitle: String { title.isEmpty ? appName : title }
}

enum Windows {
    /// Windows visible on the current Space, front to back.
    static func current() -> [WindowItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return items(from: list)
    }

    /// The window with this CGWindowID, if it belongs to a regular app.
    static func item(withID id: CGWindowID) -> WindowItem? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return items(from: list).first
    }

    private static func items(from list: [[String: Any]]) -> [WindowItem] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var items: [WindowItem] = []

        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 60, bounds.height >= 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }

            if axCache[pid] == nil { axCache[pid] = axWindows(pid: pid) }
            // CGWindowList also reports helper surfaces; keeping only windows the app exposes via AX filters them out.
            guard let ax = axCache[pid]?[id] else { continue }

            let title = (info[kCGWindowName as String] as? String) ?? axString(ax, kAXTitleAttribute) ?? ""
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            items.append(WindowItem(id: id, pid: pid, appName: app.localizedName ?? "", title: title,
                                    frame: frame, icon: app.icon, ax: ax))
        }
        return items
    }

    private static func axWindows(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        var map: [CGWindowID: AXUIElement] = [:]
        for w in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success { map[id] = w }
        }
        return map
    }

    static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return value as? String
    }

    // MARK: Actions

    static func focus(_ item: WindowItem) {
        guard let app = item.app else { return }
        if let ax = item.ax {
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    static func close(_ item: WindowItem) {
        guard let ax = item.ax else { return }
        var button: AnyObject?
        if AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    static func minimize(_ item: WindowItem) {
        guard let ax = item.ax else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func toggleFullScreen(_ item: WindowItem) {
        guard let ax = item.ax else { return }
        var value: AnyObject?
        AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &value)
        let isFull = (value as? Bool) ?? false
        AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, (!isFull) as CFBoolean)
    }

    static func hide(_ item: WindowItem) { item.app?.hide() }
    static func quit(_ item: WindowItem) { item.app?.terminate() }

    // MARK: Thumbnails

    /// Captures each window's contents. Calls `update` on the main thread as each image arrives.
    static func captureThumbnails(for items: [WindowItem], maxSide: CGFloat, update: @escaping (CGWindowID, CGImage) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return }
        let wanted = Set(items.map(\.id))
        Task.detached(priority: .userInitiated) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            await withTaskGroup(of: Void.self) { group in
                for window in content.windows where wanted.contains(window.windowID) {
                    group.addTask {
                        let config = SCStreamConfiguration()
                        let scale = min(1, maxSide / max(window.frame.width, window.frame.height)) * 2
                        config.width = max(1, Int(window.frame.width * scale))
                        config.height = max(1, Int(window.frame.height * scale))
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            let id = window.windowID
                            await MainActor.run { update(id, image) }
                        }
                    }
                }
            }
        }
    }
}
