import AppKit
import SwiftUI

// ======================================================================
// CONFIRMATION HUD
// ======================================================================
// The capture prompt closes the instant Return is pressed, which left
// nothing on screen saying what had actually been recorded. This is that
// acknowledgement: a banner in the top-right corner where Notification
// Center puts its own, gone again a few seconds later.
//
// Deliberately not a user notification. Notification Center needs a
// permission grant, is swallowed by Focus modes, and can trail the
// keystroke by a second or more -- none of which works for feedback whose
// whole job is to close the loop on a keypress. `Notifier` still owns the
// background nudges, where reaching the user *outside* the app is the point.

struct ToastContent {
    var symbol: String
    var title: String
    var detail: String?
    var isError = false
}

// -- Composers, one per mutation, so the wording lives in one place. --

extension ToastContent {
    /// `closing` is the row this entry just ended, when there was one --
    /// seeing how long the last thing ran is half the reassurance.
    static func started(task: String, at clock: String, closing: LedgerRow?) -> ToastContent {
        var detail = "Started \(clock)"
        if let closing {
            detail += " · \(closing.task) ran \(formatDuration(closing.duration))"
        }
        return ToastContent(symbol: "record.circle", title: task, detail: detail)
    }

    static func backdated(task: String, at clock: String, minutesAgo: Int) -> ToastContent {
        ToastContent(symbol: "clock.arrow.circlepath",
                     title: task,
                     detail: "Started \(clock) · \(minutesAgo)m ago")
    }

    static func stopped(closing: LedgerRow?, dayTotal: TimeInterval) -> ToastContent {
        var parts: [String] = []
        if let closing { parts.append("\(closing.task) ran \(formatDuration(closing.duration))") }
        parts.append("\(formatDuration(dayTotal)) logged today")
        return ToastContent(symbol: "stop.circle",
                            title: "Stopped",
                            detail: parts.joined(separator: " · "))
    }

    static func failure(_ message: String) -> ToastContent {
        ToastContent(symbol: "exclamationmark.triangle.fill",
                     title: "Nothing logged",
                     detail: message.isEmpty ? "The jott CLI reported an error." : message,
                     isError: true)
    }
}

extension DaySummary {
    /// The row the newest entry closed out: the one before the last, when
    /// it was real work rather than a break.
    var justClosedRow: LedgerRow? {
        guard let row = rows.dropLast().last, !row.isBreak else { return nil }
        return row
    }

    /// HH:MM of the most recent entry naming `task`. Read back from the
    /// ledger rather than recomputed, so a backdated entry reports the
    /// timestamp that actually landed on disk.
    func startClock(of task: String) -> String? {
        guard let entry = entries.last(where: { $0.message == task }) else { return nil }
        return String(entry.time.prefix(5))
    }
}

// ----------------------------------------------------------------------

@MainActor
final class ToastController {
    static let shared = ToastController()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    /// Roughly what a real notification banner gets. Longer than a HUD under
    /// the cursor would need, since the corner is somewhere the user has to
    /// look over at deliberately.
    private static let dwell: TimeInterval = 3.2
    /// Errors say something went wrong and are worth reading twice.
    private static let errorDwell: TimeInterval = 5.5
    private static let fade: TimeInterval = 0.22
    /// Inset from the top-right of the visible frame -- matched to the gap
    /// Notification Center leaves, so the two do not look misaligned when
    /// one of the background nudges is on screen at the same time.
    private static let margin: CGFloat = 14
    /// How far right of its resting place the banner starts, so it slides in
    /// from the screen edge rather than simply appearing.
    private static let slide: CGFloat = 24

    func show(_ content: ToastContent) {
        // Rebuild rather than re-use: the panel is sized to its content, and
        // a fresh one sidesteps re-measuring a HUD whose text changed shape.
        hide(animated: false)

        let metrics = PromptMetrics()
        let host = NSHostingController(rootView: ToastView(content: content, metrics: metrics))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: metrics.toastWidth, height: metrics.fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Pure feedback: it must never take key focus (the user is typing in
        // whatever app the prompt returned them to) and never swallow a click.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        panel.layoutIfNeeded()
        let size = host.view.fittingSize
        if size.width > 1, size.height > 1 { panel.setContentSize(size) }

        let resting = restingFrame(for: panel.frame.size)
        panel.setFrame(resting.offsetBy(dx: Self.slide, dy: 0), display: false)
        panel.invalidateShadow()

        panel.alphaValue = 0
        // orderFrontRegardless, not makeKeyAndOrderFront: this app is an
        // accessory and is usually inactive by the time the banner appears.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(resting, display: true)
        }
        self.panel = panel

        let dwell = content.isError ? Self.errorDwell : Self.dwell
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide(animated: true) }
        }
    }

    func hide(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        // Back out the way it came in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: Self.slide, dy: 0),
                                      display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Top-right of the screen, inset by `margin`.
    ///
    /// `visibleFrame` rather than `frame`: it already excludes the menu bar,
    /// so the banner tucks under it the way a real notification does, and it
    /// stays correct on a display that has no menu bar of its own.
    private func restingFrame(for size: NSSize) -> NSRect {
        guard let screen = targetScreen() else {
            return NSRect(origin: .zero, size: size)
        }
        let area = screen.visibleFrame
        return NSRect(x: area.maxX - size.width - Self.margin,
                      y: area.maxY - size.height - Self.margin,
                      width: size.width,
                      height: size.height)
    }

    /// The display the user is actually looking at -- the one under the
    /// pointer, matching where the capture prompt opens by default. Falls
    /// back to the menu bar display.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

}

// ----------------------------------------------------------------------

private struct ToastView: View {
    let content: ToastContent
    let metrics: PromptMetrics

    var body: some View {
        HStack(spacing: metrics.rowSpacing + 4) {
            Image(systemName: content.symbol)
                .font(.system(size: metrics.leadingIconSize * 0.85, weight: .regular))
                .foregroundStyle(content.isError
                                 ? AnyShapeStyle(Color.red)
                                 : AnyShapeStyle(Color.accentColor))
                .frame(width: metrics.leadingIconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: metrics.calloutFontSize, weight: .medium))
                    .lineLimit(1)
                if let detail = content.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: metrics.detailFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.retroVerticalPadding + 2)
        .frame(width: metrics.toastWidth, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
    }
}
