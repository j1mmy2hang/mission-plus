import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Private but long-stable API that maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private but long-stable API that builds an AX element from a remote token; used to find windows on other Spaces,
/// which apps leave out of their AX window list.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Where a window is, if not on screen.
enum WindowPlace: Equatable {
    case here
    /// Numbered as in Mission Control: user desktops on the window's display, from 1.
    case otherDesktop(Int)
    case fullScreen
    case minimized
    case hidden

    var badge: String? {
        switch self {
        case .here, .otherDesktop: return nil
        case .fullScreen: return "F"
        case .minimized: return "M"
        case .hidden: return "H"
        }
    }

    var include: OverviewInclude? {
        switch self {
        case .here: return nil
        case .otherDesktop: return .otherDesktops
        case .fullScreen: return .fullScreen
        case .minimized: return .minimized
        case .hidden: return .hidden
        }
    }

    /// The overview's order for windows that aren't on screen.
    var sortKey: Int {
        switch self {
        case .here: return 0
        case .otherDesktop(let n): return n
        case .fullScreen: return 1_000
        case .minimized: return 1_001
        case .hidden: return 1_002
        }
    }
}

/// One window: on the current Space, or elsewhere when the overview is set to include it.
final class WindowItem {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// Frame in Cocoa global coordinates (origin bottom-left of the primary screen).
    let frame: CGRect
    let icon: NSImage?
    /// Nil for windows on other Spaces until an action needs it (see `Windows.element(for:)`).
    var ax: AXUIElement?
    /// Whether a missing `ax` has been searched for; some apps' windows on other Spaces can't be found.
    var axSearched = false
    let place: WindowPlace
    var thumbnail: CGImage?

    init(id: CGWindowID, pid: pid_t, appName: String, title: String, frame: CGRect, icon: NSImage?, ax: AXUIElement?,
         place: WindowPlace = .here) {
        self.id = id; self.pid = pid; self.appName = appName; self.title = title
        self.frame = frame; self.icon = icon; self.ax = ax; self.place = place
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

    /// The same window, now somewhere else (e.g. just hidden).
    func moved(to place: WindowPlace) -> WindowItem {
        let item = WindowItem(id: id, pid: pid, appName: appName, title: title, frame: frame, icon: icon, ax: ax, place: place)
        item.thumbnail = thumbnail
        return item
    }
    var displayTitle: String { title.isEmpty ? appName : title }
}

enum Windows {
    /// Windows visible on the current Space, front to back, then any of the `extra` kinds of window that aren't on screen.
    static func current(including extra: Set<OverviewInclude> = []) -> [WindowItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let here = items(from: list)
        guard !extra.isEmpty else { return here }
        return here + elsewhere(including: extra, excluding: Set(here.map(\.id)))
    }

    /// The IDs of every window that exists, on any Space.
    static func allIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    static func exists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return !list.isEmpty
    }

    /// Whether the window has a sheet open, such as "Save changes?" after being asked to close.
    static func hasSheet(_ item: WindowItem) -> Bool {
        guard let ax = item.ax else { return false }
        var value: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement] ?? []).contains { axString($0, kAXRoleAttribute) == kAXSheetRole }
    }

    /// The window with this CGWindowID, if it belongs to a regular app.
    static func item(withID id: CGWindowID) -> WindowItem? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return items(from: list).first
    }

    /// A normal app window as CGWindowList describes it.
    private struct Entry {
        let id: CGWindowID
        let pid: pid_t
        let app: NSRunningApplication
        let bounds: CGRect
        let name: String?
        let alpha: Double

        /// Frame in Cocoa global coordinates.
        var frame: CGRect {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }

    private static func entries(_ list: [[String: Any]]) -> [Entry] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 60, bounds.height >= 40,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { return nil }
            return Entry(id: id, pid: pid, app: app, bounds: bounds, name: info[kCGWindowName as String] as? String,
                         alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    private static func items(from list: [[String: Any]]) -> [WindowItem] {
        var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var items: [WindowItem] = []

        for entry in entries(list) where entry.alpha > 0.01 {
            if axCache[entry.pid] == nil { axCache[entry.pid] = axWindows(pid: entry.pid) }
            // CGWindowList also reports helper surfaces; keeping only windows the app exposes via AX filters them out.
            guard let ax = axCache[entry.pid]?[entry.id], !isSurface(ax) else { continue }

            let title = entry.name ?? axString(ax, kAXTitleAttribute) ?? ""
            items.append(WindowItem(id: entry.id, pid: entry.pid, appName: entry.app.localizedName ?? "", title: title,
                                    frame: entry.frame, icon: entry.app.icon, ax: ax))
        }
        return items
    }

    /// Windows that aren't on screen: on other desktops, full screen, minimized, or of hidden apps.
    private static func elsewhere(including extra: Set<OverviewInclude>, excluding shown: Set<CGWindowID>) -> [WindowItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let spaces = Spaces.read()
        var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var items: [WindowItem] = []

        for entry in entries(list) where !shown.contains(entry.id) {
            if axCache[entry.pid] == nil { axCache[entry.pid] = axWindows(pid: entry.pid) }
            // Apps leave windows on other Spaces out of their AX list; those get an element only when acted on.
            let ax = axCache[entry.pid]?[entry.id]
            if let ax, isSurface(ax) { continue }
            let title = entry.name ?? ax.flatMap { axString($0, kAXTitleAttribute) } ?? ""
            // Off screen, CGWindowList also reports an app's untitled helper surfaces and closed panels.
            guard ax != nil || !title.isEmpty else { continue }

            let place: WindowPlace
            if let ax, axBool(ax, kAXMinimizedAttribute) {
                place = .minimized
            } else if let space = spaces.space(of: entry.id) {
                if entry.app.isHidden { place = .hidden }
                else if space.isFullScreen { place = .fullScreen }
                else if !space.isCurrent { place = .otherDesktop(space.number) }
                else { continue } // on this desktop yet off screen: a window mid-close, or a background tab
            } else {
                continue
            }
            guard let include = place.include, extra.contains(include) else { continue }
            items.append(WindowItem(id: entry.id, pid: entry.pid, appName: entry.app.localizedName ?? "", title: title,
                                    frame: entry.frame, icon: entry.app.icon, ax: ax, place: place))
        }
        // Group by place, keeping front-to-back order within each.
        return items.enumerated()
            .sorted { ($0.element.place.sortKey, $0.offset) < ($1.element.place.sortKey, $1.offset) }
            .map(\.element)
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

    /// Finds a window's AX element by trying the app's element IDs one by one. Apps leave windows on other
    /// Spaces out of their AX window list, but these elements still answer. Takes tens of milliseconds, and
    /// misses some apps' windows entirely.
    private static func remoteElements(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) }) // "coco"
        for elementID in UInt64(0)..<1000 where found.count < wanted.count {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &wid) == .success, wanted.contains(wid) { found[wid] = element }
        }
        return found
    }

    /// Looks up, in the background, the elements of windows on other Spaces, so opening one doesn't wait for it.
    static func findElements(for items: [WindowItem]) {
        let missing = Dictionary(grouping: items.filter { $0.ax == nil && !$0.axSearched }, by: \.pid)
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = missing.mapValues { remoteElements(pid: $0[0].pid, wanted: Set($0.map(\.id))) }
            DispatchQueue.main.async {
                for (pid, items) in missing {
                    for item in items where !item.axSearched {
                        item.ax = item.ax ?? found[pid]?[item.id]
                        item.axSearched = true
                    }
                }
            }
        }
    }

    /// The window's AX element, looked up now if `findElements` hasn't got to it yet.
    static func element(for item: WindowItem) -> AXUIElement? {
        if item.ax == nil, !item.axSearched {
            item.ax = remoteElements(pid: item.pid, wanted: [item.id])[item.id]
            item.axSearched = true
        }
        return item.ax
    }

    static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return value as? String
    }

    /// A part of a window rather than a window: e.g. the toolbar strip a full-screen app keeps at the top of
    /// the screen, which apps list among their AX windows with an unknown subrole.
    private static func isSurface(_ el: AXUIElement) -> Bool {
        axString(el, kAXSubroleAttribute) == kAXUnknownSubrole
    }

    private static func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return value as? Bool ?? false
    }

    // MARK: Actions

    /// Brings the window to the front: unhiding its app, unminimizing it, or switching to its Space as needed.
    static func focus(_ item: WindowItem) {
        guard let app = item.app else { return }
        if item.place == .hidden { app.unhide() }
        if item.place == .minimized, let ax = item.ax {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Bring forward exactly this window, which switches straight to its Space. Activating the app instead
        // lets macOS pick which of its windows, and Spaces, to show: an app with windows on several Spaces
        // bounces between them.
        // The raise is what moves to a window on another Space, so look up its element if needed.
        let ax = element(for: item)
        if SkyLight.focus(window: item.id, pid: item.pid) {
            guard let ax else {
                // Some apps' windows on other Spaces have no element to raise (Obsidian, Dia): activating
                // the app goes to a Space where it has windows.
                if item.place != .here { activate(app) }
                return
            }
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            guard item.place != .here else { return }
            // Safety net, in case the window server didn't switch Spaces.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !isOnScreen(item.id) { activate(app) }
            }
            return
        }
        // Fallback if SkyLight's calls go away.
        if let ax {
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
        activate(app)
    }

    private static func activate(_ app: NSRunningApplication) {
        // Make the app frontmost through Accessibility too: a plain activate() from a background app
        // (the overview doesn't make Mission Plus active) can be ignored by macOS.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    private static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    static func close(_ item: WindowItem) {
        guard let ax = element(for: item) else { return }
        var button: AnyObject?
        if AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    static func minimize(_ item: WindowItem) {
        guard let ax = element(for: item) else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func unminimize(_ item: WindowItem) {
        guard let ax = item.ax else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    static func toggleFullScreen(_ item: WindowItem) {
        guard let ax = element(for: item) else { return }
        var value: AnyObject?
        AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &value)
        let isFull = (value as? Bool) ?? false
        AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, (!isFull) as CFBoolean)
    }

    static func hide(_ item: WindowItem) { item.app?.hide() }
    static func quit(_ item: WindowItem) { item.app?.terminate() }

    // MARK: Thumbnails

    /// Captures each window's contents. Calls `update` on the main thread as each image arrives.
    /// `sizes` gives the pixel size wanted for each window.
    static func captureThumbnails(sizes: [CGWindowID: CGSize], update: @escaping (CGWindowID, CGImage) -> Void) {
        guard CGPreflightScreenCaptureAccess(), !sizes.isEmpty else { return }
        let wanted = Set(sizes.keys)
        Task.detached(priority: .userInitiated) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            await withTaskGroup(of: Void.self) { group in
                for window in content.windows where wanted.contains(window.windowID) {
                    let size = sizes[window.windowID]!
                    group.addTask {
                        let config = SCStreamConfiguration()
                        config.width = max(1, Int(size.width))
                        config.height = max(1, Int(size.height))
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

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?
@_silgen_name("CGSCopySpacesForWindows") private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray?

/// Mission Control's Spaces, through private but long-stable CoreGraphics calls (the ones yabai and AltTab use).
struct Spaces {
    struct Space {
        let isCurrent: Bool
        let isFullScreen: Bool
        /// The desktop's number on its display, as Mission Control labels it. 0 for full-screen Spaces.
        let number: Int
    }

    private let byID: [UInt64: Space]
    private let connection = CGSMainConnectionID()

    static func read() -> Spaces {
        var byID: [UInt64: Space] = [:]
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        for display in displays {
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
            var desktop = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["id64"] as? UInt64 else { continue }
                let isFullScreen = space["type"] as? Int == 4
                if !isFullScreen { desktop += 1 }
                byID[id] = Space(isCurrent: id == current, isFullScreen: isFullScreen, number: isFullScreen ? 0 : desktop)
            }
        }
        return Spaces(byID: byID)
    }

    /// The Space a window is on, or nil for windows on none (minimized, or helper surfaces).
    /// A window on every Space reports the current one.
    func space(of window: CGWindowID) -> Space? {
        let spaces = spaceIDs(of: window).compactMap { byID[$0] }
        return spaces.first(where: \.isCurrent) ?? spaces.first
    }

    /// Whether a window is on a Space being shown on one of the displays.
    func isOnCurrentSpace(_ window: CGWindowID) -> Bool {
        spaceIDs(of: window).contains { byID[$0]?.isCurrent == true }
    }

    private func spaceIDs(of window: CGWindowID) -> [UInt64] {
        CGSCopySpacesForWindows(connection, 0x7, [window] as CFArray) as? [UInt64] ?? []
    }
}

/// Deprecated, and hidden from Swift, but still the way to get a process serial number for SkyLight.
@_silgen_name("GetProcessForPID")
private func getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Focuses one specific window the way the Dock does, through private SkyLight calls (as AltTab does).
/// Looked up at run time, so the app still works, with the fallback, if they disappear.
private enum SkyLight {
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFrontProcess = library.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
        .map { unsafeBitCast($0, to: SetFrontProcess.self) }
    private static let postEventRecord = library.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
        .map { unsafeBitCast($0, to: PostEventRecord.self) }

    static func focus(window: CGWindowID, pid: pid_t) -> Bool {
        guard let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr,
              setFrontProcess(&psn, window, 0x200) == .success else { return false } // 0x200: user generated
        // Make it the key window: a pair of window-server event records naming it.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: window) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        bytes.replaceSubrange(0x20..<0x30, with: [UInt8](repeating: 0xff, count: 0x10))
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            _ = postEventRecord(&psn, &bytes)
        }
        return true
    }
}
