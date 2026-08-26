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

    private var timer: Timer?
    private var lastSignature: String = ""

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
        apply { JottCLI.log(trimmed) }
    }

    func stop() { apply { JottCLI.stop() } }

    /// Logs a task that actually started `minutes` ago.
    func backlog(minutes: Int, task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, minutes > 0 else { return }
        apply { JottCLI.backlog(minutes: minutes, task: trimmed) }
    }

    func continueLast() { apply { JottCLI.continueLast() } }

    private func apply(_ action: @escaping () -> JottCLI.Result) {
        Task.detached {
            let result = action()
            await MainActor.run {
                self.lastMessage = result.output
                self.reload()
                Notifier.post(result.output)
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
