import AppKit
import Carbon.HIToolbox

// ======================================================================
// GLOBAL HOTKEYS
// ======================================================================
// Uses Carbon's RegisterEventHotKey rather than a CGEventTap on purpose:
// a registered hotkey needs NO Accessibility permission, so first launch
// never shows a security prompt. That matters a lot for handing this to
// a teammate.
//
// Manages one registration per HotKeyAction. RegisterEventHotKey fails
// when another app already owns a combination, and that failure is
// surfaced rather than swallowed -- a shortcut that silently does
// nothing is the worst possible outcome here.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var idToAction: [UInt32: HotKeyAction] = [:]

    /// Actions whose last registration attempt was rejected by the system.
    private(set) var failed: Set<HotKeyAction> = []

    var onFire: ((HotKeyAction) -> Void)?

    private init() {}

    /// Re-registers every global action from current preferences.
    func syncFromPreferences() {
        installHandlerIfNeeded()
        failed.removeAll()

        for action in HotKeyAction.allCases where action.isGlobal {
            unregister(action)
            let binding = Preferences.binding(for: action)
            guard binding.isBound else { continue }
            if !register(action, binding: binding) {
                failed.insert(action)
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Captureless closure so it can bridge to a C function pointer.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = HotKeyManager.shared.idToAction[id.id] {
                HotKeyManager.shared.onFire?(action)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    @discardableResult
    private func register(_ action: HotKeyAction, binding: KeyBinding) -> Bool {
        let index = UInt32((HotKeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
        let id = EventHotKeyID(signature: OSType(0x4A4F5454), id: index) // 'JOTT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action] = ref
        idToAction[index] = action
        return true
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
    }

    func unregisterAll() {
        for action in refs.keys { unregister(action) }
        idToAction.removeAll()
    }
}
