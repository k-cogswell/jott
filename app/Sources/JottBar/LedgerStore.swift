import Foundation
import Combine

// ======================================================================
// OBSERVABLE STATE
// ======================================================================
// Single source of truth for the UI. Polls the on-disk ledger on a short
// timer, which does double duty: it advances the live elapsed counter and
// picks up entries logged from the terminal.
//
// A 2s stat() is cheap and has no re-arming edge cases around the
// YYYY/MM directory rolling over at month boundaries. If the latency ever
// becomes noticeable, swap `tick()` for an FSEvents stream on the day's
// directory -- the rest of the app is unaffected.
@MainActor
final class LedgerStore: ObservableObject {
    /// Shared instance so the SwiftUI scene and the AppDelegate (which owns
    /// the hotkey and the panel) operate on the same state.
    static let shared = LedgerStore()

    @Published private(set) var summary = DaySummary()
    @Published private(set) var lastMessage: String?
    @Published private(set) var jira = JiraBridge.Snapshot()

    private var timer: Timer?
    private var jiraTimer: Timer?
    private var lastSignature: String = ""

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Jira is refreshed on a slow cadence; the CLI's own 15 minute cache
        // means most of these calls never touch the network.
        refreshJira()
        jiraTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshJira() }
        }
    }

    /// Fetches assigned issues off the main thread. Failures are held in the
    /// snapshot rather than surfaced as alerts -- Jira is optional, and a
    /// broken connection must never block logging time.
    func refreshJira(force: Bool = false) {
        Task.detached {
            let snapshot = JiraBridge.issues(refresh: force)
            await MainActor.run { self.jira = snapshot }
        }
    }

    /// Recent tasks first (most likely to repeat), then assigned issues that
    /// are not already represented by a recent entry.
    var suggestions: [Suggestion] {
        var out = summary.recentTasks.map {
            Suggestion(kind: .recent, taskText: $0, key: nil, detail: nil)
        }
        let seen = Set(out.map { $0.taskText.lowercased() })
        for issue in jira.issues where !seen.contains(issue.taskText.lowercased()) {
            out.append(Suggestion(kind: .jira, taskText: issue.taskText,
                                  key: issue.key, detail: issue.status))
        }
        return out
    }

    /// Reload only when the file actually changed, but always recompute
    /// so the running task's elapsed time keeps advancing.
    private func tick() {
        let path = JottConfig.filePath(for: Date())
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        let signature = "\(path)|\(mtime)|\(size)"

        if signature != lastSignature {
            lastSignature = signature
            reload()
        } else if summary.currentTask != nil {
            summary = Ledger.today()
        }
    }

    func reload() {
        summary = Ledger.today()
    }

    // -- Mutations. All of these delegate to the CLI, then refresh. --

    func log(_ task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply({ JottCLI.log(trimmed) }, confirm: { after in
            .started(task: trimmed,
                     at: after.startClock(of: trimmed) ?? "now",
                     closing: after.justClosedRow)
        })
    }

    func stop() {
        apply({ JottCLI.stop() }, confirm: { after in
            .stopped(closing: after.justClosedRow, dayTotal: after.total)
        })
    }

    /// Logs a task that actually started `minutes` ago.
    func backlog(minutes: Int, task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, minutes > 0 else { return }
        apply({ JottCLI.backlog(minutes: minutes, task: trimmed) }, confirm: { after in
            // The away prompt closes a task as `backlog <n> stop`, so this
            // path has to be able to report a stop as well as a start.
            if breakKeywords.contains(trimmed.lowercased()) {
                return .stopped(closing: after.justClosedRow, dayTotal: after.total)
            }
            return .backdated(task: trimmed,
                              at: after.startClock(of: trimmed) ?? "earlier",
                              minutesAgo: minutes)
        })
    }

    func continueLast() {
        apply({ JottCLI.continueLast() }, confirm: { after in
            guard let task = after.currentTask else {
                return .failure("Nothing to continue yet today.")
            }
            return .started(task: task,
                            at: after.startClock(of: task) ?? "now",
                            closing: after.justClosedRow)
        })
    }

    /// `confirm` builds the HUD text from the ledger as it stands AFTER the
    /// write, so the confirmation reports what actually landed on disk
    /// rather than what we asked for.
    private func apply(_ action: @escaping () -> JottCLI.Result,
                       confirm: @escaping (DaySummary) -> ToastContent) {
        Task.detached {
            let result = action()
            await MainActor.run {
                self.lastMessage = result.output
                self.reload()
                // The CLI refuses some commands ("No tasks logged yet today
                // to continue") on a zero exit status, so the text has to be
                // checked as well as the status.
                let failed = !result.succeeded
                    || result.output.lowercased().hasPrefix("error")
                ToastController.shared.show(failed ? .failure(result.output)
                                                   : confirm(self.summary))
            }
        }
    }

    /// Menubar title: the running task and how long it has been running.
    var statusTitle: String {
        if let task = summary.currentTask, let elapsed = summary.currentElapsed {
            let clipped = task.count > 28 ? String(task.prefix(27)) + "…" : task
            return "\(clipped) · \(formatDuration(elapsed))"
        }
        if summary.isOnBreak { return "Stopped" }
        return "Not tracking"
    }
}
