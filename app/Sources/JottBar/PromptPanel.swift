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
    /// Likewise anchor the horizontal centre: the panel is sized by its
    /// SwiftUI content after creation, and AppKit grows a window rightward
    /// from its origin, so a width change would otherwise push it off centre.
    private var pinnedCenterX: CGFloat?
    private var state: PromptState?
    private var keyMonitor: Any?
    /// Set while WE are moving the panel, so the delegate can tell a
    /// programmatic reposition from the user dragging it and only persist
    /// the latter.
    private var isRepositioning = false

    init(store: LedgerStore) {
        self.store = store
    }

    func toggle(mode: PromptMode = .immediate) {
        if panel?.isVisible == true { dismiss() } else { present(mode: mode) }
    }

    /// Opens straight into retroactive mode with the minutes pre-filled --
    /// used when the away prompt hands off "I was doing something else".
    func presentRetroactive(minutes: Int) {
        present(mode: .retroactive)
        state?.minutesAgo = max(1, min(720, minutes))
    }

    func present(mode: PromptMode = .immediate) {
        store.reload()

        let state = PromptState(mode: mode)
        self.state = state
        installKeyMonitor(state)

        // Read the scale once per presentation so the window rect and the
        // SwiftUI content cannot disagree about how big the prompt is.
        let metrics = PromptMetrics()

        let view = PromptView(
            state: state,
            suggestions: store.suggestions,
            currentTask: store.summary.currentTask,
            onSubmit: { [weak self] text, minutesAgo in
                if let minutesAgo, minutesAgo > 0 {
                    self?.store.backlog(minutes: minutesAgo, task: text)
                } else {
                    self?.store.log(text)
                }
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() },
            metrics: metrics
        )

        // No .nonactivatingPanel: this panel is meant to take key focus so
        // typing lands in it immediately. A nonactivating panel never
        // becomes key, which leaves the caret in whatever app was in front.
        // .borderless, NOT .titled: a titled window keeps an
        // NSTitlebarContainerView 32pt tall at the top of its frame even
        // with the titlebar hidden, transparent and its separator style set
        // to .none. Two things go wrong with it. The hosting controller's
        // fittingSize comes back 32pt taller than the SwiftUI content
        // (measured: 336 vs 304), so the window ends up that much taller
        // than what is drawn -- and the chrome's own edge renders as a thin
        // dark line floating above the prompt, inset at each end by the
        // window's corner radius. Borderless has no chrome, so the frame and
        // the content agree exactly. Key focus and drag-to-move both survive
        // it: PromptPanel overrides canBecomeKey, and
        // isMovableByWindowBackground does not need a titlebar.
        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: metrics.width, height: metrics.fieldHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
        // Settle on the content's real size first. Positioning while the
        // hosting controller still reports its initial (near-zero) fitting
        // size centres the wrong geometry, and the window then grows out
        // from that origin -- visibly off centre.
        panel.layoutIfNeeded()
        if let content = panel.contentViewController?.view {
            let size = content.fittingSize
            if size.width > 1, size.height > 1 {
                panel.setContentSize(size)
            }
        }

        positionNearTop(panel)
        pinnedTopY = panel.frame.maxY
        pinnedCenterX = panel.frame.midX
        panel.delegate = self
        self.panel = panel
        hasBecomeKey = false

        // Accessory apps must activate explicitly or the panel comes up
        // visible but unfocused.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
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
        rememberPosition()
        removeKeyMonitor()
        state = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        hasBecomeKey = false
        pinnedTopY = nil
        pinnedCenterX = nil
    }

    /// Keep the top edge and the horizontal centre where they started as the
    /// panel grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let top = pinnedTopY, let centerX = pinnedCenterX else { return }
        let frame = panel.frame
        let origin = NSPoint(x: centerX - frame.width / 2, y: top - frame.height)
        if abs(origin.x - frame.origin.x) > 0.5 || abs(origin.y - frame.origin.y) > 0.5 {
            setOrigin(origin, on: panel)
        }
        // A transparent window's drop shadow is cached against the previous
        // frame, so it has to be invalidated whenever the panel resizes.
        panel.invalidateShadow()
    }

    /// A drag moves the prompt, so the anchors the resize handler holds to
    /// have to move with it -- otherwise typing (which grows the suggestion
    /// list) would snap the panel back to where it was first opened.
    func windowDidMove(_ notification: Notification) {
        guard !isRepositioning, let panel else { return }
        pinnedTopY = panel.frame.maxY
        pinnedCenterX = panel.frame.midX
        rememberPosition()
    }

    /// Every programmatic move goes through here so windowDidMove can tell
    /// it apart from a drag.
    private func setOrigin(_ origin: NSPoint, on panel: NSWindow) {
        isRepositioning = true
        panel.setFrameOrigin(origin)
        isRepositioning = false
    }

    private func rememberPosition() {
        guard Preferences.rememberPromptPosition, let panel, panel.isVisible else { return }
        Preferences.promptPosition = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
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

    /// Restores where the prompt was last left, falling back to the default
    /// near-top placement.
    private func positionNearTop(_ panel: NSPanel) {
        if Preferences.rememberPromptPosition,
           let saved = Preferences.promptPosition,
           let origin = restoredOrigin(for: panel, savedTopLeft: saved) {
            setOrigin(origin, on: panel)
            return
        }
        setOrigin(defaultOrigin(for: panel), on: panel)
    }

    /// Validates a remembered spot against the CURRENT display layout.
    ///
    /// A saved point can easily be somewhere that no longer exists -- an
    /// external monitor was unplugged, the resolution changed, the display
    /// arrangement moved. Nudge it back onto whichever screen it overlaps,
    /// and give up (returning nil for the default placement) only when it
    /// lands on no screen at all.
    private func restoredOrigin(for panel: NSPanel, savedTopLeft: CGPoint) -> NSPoint? {
        let size = panel.frame.size
        let proposed = NSRect(x: savedTopLeft.x, y: savedTopLeft.y - size.height,
                              width: size.width, height: size.height)

        // Prefer the screen holding the panel's top-left corner; otherwise
        // any screen it still overlaps at all.
        let screen = NSScreen.screens.first { NSPointInRect(savedTopLeft, $0.frame) }
            ?? NSScreen.screens.first { $0.frame.intersects(proposed) }
        guard let screen else { return nil }

        return Self.clamped(proposed, into: screen.visibleFrame)
    }

    /// Nudges a frame fully inside `bounds`, bottom-left origin.
    ///
    /// Pure and static so the arithmetic can be reasoned about on its own.
    /// The outer max() on each axis matters: a panel LARGER than the screen
    /// makes `bounds.maxX - size.width` fall below `bounds.minX`, and
    /// clamping into an inverted range would push the window off the far
    /// edge instead of the near one. Oversized panels stay pinned to the
    /// bottom-left of the visible area and overflow outward.
    static func clamped(_ frame: NSRect, into bounds: NSRect) -> NSPoint {
        let maxX = max(bounds.minX, bounds.maxX - frame.width)
        let maxY = max(bounds.minY, bounds.maxY - frame.height)
        return NSPoint(x: min(max(frame.minX, bounds.minX), maxX),
                       y: min(max(frame.minY, bounds.minY), maxY))
    }

    private func defaultOrigin(for panel: NSPanel) -> NSPoint {
        // Prefer the screen the pointer is on, so the prompt appears where
        // the user is looking on a multi-monitor setup.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else {
            return NSPoint(x: panel.frame.minX, y: panel.frame.minY)
        }
        let frame = panel.frame
        return NSPoint(x: screen.frame.midX - frame.width / 2,
                       y: screen.frame.midY + screen.frame.height * 0.12)
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
    var fontSize: CGFloat = 22
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMove: (Move) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .light)
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
        if nsView.font?.pointSize != fontSize {
            nsView.font = .systemFont(ofSize: fontSize, weight: .light)
        }
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

// ======================================================================
// PROMPT METRICS
// ======================================================================
/// Every size in the capture prompt derives from one user-set scale. The
/// baseline numbers are the values that were hard-coded before this became
/// adjustable, so a scale of 1.0 renders exactly as it always did.
struct PromptMetrics {
    let scale: CGFloat

    init(scale: CGFloat? = nil) {
        self.scale = scale ?? CGFloat(Preferences.promptTextScale)
    }

    private func s(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }

    // Layout
    var width: CGFloat { s(560) }
    var fieldHeight: CGFloat { s(74) }
    var horizontalPadding: CGFloat { s(18) }
    var rowVerticalPadding: CGFloat { s(7) }
    var rowSpacing: CGFloat { s(8) }
    var listVerticalPadding: CGFloat { s(6) }
    var hintVerticalPadding: CGFloat { s(6) }
    var retroVerticalPadding: CGFloat { s(9) }
    var fieldSpacing: CGFloat { s(12) }
    var iconColumnWidth: CGFloat { s(14) }
    var cornerRadius: CGFloat { s(12) }

    // Type. Semantic styles (.caption/.callout) cannot be scaled, so these
    // are the point sizes those styles resolve to at the default scale.
    var fieldFontSize: CGFloat { s(22) }
    var leadingIconSize: CGFloat { s(20) }
    var rowIconSize: CGFloat { s(11) }
    var rowFontSize: CGFloat { s(13) }
    var keyFontSize: CGFloat { s(11) }
    var detailFontSize: CGFloat { s(11) }
    var hintFontSize: CGFloat { s(11) }
    var calloutFontSize: CGFloat { s(13) }
}

struct PromptView: View {
    @ObservedObject var state: PromptState
    let suggestions: [Suggestion]
    let currentTask: String?
    /// (task, minutesAgo). minutesAgo is nil for an immediate entry.
    let onSubmit: (String, Int?) -> Void
    let onCancel: () -> Void
    var metrics = PromptMetrics()

    @State private var text: String = ""
    @State private var selection: Int = -1

    private static let presets = [5, 15, 30, 60]

    /// Recent tasks and assigned Jira issues, filtered by what is typed.
    private var matches: [Suggestion] {
        let q = text.trimmingCharacters(in: .whitespaces)
        let pool = suggestions.filter { $0.taskText.lowercased() != q.lowercased() }
        return Array(pool.filter { $0.matches(q) }.prefix(6))
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
            HStack(spacing: metrics.fieldSpacing) {
                Image(systemName: isRetroactive ? "clock.arrow.circlepath" : "clock")
                    .font(.system(size: metrics.leadingIconSize, weight: .light))
                    .foregroundStyle(isRetroactive ? Color.accentColor : .secondary)

                PromptTextField(
                    text: $text,
                    placeholder: placeholder,
                    fontSize: metrics.fieldFontSize,
                    onSubmit: submit,
                    onCancel: onCancel,
                    onMove: move
                )
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.fieldHeight)

            if isRetroactive { retroactiveRow }

            if !matches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                        HStack(spacing: metrics.rowSpacing) {
                            Image(systemName: match.kind == .jira
                                  ? "ticket" : "arrow.uturn.backward")
                                .font(.system(size: metrics.rowIconSize))
                                .foregroundStyle(match.kind == .jira
                                                 ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(.tertiary))
                                .frame(width: metrics.iconColumnWidth)

                            if let key = match.key {
                                Text(key)
                                    .font(.system(size: metrics.keyFontSize, design: .monospaced))
                                    .bold()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(match.taskText.dropFirst(key.count).trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: metrics.rowFontSize))
                                    .lineLimit(1)
                            } else {
                                Text(match.taskText)
                                    .font(.system(size: metrics.rowFontSize))
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let detail = match.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: metrics.detailFontSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.vertical, metrics.rowVerticalPadding)
                        .background(index == selection ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { onSubmit(match.taskText, isRetroactive ? minutesAgo : nil) }
                    }
                }
                .padding(.vertical, metrics.listVerticalPadding)
            }

            hint
        }
        .frame(width: metrics.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
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
                    .font(.system(size: metrics.calloutFontSize, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: metrics.calloutFontSize))
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.retroVerticalPadding)
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
            .font(.system(size: metrics.hintFontSize))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.hintVerticalPadding)
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
        let value = (selection >= 0 && selection < matches.count)
            ? matches[selection].taskText
            : text
        onSubmit(value, isRetroactive ? minutesAgo : nil)
    }
}
