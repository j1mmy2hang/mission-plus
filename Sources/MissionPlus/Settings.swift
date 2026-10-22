import AppKit
import Carbon.HIToolbox

/// Every keyboard action available in the overview. Each can be switched off in Preferences.
enum Shortcut: String, CaseIterable, Identifiable {
    case closeWindow, minimizeWindow, hideApp, quitApp
    case closeAll, minimizeAll, hideOthers
    case fullScreen

    var id: String { rawValue }

    var keys: String {
        switch self {
        case .closeWindow: return "⌘W"
        case .minimizeWindow: return "⌘M"
        case .hideApp: return "⌘H"
        case .quitApp: return "⌘Q"
        case .closeAll: return "⌥⌘W"
        case .minimizeAll: return "⌥⌘M"
        case .hideOthers: return "⌥⌘H"
        case .fullScreen: return "⌃⌘F"
        }
    }

    var label: String {
        switch self {
        case .closeWindow: return "Close the highlighted window"
        case .minimizeWindow: return "Minimize the highlighted window"
        case .hideApp: return "Hide the highlighted window's app"
        case .quitApp: return "Quit the highlighted window's app"
        case .closeAll: return "Close all windows"
        case .minimizeAll: return "Minimize all windows"
        case .hideOthers: return "Hide all apps except the highlighted one"
        case .fullScreen: return "Toggle full screen for the highlighted window"
        }
    }

    /// Matches a key-down event against this shortcut.
    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch self {
        case .closeWindow: return mods == .command && key == "w"
        case .minimizeWindow: return mods == .command && key == "m"
        case .hideApp: return mods == .command && key == "h"
        case .quitApp: return mods == .command && key == "q"
        case .closeAll: return mods == [.command, .option] && event.keyCode == UInt16(kVK_ANSI_W)
        case .minimizeAll: return mods == [.command, .option] && event.keyCode == UInt16(kVK_ANSI_M)
        case .hideOthers: return mods == [.command, .option] && event.keyCode == UInt16(kVK_ANSI_H)
        case .fullScreen: return mods == [.command, .control] && event.keyCode == UInt16(kVK_ANSI_F)
        }
    }
}

/// The global hotkey that opens the overview: a key plus Carbon modifier flags, and how to display it.
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = HotKeySpec(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥↑")

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Tab: "⇥", kVK_Space: "Space", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// A hotkey from a key press, or nil if it would get in the way of normal typing
    /// (a plain or shift-only key, unless it's a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let code = Int(event.keyCode)
        let functionKey = Self.functionKeys[code]
        guard functionKey != nil || !flags.subtracting(.shift).isEmpty else { return nil }

        var carbon = 0
        var label = ""
        if flags.contains(.control) { carbon |= controlKey; label += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; label += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; label += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; label += "⌘" }
        guard let key = functionKey ?? Self.namedKeys[code] ?? event.charactersIgnoringModifiers?.uppercased(),
              !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(carbon), label: label + key)
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// The fixed choices of earlier versions, by their stored names.
    static func legacy(_ name: String) -> HotKeySpec? {
        switch name {
        case "controlOptionUp": return .standard
        case "optionTab": return HotKeySpec(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), label: "⌥⇥")
        case "optionBacktick": return HotKeySpec(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey), label: "⌥`")
        case "f13": return HotKeySpec(keyCode: UInt32(kVK_F13), modifiers: 0, label: "F13")
        default: return nil
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var hotKey: HotKeySpec {
        didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: "overviewHotKey") }
    }
    /// True while Preferences is recording a new hotkey, so the current one is paused.
    @Published var isRecordingHotKey = false
    @Published var swipeOpensOverview: Bool {
        didSet { defaults.set(swipeOpensOverview, forKey: "swipeOpensOverview") }
    }
    @Published var alwaysShowTitles: Bool {
        didSet { defaults.set(alwaysShowTitles, forKey: "alwaysShowTitles") }
    }
    @Published var disabledShortcuts: Set<String> {
        didSet { defaults.set(Array(disabledShortcuts), forKey: "disabledShortcuts") }
    }

    private init() {
        hotKey = defaults.data(forKey: "overviewHotKey").flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) }
            ?? HotKeySpec.legacy(defaults.string(forKey: "hotKey") ?? "")
            ?? .standard
        swipeOpensOverview = defaults.object(forKey: "swipeOpensOverview") as? Bool ?? false
        alwaysShowTitles = defaults.object(forKey: "alwaysShowTitles") as? Bool ?? false
        disabledShortcuts = Set(defaults.stringArray(forKey: "disabledShortcuts") ?? [])
    }

    func isEnabled(_ s: Shortcut) -> Bool { !disabledShortcuts.contains(s.rawValue) }

    func setEnabled(_ s: Shortcut, _ on: Bool) {
        if on { disabledShortcuts.remove(s.rawValue) } else { disabledShortcuts.insert(s.rawValue) }
    }
}
