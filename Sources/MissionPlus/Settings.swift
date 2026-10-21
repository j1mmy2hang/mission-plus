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

/// Global hotkeys that open the overview.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case controlOptionUp, optionTab, optionBacktick, f13

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionUp: return "⌃⌥↑"
        case .optionTab: return "⌥⇥"
        case .optionBacktick: return "⌥`"
        case .f13: return "F13"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlOptionUp: return UInt32(kVK_UpArrow)
        case .optionTab: return UInt32(kVK_Tab)
        case .optionBacktick: return UInt32(kVK_ANSI_Grave)
        case .f13: return UInt32(kVK_F13)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .controlOptionUp: return UInt32(controlKey | optionKey)
        case .optionTab, .optionBacktick: return UInt32(optionKey)
        case .f13: return 0
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var hotKey: HotKeyChoice {
        didSet { defaults.set(hotKey.rawValue, forKey: "hotKey") }
    }
    @Published var enhanceMissionControl: Bool {
        didSet { defaults.set(enhanceMissionControl, forKey: "enhanceMissionControl") }
    }
    @Published var alwaysShowTitles: Bool {
        didSet { defaults.set(alwaysShowTitles, forKey: "alwaysShowTitles") }
    }
    @Published var showButtonsOnHover: Bool {
        didSet { defaults.set(showButtonsOnHover, forKey: "showButtonsOnHover") }
    }
    @Published var disabledShortcuts: Set<String> {
        didSet { defaults.set(Array(disabledShortcuts), forKey: "disabledShortcuts") }
    }

    private init() {
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .controlOptionUp
        enhanceMissionControl = defaults.object(forKey: "enhanceMissionControl") as? Bool ?? true
        alwaysShowTitles = defaults.object(forKey: "alwaysShowTitles") as? Bool ?? false
        showButtonsOnHover = defaults.object(forKey: "showButtonsOnHover") as? Bool ?? true
        disabledShortcuts = Set(defaults.stringArray(forKey: "disabledShortcuts") ?? [])
    }

    func isEnabled(_ s: Shortcut) -> Bool { !disabledShortcuts.contains(s.rawValue) }

    func setEnabled(_ s: Shortcut, _ on: Bool) {
        if on { disabledShortcuts.remove(s.rawValue) } else { disabledShortcuts.insert(s.rawValue) }
    }
}
