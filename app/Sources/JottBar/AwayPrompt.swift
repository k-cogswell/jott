import AppKit
import SwiftUI

// ======================================================================
// "YOU WERE AWAY" PROMPT
// ======================================================================
// Shown on return from an idle or sleep gap while a task was running.
// Closing the task is expressed as `jott backlog <minutes> stop`, so the
// stop entry lands at the moment you actually walked away rather than the
// moment you came back -- and the write still goes through the CLI.
@MainActor
final class AwayPromptController: NSObject, NSWindowDelegate {
    static let shared = AwayPromptController()

    private var panel: PromptPanel?
    private var hasBecomeKey = false

    /// Opens the normal capture prompt in retroactive mode.
    var onLogSomethingElse: ((Int) -> Void)?

    func present(awayStart: Date, duration: TimeInterval, task: String) {
        dismiss()

        let minutesAway = max(1, Int(duration / 60))
        let stopClock = Self.clock(awayStart)

        let view = AwayPromptView(
            task: task,
            awayDuration: duration,
            stopAtClock: stopClock,
            onStop: { [weak self] in
                // Backdate the stop to when the machine went quiet.
                LedgerStore.shared.backlog(minutes: minutesAway, task: "stop")
                self?.dismiss()
            },
            onKeep: { [weak self] in self?.dismiss() },
            onLogOther: { [weak self] in
                self?.dismiss()
                self?.onLogSomethingElse?(minutesAway)
            }
        )

        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.center()

        self.panel = panel
        hasBecomeKey = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        hasBecomeKey = false
    }

    func windowDidBecomeKey(_ notification: Notification) { hasBecomeKey = true }

    /// Unlike the capture prompt this does NOT close on losing focus -- it is
    /// asking about time already elapsed, and dismissing it by accident means
    /// silently losing that time again.
    func windowDidResignKey(_ notification: Notification) {}

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct AwayPromptView: View {
    let task: String
    let awayDuration: TimeInterval
    let stopAtClock: String
    let onStop: () -> Void
    let onKeep: () -> Void
    let onLogOther: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You were away for \(formatDuration(awayDuration))")
                        .font(.headline)
                    Text("“\(task)” kept running while you were gone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            VStack(spacing: 8) {
                Button {
                    onStop()
                } label: {
                    HStack {
                        Text("Stop tracking at \(stopAtClock)")
                        Spacer()
                        Text("recommended").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 8) {
                    Button("Keep the time") { onKeep() }
                        .frame(maxWidth: .infinity)
                    Button("I was doing something else…") { onLogOther() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
