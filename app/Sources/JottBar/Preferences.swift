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

    // -- Appearance --

    private static let promptTextScaleKey = "prompt.textScale"

    /// Bounds chosen so the panel stays usable: below ~0.85 the Jira key
    /// badges stop being legible, above ~1.6 a 560pt-derived panel starts
    /// crowding a laptop screen.
    static let promptTextScaleRange: ClosedRange<Double> = 0.85...1.6

    /// One multiplier for every dimension in the capture prompt. Type and
    /// the box around it have to grow together, or long issue summaries
    /// truncate the moment the font goes up.
    static var promptTextScale: Double {
        get {
            guard defaults.object(forKey: promptTextScaleKey) != nil else { return 1.0 }
            let stored = defaults.double(forKey: promptTextScaleKey)
            return min(max(stored, promptTextScaleRange.lowerBound),
                       promptTextScaleRange.upperBound)
        }
        set {
            defaults.set(min(max(newValue, promptTextScaleRange.lowerBound),
                             promptTextScaleRange.upperBound),
                         forKey: promptTextScaleKey)
        }
    }

    static func resetPromptTextScale() {
        defaults.removeObject(forKey: promptTextScaleKey)
    }

    // -- Prompt position --

    private static let rememberPromptPositionKey = "prompt.rememberPosition"
    private static let promptPositionXKey = "prompt.position.x"
    private static let promptPositionYKey = "prompt.position.y"

    /// On by default: having the prompt reappear where you left it is the
    /// behaviour people expect once they discover it can be dragged.
    static var rememberPromptPosition: Bool {
        get {
            guard defaults.object(forKey: rememberPromptPositionKey) != nil else { return true }
            return defaults.bool(forKey: rememberPromptPositionKey)
        }
        set { defaults.set(newValue, forKey: rememberPromptPositionKey) }
    }

    /// The panel's TOP-left corner in screen coordinates.
    ///
    /// Top-left rather than AppKit's native bottom-left because the panel
    /// grows downward as suggestions appear and when the text scale changes
    /// -- anchoring the bottom would make the saved spot drift by however
    /// tall the prompt happened to be when it was saved.
    static var promptPosition: CGPoint? {
        get {
            guard defaults.object(forKey: promptPositionXKey) != nil,
                  defaults.object(forKey: promptPositionYKey) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: promptPositionXKey),
                           y: defaults.double(forKey: promptPositionYKey))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: promptPositionXKey)
                defaults.removeObject(forKey: promptPositionYKey)
                return
            }
            defaults.set(Double(newValue.x), forKey: promptPositionXKey)
            defaults.set(Double(newValue.y), forKey: promptPositionYKey)
        }
    }

    static var hasStoredPromptPosition: Bool { promptPosition != nil }

    static func resetPromptPosition() {
        promptPosition = nil
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
