import SwiftUI
import AppKit

// ======================================================================
// APPLICATION ENTRY POINT
// ======================================================================
// MenuBarExtra in .window style so the dropdown can be real SwiftUI
// rather than a stack of NSMenuItems -- this is the seam the fuller UI
// grows out of.
@main
struct JottBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = LedgerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(onPerform: { delegate.perform($0) })
                .environmentObject(store)
        } label: {
            // Icon plus live status text.
            HStack(spacing: 4) {
                Image(systemName: store.summary.currentTask != nil ? "clock.fill" : "clock")
                Text(store.statusTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var prompt = PromptController(store: LedgerStore.shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        HotKeyManager.shared.onFire = { [weak self] action in
            Task { @MainActor in self?.perform(action) }
        }
        HotKeyManager.shared.syncFromPreferences()
    }

    func showPrompt(mode: PromptMode = .immediate) {
        prompt.toggle(mode: mode)
    }

    /// Routes a fired hotkey to its action. The dropdown calls this too, so
    /// both entry points stay in step.
    func perform(_ action: HotKeyAction) {
        switch action {
        case .newEntry:
            prompt.toggle(mode: .immediate)
        case .retroactiveEntry:
            prompt.toggle(mode: .retroactive)
        case .continueLast:
            LedgerStore.shared.continueLast()
        case .stopTracking:
            LedgerStore.shared.stop()
        case .weeklyTimesheet:
            NSApp.activate(ignoringOtherApps: true)
            WeekWindow.shared.show()
        case .editToday:
            NSApp.activate(ignoringOtherApps: true)
            LogEditorWindow.shared.show(store: LedgerStore.shared)
        case .togglePromptMode:
            break // matched locally inside the prompt panel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregisterAll()
    }
}
