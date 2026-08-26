import SwiftUI
import AppKit
import Carbon.HIToolbox

// ======================================================================
// SETTINGS
// ======================================================================
// Hosted in a plain NSWindow rather than the SwiftUI Settings scene,
// because a MenuBarExtra-only app has no menu bar to open it from.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(store: LedgerStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "JottBar Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct SettingsView: View {
    @State private var launchAtLogin = Preferences.launchAtLogin
    @State private var cliPath = Preferences.cliPath

    /// Mirrored into state so the UI updates when a binding changes;
    /// Preferences itself is not observable.
    @State private var bindings: [HotKeyAction: KeyBinding] = [:]
    @State private var recording: HotKeyAction?
    @State private var failed: Set<HotKeyAction> = []

    private var globalActions: [HotKeyAction] { HotKeyAction.allCases.filter(\.isGlobal) }
    private var localActions: [HotKeyAction] { HotKeyAction.allCases.filter { !$0.isGlobal } }

    var body: some View {
        Form {
            Section {
                ForEach(globalActions) { action in
                    row(action)
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("Work from any app. None require Accessibility permission. Only New Entry is set by default — the rest are yours to assign.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(localActions) { action in
                    row(action)
                }
            } header: {
                Text("In the Capture Prompt")
            } footer: {
                Text("Active only while the prompt is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset Shortcuts to Defaults") {
                        Preferences.resetAllBindings()
                        reloadBindings()
                    }
                    Spacer()
                }
            }

            Section("Command Line Tool") {
                HStack {
                    TextField("Path to jott", text: $cliPath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: cliPath) { _, newValue in Preferences.cliPath = newValue }
                    Button("Choose…") { chooseCLI() }
                }
                if !FileManager.default.fileExists(atPath: cliPath) {
                    Label("Not found — writing entries will fail.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in Preferences.launchAtLogin = newValue }
                LabeledContent("Log directory", value: JottConfig.logBaseDir())
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: reloadBindings)
    }

    // ------------------------------------------------------------------

    @ViewBuilder
    private func row(_ action: HotKeyAction) -> some View {
        let binding = bindings[action] ?? .unbound
        let conflicts = Preferences.conflicts(with: action)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                    Text(action.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ShortcutRecorder(
                    action: action,
                    binding: binding,
                    recording: $recording,
                    onCapture: { assign($0, to: action) },
                    onClear: { assign(.unbound, to: action) }
                )
            }

            if failed.contains(action) {
                Label("Another app already uses \(binding.description). Pick a different combination.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if !conflicts.isEmpty {
                Label("Also assigned to \(conflicts.map(\.title).joined(separator: ", ")).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func assign(_ binding: KeyBinding, to action: HotKeyAction) {
        Preferences.setBinding(binding, for: action)
        recording = nil
        reloadBindings()
    }

    private func reloadBindings() {
        var map: [HotKeyAction: KeyBinding] = [:]
        for action in HotKeyAction.allCases {
            map[action] = Preferences.binding(for: action)
        }
        bindings = map
        HotKeyManager.shared.syncFromPreferences()
        failed = HotKeyManager.shared.failed
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            cliPath = url.path
            Preferences.cliPath = url.path
        }
    }
}

// ----------------------------------------------------------------------

/// Click to record, then press a combination. Escape cancels, Delete
/// clears. Only one recorder is armed at a time, tracked by `recording`.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    let binding: KeyBinding
    @Binding var recording: HotKeyAction?
    var onCapture: (KeyBinding) -> Void
    var onClear: () -> Void

    @State private var monitor: Any?

    private var isRecording: Bool { recording == action }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording = isRecording ? nil : action
            } label: {
                Text(isRecording ? "Press keys…" : binding.description)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!binding.isBound)
            .opacity(binding.isBound ? 1 : 0.2)
            .help("Clear this shortcut")
        }
        .onChange(of: recording) { _, _ in isRecording ? start() : stop() }
        .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                recording = nil
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) {
                onClear()
                return nil
            }
            let mods = KeyBinding.carbonModifiers(from: event.modifierFlags)
            // Require a modifier: a bare key registered globally would
            // swallow that key everywhere in the OS.
            guard mods != 0 else { return nil }
            onCapture(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: mods))
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
