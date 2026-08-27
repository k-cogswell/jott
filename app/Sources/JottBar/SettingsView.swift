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
    @State private var promptTextScale = Preferences.promptTextScale
    @State private var rememberPromptPosition = Preferences.rememberPromptPosition
    @State private var hasPromptPosition = Preferences.hasStoredPromptPosition

    /// Mirrored into state so the UI updates when a binding changes;
    /// Preferences itself is not observable.
    @State private var bindings: [HotKeyAction: KeyBinding] = [:]
    @State private var recording: HotKeyAction?
    @State private var failed: Set<HotKeyAction> = []

    @EnvironmentObject private var store: LedgerStore
    @State private var jiraStatus = JiraStatus.unknown
    @State private var jiraToken = ""
    @State private var jiraMessage: String?
    @State private var jiraWorking = false

    /// Edited copy of the JQL. Kept separate from the saved value so the
    /// Save button can tell whether anything actually changed, and a failed
    /// validation leaves what you typed on screen to fix.
    @State private var jqlDraft = ""
    @State private var jqlSaved = ""
    @State private var jqlIsDefault = true
    @State private var jqlWorking = false
    @State private var jqlMessage: String?
    @State private var jqlFailed = false

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

            jiraSection

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

            appearanceSection

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in Preferences.launchAtLogin = newValue }
                LabeledContent("Log directory", value: JottConfig.logBaseDir())
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            reloadBindings()
            reloadJira()
            reloadJQL()
            hasPromptPosition = Preferences.hasStoredPromptPosition
        }
    }

    // ------------------------------------------------------------------

    /// One scale drives the whole capture prompt. The sample below is built
    /// from the same PromptMetrics the prompt uses, so what you see here is
    /// the size you will actually get.
    private var appearanceSection: some View {
        Section {
            let metrics = PromptMetrics(scale: CGFloat(promptTextScale))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt text size")
                    Spacer()
                    Text("\(Int((promptTextScale * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $promptTextScale,
                        in: Preferences.promptTextScaleRange,
                        step: 0.05
                    )
                    .onChange(of: promptTextScale) { _, newValue in
                        Preferences.promptTextScale = newValue
                    }
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reset to 100%") {
                        Preferences.resetPromptTextScale()
                        promptTextScale = Preferences.promptTextScale
                    }
                    .disabled(promptTextScale == 1.0)
                    Spacer()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remember where I move the prompt", isOn: $rememberPromptPosition)
                    .onChange(of: rememberPromptPosition) { _, newValue in
                        Preferences.rememberPromptPosition = newValue
                    }

                HStack {
                    Text(positionSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Position") {
                        Preferences.resetPromptPosition()
                        hasPromptPosition = false
                    }
                    .disabled(!hasPromptPosition)
                }
            }

            // Live preview of a suggestion row -- the part that is hardest
            // to read at the default size.
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: metrics.rowSpacing) {
                    Image(systemName: "ticket")
                        .font(.system(size: metrics.rowIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: metrics.iconColumnWidth)
                    Text("PROJ-1234")
                        .font(.system(size: metrics.keyFontSize, design: .monospaced))
                        .bold()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("An example issue summary")
                        .font(.system(size: metrics.rowFontSize))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, metrics.rowVerticalPadding)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Scales the capture prompt — the typing field, your recent tasks and the Jira issue list — along with the panel itself, so longer summaries still fit. Takes effect the next time you open the prompt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Drag the prompt by its background to move it; this just reports what
    /// was remembered, in top-left screen coordinates.
    private var positionSummary: String {
        guard rememberPromptPosition else {
            return "The prompt opens near the top of the screen you are using."
        }
        guard let point = Preferences.promptPosition else {
            return "Drag the prompt anywhere — it will open there next time."
        }
        return "Opening at \(Int(point.x)), \(Int(point.y)). Drag the prompt to change it."
    }

    // ------------------------------------------------------------------

    @ViewBuilder
    private var jiraSection: some View {
        Section {
            if jiraStatus.configured == true {
                LabeledContent("Site", value: jiraStatus.site ?? "—")
                LabeledContent("Account", value: jiraStatus.email ?? "—")
                LabeledContent("Token type",
                               value: jiraStatus.mode == "scoped" ? "Scoped" : "Classic")

                if jiraStatus.valid == true {
                    Label("Connected as \(jiraStatus.displayName ?? "your account") — \(store.jira.issues.count) issues assigned",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)

                    if let warning = store.jira.truncationWarning {
                        Label(warning, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if jiraStatus.tokenStored == true {
                    Label(jiraStatus.error ?? "Stored token is not working.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Label("No token stored yet.", systemImage: "key")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    SecureField("API token", text: $jiraToken)
                        .textFieldStyle(.roundedBorder)
                    Button(jiraWorking ? "Connecting…" : "Connect") { connectJira() }
                        .disabled(jiraToken.isEmpty || jiraWorking)
                }

                HStack {
                    Button("Refresh Issues") {
                        store.refreshJira(force: true)
                        jiraMessage = "Refreshing…"
                    }
                    Button("Disconnect") {
                        JiraBridge.disconnect()
                        jiraToken = ""
                        jiraMessage = "Token removed."
                        reloadJira()
                    }
                    .disabled(jiraStatus.tokenStored != true)
                    Spacer()
                    Button("Open config.toml") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: JottConfig.configFile))
                    }
                }

                if let jiraMessage {
                    Text(jiraMessage).font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                jqlEditor
            } else {
                Text("Jira is not configured.")
                    .font(.callout)
                Text("Add jira_site and jira_email to config.toml, then come back here to paste your API token.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open config.toml") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: JottConfig.configFile))
                }
            }
        } header: {
            Text("Jira")
        } footer: {
            Text("Assigned issues appear in the capture prompt. Your token is stored in the macOS Keychain, never in config.toml.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Which issues the prompt offers. Validated against Jira before it is
    /// saved -- a syntax error comes back as Jira's own parser message, and
    /// a query that matches nothing is reported rather than silently kept.
    private var jqlEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Issue query (JQL)")
                Spacer()
                if jqlIsDefault {
                    Text("default").font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("JQL", text: $jqlDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2...5)
                .disabled(jqlWorking)

            HStack {
                Button(jqlWorking ? "Checking…" : "Save Query") { saveJQL() }
                    .disabled(jqlWorking
                              || jqlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || jqlDraft == jqlSaved)

                Button("Revert") { jqlDraft = jqlSaved; jqlMessage = nil; jqlFailed = false }
                    .disabled(jqlWorking || jqlDraft == jqlSaved)

                Button("Use Default") { resetJQL() }
                    .disabled(jqlWorking || jqlIsDefault)

                Spacer()
            }

            if let jqlMessage {
                Text(jqlMessage)
                    .font(.caption)
                    .foregroundStyle(jqlFailed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Saved queries take effect immediately — the issue cache is cleared on save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveJQL() {
        jqlWorking = true
        jqlMessage = nil
        jqlFailed = false
        let query = jqlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached {
            let result = JiraBridge.setJQL(query)
            await MainActor.run {
                jqlWorking = false
                if result.ok {
                    jqlSaved = result.jql ?? query
                    jqlDraft = jqlSaved
                    jqlIsDefault = result.isDefault ?? false
                    jqlFailed = false
                    if result.matched == 0 {
                        // Jira accepts an unknown field name and returns
                        // nothing, so zero matches is worth flagging.
                        jqlFailed = true
                        jqlMessage = "Saved, but nothing matched. Check field names and values — Jira accepts an unknown field without complaint."
                    } else {
                        jqlMessage = "Saved. \(result.matchedDescription ?? "?") issue(s) match."
                    }
                    store.refreshJira(force: true)
                    reloadJira()
                } else {
                    jqlFailed = true
                    jqlMessage = result.error ?? "Could not save the query."
                }
            }
        }
    }

    private func resetJQL() {
        jqlWorking = true
        jqlMessage = nil
        jqlFailed = false
        Task.detached {
            let result = JiraBridge.resetJQL()
            await MainActor.run {
                jqlWorking = false
                if result.ok {
                    jqlSaved = result.jql ?? ""
                    jqlDraft = jqlSaved
                    jqlIsDefault = true
                    jqlMessage = "Restored the default query."
                    store.refreshJira(force: true)
                    reloadJira()
                } else {
                    jqlFailed = true
                    jqlMessage = result.error ?? "Could not restore the default."
                }
            }
        }
    }

    private func reloadJQL() {
        Task.detached {
            let result = JiraBridge.jql()
            await MainActor.run {
                guard result.ok, let jql = result.jql else { return }
                jqlSaved = jql
                jqlIsDefault = result.isDefault ?? false
                // Never clobber an unsaved edit.
                if jqlDraft.isEmpty || jqlDraft == jqlSaved { jqlDraft = jql }
            }
        }
    }

    private func connectJira() {
        jiraWorking = true
        jiraMessage = nil
        let token = jiraToken
        Task.detached {
            let result = JiraBridge.connect(token: token)
            await MainActor.run {
                jiraWorking = false
                jiraMessage = result.message
                if result.ok {
                    jiraToken = ""      // do not keep the secret in view state
                    store.refreshJira(force: true)
                }
                reloadJira()
            }
        }
    }

    private func reloadJira() {
        Task.detached {
            let status = JiraBridge.status()
            await MainActor.run { jiraStatus = status }
        }
    }

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
