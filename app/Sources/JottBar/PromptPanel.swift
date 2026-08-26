import AppKit
import SwiftUI

// ======================================================================
// CAPTURE PANEL
// ======================================================================
// The Spotlight-style prompt the hotkey summons. An NSPanel rather than a
// SwiftUI Window so it can float above other apps, take key focus without
// a Dock icon, and dismiss itself when it loses focus.
/// Prompt state the panel and its key monitor both need to touch.
@MainActor
final class PromptState: ObservableObject {
    @Published var mode: PromptMode
    @Published var minutesAgo: Int = 15

    init(mode: PromptMode) { self.mode = mode }

    func toggleMode() {
        mode = (mode == .retroactive) ? .immediate : .retroactive
    }
}

final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PromptController: NSObject, NSWindowDelegate {
    private var panel: PromptPanel?
    private let store: LedgerStore
    /// NSApp.activate is asynchronous. Until the panel has actually become
    /// key we must ignore resignKey, or the transient non-key state during
    /// the activation handshake dismisses the panel before focus lands.
    private var hasBecomeKey = false
    /// The panel grows when suggestions or the retroactive row appear. AppKit
    /// anchors windows by their BOTTOM-left corner, so without pinning the top
    /// edge the prompt would visibly slide up the screen as it resizes.
    private var pinnedTopY: CGFloat?
    private var state: PromptState?
    private var keyMonitor: Any?

    init(store: LedgerStore) {
        self.store = store
    }

    func toggle(mode: PromptMode = .immediate) {
        if panel?.isVisible == true { dismiss() } else { present(mode: mode) }
    }

    func present(mode: PromptMode = .immediate) {
        store.reload()

        let state = PromptState(mode: mode)
        self.state = state
        installKeyMonitor(state)

        let view = PromptView(
            state: state,
            suggestions: store.summary.recentTasks,
            currentTask: store.summary.currentTask,
            onSubmit: { [weak self] text, minutesAgo in
                if let minutesAgo, minutesAgo > 0 {
                    self?.store.backlog(minutes: minutesAgo, task: text)
                } else {
                    self?.store.log(text)
                }
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() }
        )

        // No .nonactivatingPanel: this panel is meant to take key focus so
        // typing lands in it immediately. A nonactivating panel never
        // becomes key, which leaves the caret in whatever app was in front.
        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 74),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        // Follow the user across Spaces and show above fullscreen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // contentViewController (rather than contentView) makes AppKit resize
        // the window to the SwiftUI content's fitting size as it changes.
        panel.contentViewController = NSHostingController(rootView: view)

        positionNearTop(panel)
        pinnedTopY = panel.frame.maxY
        panel.delegate = self
        self.panel = panel
        hasBecomeKey = false

        // Accessory apps must activate explicitly or the panel comes up
        // visible but unfocused.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Matches the configured Toggle Retroactive Mode binding while the
    /// prompt is open. A local monitor rather than a doCommandBy selector,
    /// so the combination is user-configurable rather than fixed to Option-Return.
    private func installKeyMonitor(_ state: PromptState) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let binding = Preferences.binding(for: .togglePromptMode)
            if binding.matches(event) {
                state.toggleMode()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func dismiss() {
        removeKeyMonitor()
        state = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        hasBecomeKey = false
        pinnedTopY = nil
    }

    /// Keep the top edge where it started as the panel grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let top = pinnedTopY else { return }
        var origin = panel.frame.origin
        origin.y = top - panel.frame.height
        if abs(origin.y - panel.frame.origin.y) > 0.5 {
            panel.setFrameOrigin(origin)
        }
    }

    /// Fires once activation actually completes -- the only point at which
    /// claiming first responder is guaranteed to stick.
    func windowDidBecomeKey(_ notification: Notification) {
        hasBecomeKey = true
        guard let panel else { return }
        if let field = Self.firstTextField(in: panel.contentView),
           panel.firstResponder !== field.currentEditor() {
            panel.makeFirstResponder(field)
        }
    }

    // Close as soon as focus genuinely moves elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        guard hasBecomeKey else { return }
        dismiss()
    }

    private func positionNearTop(_ panel: NSPanel) {
        // Prefer the screen the pointer is on, so the prompt appears where
        // the user is looking on a multi-monitor setup.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { panel.center(); return }
        let frame = panel.frame
        let x = screen.frame.midX - frame.width / 2
        let y = screen.frame.midY + screen.frame.height * 0.12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }
}

// ======================================================================
// FOCUS-RELIABLE TEXT FIELD
// ======================================================================
// SwiftUI's @FocusState is applied on the next render pass, which for a
// freshly ordered-in NSPanel is too early -- the window is not key yet and
// the request is silently dropped. Wrapping a real NSTextField lets the
// field claim first responder the moment it is installed in the window,
// and gives deterministic Return / Escape / arrow handling that does not
// depend on SwiftUI focus either.
final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct PromptTextField: NSViewRepresentable {
    enum Move { case up, down }

    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMove: (Move) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PromptTextField

        init(_ parent: PromptTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(.up)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(.down)
                return true
            default:
                return false
            }
        }
    }
}

// ----------------------------------------------------------------------

enum PromptMode {
    case immediate      // starts tracking now
    case retroactive    // started N minutes ago -- routes to `jott backlog`
}

struct PromptView: View {
    @ObservedObject var state: PromptState
    let suggestions: [String]
    let currentTask: String?
    /// (task, minutesAgo). minutesAgo is nil for an immediate entry.
    let onSubmit: (String, Int?) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var selection: Int = -1

    private static let presets = [5, 15, 30, 60]

    /// Recent tasks filtered by what has been typed so far.
    private var matches: [String] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = suggestions.filter { $0.lowercased() != q }
        guard !q.isEmpty else { return Array(pool.prefix(5)) }
        return Array(pool.filter { $0.lowercased().contains(q) }.prefix(5))
    }

    private var isRetroactive: Bool { state.mode == .retroactive }

    private var minutesAgo: Int { state.minutesAgo }

    private var toggleHint: String {
        let binding = Preferences.binding(for: .togglePromptMode)
        guard binding.isBound else { return "" }
        return isRetroactive
            ? "\(binding.description) log now instead"
            : "\(binding.description) started earlier"
    }

    /// The clock time the entry will actually be stamped with.
    private var startsAt: String {
        let secs = max(0, Date().secondsSinceMidnight - Double(minutesAgo * 60))
        return String(Ledger.clockString(secs).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isRetroactive ? "clock.arrow.circlepath" : "clock")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isRetroactive ? Color.accentColor : .secondary)

                PromptTextField(
                    text: $text,
                    placeholder: placeholder,
                    onSubmit: submit,
                    onCancel: onCancel,
                    onMove: move
                )
            }
            .padding(.horizontal, 18)
            .frame(height: 74)

            if isRetroactive { retroactiveRow }

            if !matches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                        HStack {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(match).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(index == selection ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { onSubmit(match, isRetroactive ? minutesAgo : nil) }
                    }
                }
                .padding(.vertical, 6)
            }

            hint
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: matches.count) { _, newCount in
            if selection >= newCount { selection = newCount - 1 }
        }
    }

    private var retroactiveRow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("Started").foregroundStyle(.secondary)

                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        state.minutesAgo = preset
                    } label: {
                        Text("\(preset)m")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(minutesAgo == preset ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Stepper(value: $state.minutesAgo, in: 1...720, step: 5) {
                    Text("\(minutesAgo)m ago")
                        .monospacedDigit()
                }
                .fixedSize()

                Spacer()

                Text("at \(startsAt)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
    }

    private var hint: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(toggleHint)
                Spacer()
                Text("↩ log   esc cancel")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }

    private var placeholder: String {
        if isRetroactive { return "What did you start \(minutesAgo)m ago?" }
        if let current = currentTask { return "Now: \(current) — what next?" }
        return "What are you working on?"
    }

    private func move(_ direction: PromptTextField.Move) {
        switch direction {
        case .down: selection = min(selection + 1, matches.count - 1)
        case .up:   selection = max(selection - 1, -1)
        }
    }

    private func submit() {
        let value = (selection >= 0 && selection < matches.count) ? matches[selection] : text
        onSubmit(value, isRetroactive ? minutesAgo : nil)
    }
}
