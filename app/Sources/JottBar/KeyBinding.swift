import Foundation
import AppKit
import Carbon.HIToolbox

// ======================================================================
// KEY BINDINGS
// ======================================================================
// One value type for every shortcut in the app, whether it is registered
// globally with Carbon or matched locally against an NSEvent.

struct KeyBinding: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let unbound = KeyBinding(keyCode: 0, modifiers: 0)

    /// A binding needs at least one modifier: a bare key would swallow
    /// ordinary typing when registered globally.
    var isBound: Bool { modifiers != 0 }

    var description: String {
        guard isBound else { return "Not set" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + (KeyBinding.keyName(keyCode) ?? "Key \(keyCode)")
    }

    /// Does this binding match a live NSEvent? Used for the in-panel
    /// shortcuts, which are matched rather than globally registered.
    func matches(_ event: NSEvent) -> Bool {
        guard isBound, UInt32(event.keyCode) == keyCode else { return false }
        return KeyBinding.carbonModifiers(from: event.modifierFlags) == modifiers
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    static func keyName(_ code: UInt32) -> String? {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Escape): "esc", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Comma): ",",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_Grave): "`",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return map[code]
    }
}

// ----------------------------------------------------------------------

/// Every shortcut the app exposes. `global` ones are registered with the
/// system and fire from any app; the rest are matched only while the
/// relevant JottBar window has focus.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case newEntry
    case retroactiveEntry
    case continueLast
    case stopTracking
    case weeklyTimesheet
    case editToday
    case searchHistory
    case togglePromptMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newEntry:         return "New Entry"
        case .retroactiveEntry: return "Log Retroactively"
        case .continueLast:     return "Continue Last Task"
        case .stopTracking:     return "Stop Tracking"
        case .weeklyTimesheet:  return "Weekly Timesheet"
        case .editToday:        return "Edit Today's Log"
        case .searchHistory:    return "Search History"
        case .togglePromptMode: return "Toggle Retroactive Mode"
        }
    }

    var detail: String {
        switch self {
        case .newEntry:         return "Opens the capture prompt"
        case .retroactiveEntry: return "Opens the prompt in retroactive mode"
        case .continueLast:     return "Resumes the task before your last break"
        case .stopTracking:     return "Logs a stop entry"
        case .weeklyTimesheet:  return "Opens the weekly timesheet window"
        case .editToday:        return "Opens today's log editor"
        case .searchHistory:    return "Searches every entry you have logged"
        case .togglePromptMode: return "Switches the open prompt between now and earlier"
        }
    }

    /// Global actions are registered system-wide. `togglePromptMode` only
    /// makes sense while the prompt is on screen, so it stays local.
    var isGlobal: Bool { self != .togglePromptMode }

    /// Only New Entry ships bound. Leaving the rest unset avoids stomping
    /// on shortcuts other apps already own; the user opts in per action.
    var defaultBinding: KeyBinding {
        switch self {
        case .newEntry:
            return KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
        case .togglePromptMode:
            return KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
        default:
            return .unbound
        }
    }
}
