import Foundation
import ServiceManagement
import Carbon.HIToolbox

// ======================================================================
// STORED SETTINGS
// ======================================================================
enum Preferences {
    private static let defaults = UserDefaults.standard

    // -- Key bindings, one entry per HotKeyAction --

    private static func codeKey(_ a: HotKeyAction) -> String { "binding.\(a.rawValue).code" }
    private static func modsKey(_ a: HotKeyAction) -> String { "binding.\(a.rawValue).mods" }

    static func binding(for action: HotKeyAction) -> KeyBinding {
        // An explicitly cleared binding is stored as modifiers 0, which is
        // distinct from "never set" -- so check for the key's presence
        // rather than treating 0 as missing.
        guard defaults.object(forKey: modsKey(action)) != nil else {
            return action.defaultBinding
        }
        return KeyBinding(keyCode: UInt32(defaults.integer(forKey: codeKey(action))),
                          modifiers: UInt32(defaults.integer(forKey: modsKey(action))))
    }

    static func setBinding(_ binding: KeyBinding, for action: HotKeyAction) {
        defaults.set(Int(binding.keyCode), forKey: codeKey(action))
        defaults.set(Int(binding.modifiers), forKey: modsKey(action))
    }

    static func resetBinding(for action: HotKeyAction) {
        defaults.removeObject(forKey: codeKey(action))
        defaults.removeObject(forKey: modsKey(action))
    }

    static func resetAllBindings() {
        for action in HotKeyAction.allCases { resetBinding(for: action) }
    }

    /// Actions sharing a binding with `action`. Two global shortcuts on the
    /// same combination means only one of them can ever register.
    static func conflicts(with action: HotKeyAction) -> [HotKeyAction] {
        let mine = binding(for: action)
        guard mine.isBound else { return [] }
        return HotKeyAction.allCases.filter { other in
            other != action
                && other.isGlobal == action.isGlobal
                && binding(for: other) == mine
        }
    }

    static var cliPath: String {
        get { JottCLI.resolvePath() ?? "" }
        set { defaults.set(newValue, forKey: JottCLI.cliPathDefaultsKey) }
    }

    // -- Login item. SMAppService works fine for an ad-hoc signed app. --

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("JottBar: login item change failed: \(error.localizedDescription)")
            }
        }
    }
}
