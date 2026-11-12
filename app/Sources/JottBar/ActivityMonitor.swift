import AppKit
import Foundation

// ======================================================================
// IDLE DETECTION & NUDGES
// ======================================================================
// Exists to fix a silent data loss in the ledger format: a day's final
// entry has no following timestamp to measure against, so if you walk away
// without logging a stop, that block counts as zero once the day rolls
// over. Catching the walk-away is the only reliable moment to fix it.
//
// Two independent signals are watched, because neither alone is enough:
//   * HID idle time, for sitting at an unlocked machine doing nothing.
//   * Wall-clock gaps between polls, for sleep/lid-close, where the timer
//     simply stops firing and HID idle resets on wake.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    private var timer: Timer?
    private var lastPoll = Date()
    private var awayStart: Date?

    /// Suppresses repeat nudges for a task we have already asked about.
    private var lastNudgeAt: Date?
    private var lastNudgedTask: String?

    /// (awayStart, seconds away)
    var onReturnFromAway: ((Date, TimeInterval) -> Void)?

    private static let pollInterval: TimeInterval = 15

    private init() {}

    func start() {
        timer?.invalidate()
        lastPoll = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }

        // Sleep and wake are observed directly as well: on some hardware the
        // timer resumes before HID idle has caught up.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markAwayStart() }
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markAwayStart() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // ------------------------------------------------------------------

    /// Seconds since the last input event of any kind.
    private func currentIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func markAwayStart() {
        if awayStart == nil { awayStart = Date() }
    }

    private func poll() {
        let now = Date()
        let gap = now.timeIntervalSince(lastPoll)
        lastPoll = now

        // The timer missed several cycles, so the machine was asleep.
        if gap > Self.pollInterval * 3 {
            let start = awayStart ?? now.addingTimeInterval(-gap)
            awayStart = nil
            finishAway(start: start, end: now)
            return
        }

        let threshold = TimeInterval(Preferences.idleThresholdMinutes * 60)
        let idle = currentIdleSeconds()

        if threshold > 0 && idle >= threshold {
            if awayStart == nil { awayStart = now.addingTimeInterval(-idle) }
        } else if let start = awayStart, idle < threshold {
            awayStart = nil
            // The away period ended when input resumed, not now.
            finishAway(start: start, end: now.addingTimeInterval(-idle))
        }

        checkNudge()
    }

    private func finishAway(start: Date, end: Date) {
        let duration = end.timeIntervalSince(start)
        let threshold = TimeInterval(Preferences.idleThresholdMinutes * 60)
        guard threshold > 0, duration >= threshold else { return }
        // Only worth asking if something was actually being tracked.
        guard LedgerStore.shared.summary.currentTask != nil else { return }
        onReturnFromAway?(start, duration)
    }

    // ------------------------------------------------------------------

    /// "Still working?" -- catches the opposite failure: heads-down all
    /// afternoon on something that was never logged.
    private func checkNudge() {
        let minutes = Preferences.nudgeIntervalMinutes
        guard minutes > 0 else { return }
        guard let task = LedgerStore.shared.summary.currentTask,
              let elapsed = LedgerStore.shared.summary.currentElapsed else { return }
        guard elapsed >= TimeInterval(minutes * 60) else { return }

        // Don't nag: once per interval, and reset when the task changes.
        if lastNudgedTask != task {
            lastNudgedTask = task
            lastNudgeAt = nil
        }
        if let last = lastNudgeAt, Date().timeIntervalSince(last) < TimeInterval(minutes * 60) {
            return
        }
        lastNudgeAt = Date()

        Notifier.post("Still on \"\(task)\"? Running for \(formatDuration(elapsed)).")
    }
}
