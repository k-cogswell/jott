import SwiftUI
import AppKit

// ======================================================================
// DASHBOARD
// ======================================================================
// The landing page: what today looks like so far, what last week added
// up to, and a field to switch tasks without opening the capture prompt.
// Everything here is read from the same `LedgerStore` the menubar uses,
// and every write goes through it too -- no new paths to the CLI.

struct DashboardView: View {
    @ObservedObject var selection: MainTabSelection
    @EnvironmentObject var store: LedgerStore

    @State private var draft = ""
    /// Last week is parsed from disk, which is a dozen file reads. Held in
    /// state and refreshed on appear rather than recomputed every redraw --
    /// the store ticks every 2 seconds.
    @State private var lastWeek = WeekPivot()
    /// Width of the page, so the layout can reflow rather than squeeze.
    @State private var width: CGFloat = 0

    /// Below this the three stat cards stop fitting side by side without
    /// their own contents wrapping mid-word.
    private var isNarrow: Bool { width > 0 && width < 780 }

    private var today: DaySummary { store.summary }

    /// Entries worth drawing. A zero-duration row has no width on a
    /// proportional strip and would render as an invisible sliver.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statCards
                todayCard
                switchTaskCard
            }
            .padding(.horizontal, 30)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(Theme.surface)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, new in
                    width = new
                }
            }
        )
        .onAppear { lastWeek = Ledger.week(weeksAgo: 1).pivot(dayCount: 7) }
    }

    // ----- Header ----------------------------------------------------

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text(longDate())
                    .font(.system(size: isNarrow ? 28 : 36, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Without this the button -- which cannot compress, its padding
            // being fixed -- took the width it wanted and the date was left
            // wrapping one letter per line.
            .layoutPriority(1)

            Spacer(minLength: 16)
            Button { selection.tab = .today } label: {
                Text("Edit today's log")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    // ----- Stat cards -------------------------------------------------

    @ViewBuilder
    private var statCards: some View {
        // Side by side while there is room, stacked once there is not.
        // Three cards across a 700pt page left each one ~210pt, which is
        // where "Last week by project" started wrapping mid-word.
        if isNarrow {
            VStack(spacing: 14) {
                loggedTodayCard
                lastWeekByProjectCard
                lastWeekTotalCard
            }
        } else {
            HStack(alignment: .top, spacing: 18) {
                loggedTodayCard
                lastWeekByProjectCard
                lastWeekTotalCard
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loggedTodayCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Logged today")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text(formatDuration(today.total))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(entriesSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lastWeekByProjectCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last week by project")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if lastWeek.groups.isEmpty {
                    Text("Nothing logged last week.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    ForEach(lastWeek.groups.prefix(3)) { group in
                        projectBar(group)
                    }
                }
            }
        }
    }

    private var lastWeekTotalCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last week")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text(formatDuration(lastWeek.grandTotal))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Button { selection.tab = .week } label: {
                    Text("Open weekly view →")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func projectBar(_ group: TicketGroup) -> some View {
        let fraction = lastWeek.groups.first.map { $0.total > 0 ? group.total / $0.total : 0 } ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(group.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(formatDuration(group.total))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceMuted)
                    Capsule()
                        .fill(group.isBillable ? Theme.accent : Theme.slate)
                        // A floor so a 10-minute project is still a visible
                        // mark rather than nothing at all.
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }

    private var entriesSummary: String {
        guard let first = today.entries.first else { return "Nothing logged yet" }
        let count = today.entries.count
        return "\(count) \(count == 1 ? "entry" : "entries") since \(String(first.time.prefix(5)))"
    }

    // ----- Today so far -----------------------------------------------

    private var todayCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Today so far")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button { selection.tab = .today } label: {
                        Text("Open day editor →")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }

                if today.entries.isEmpty {
                    Text("Nothing logged yet today.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                } else {
                    // The same view the day editor draws, read-only and at
                    // the condensed scale. A whole day at the editor's
                    // 120pt-per-hour would be ~1000pt tall inside a card,
                    // so it scrolls, and opens scrolled to now.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            DayTimeline(
                                items: timelineItems,
                                isToday: true,
                                now: Date().secondsSinceMidnight,
                                hourHeight: TimelineGeometry.compactHourHeight,
                                selection: nil
                            )
                            .id("timeline")
                            .overlay(alignment: .bottom) {
                                Color.clear.frame(height: 1).id("now")
                            }
                        }
                        .frame(maxHeight: 360)
                        .onAppear { proxy.scrollTo("now", anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// Today's ledger as timeline input. The id has to be stable across
    /// redraws or the list churns, so it is derived from the entry rather
    /// than generated.
    private var timelineItems: [DayTimelineItem] {
        today.entries.map {
            DayTimelineItem(id: "\($0.time)|\($0.message)", time: $0.time, task: $0.message)
        }
    }

    // ----- Switch task -------------------------------------------------

    private var switchTaskCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Switch task")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)

                HStack(spacing: 12) {
                    TaskSuggestionField(
                        text: $draft,
                        placeholder: "Search tickets or type a task…",
                        capsuleShape: true,
                        onCommit: { task in
                            draft = task
                            start()
                        }
                    )

                    Button(action: start) {
                        Text("Start")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.onInk)
                            .padding(.horizontal, 26).padding(.vertical, 12)
                            .background(Capsule().fill(Theme.ink.opacity(draft.isEmpty ? 0.4 : 1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !suggestions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(suggestions.prefix(isNarrow ? 2 : 3), id: \.self) { task in
                            chip(task)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// Today's distinct tasks, minus whatever is already running -- you do
    /// not need a shortcut back to where you already are.
    private var suggestions: [String] {
        today.recentTasks
            .filter { $0 != today.currentTask }
            .prefix(3)
            .map { $0 }
    }

    private func chip(_ task: String) -> some View {
        let identity = TicketIdentity.parse(task)
        return Button { store.log(task) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(identity.isBillable ? Theme.accent : Theme.slate)
                    .frame(width: 7, height: 7)
                Text(task)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Theme.surfaceMuted))
        }
        .buttonStyle(.plain)
    }

    private func start() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.log(trimmed)
        draft = ""
    }

    // ----- Shared card chrome -------------------------------------------

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }

    private func longDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}
