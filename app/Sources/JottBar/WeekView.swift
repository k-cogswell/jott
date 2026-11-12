import SwiftUI
import AppKit

// ======================================================================
// WEEKLY TIMESHEET
// ======================================================================
// The grid you transcribe into OpenAir, without leaving the app. Read-only
// by design -- edits belong in the day editor, where a single day's
// chronology can be validated as a whole.

@MainActor
final class WeekWindow {
    static let shared = WeekWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Weekly Timesheet"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 360)
        window.contentView = NSHostingView(rootView: WeekView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct WeekView: View {
    @State private var weeksAgo = 0
    @State private var week = Ledger.week(weeksAgo: 0)
    @State private var expanded: Set<String> = []

    private var rangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let sunday = Calendar.current.date(byAdding: .day, value: 6, to: week.monday) ?? week.monday
        return "\(f.string(from: week.monday)) – \(f.string(from: sunday))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(week.days) { day in
                        dayRow(day)
                        Divider().opacity(0.4)
                    }
                }
            }
            Divider()
            footer
        }
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Button {
                weeksAgo += 1; reload()
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous week")

            VStack(spacing: 1) {
                Text(weeksAgo == 0 ? "This Week" : (weeksAgo == 1 ? "Last Week" : "\(weeksAgo) Weeks Ago"))
                    .font(.headline)
                Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                if weeksAgo > 0 { weeksAgo -= 1; reload() }
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(weeksAgo == 0)
                .help("Next week")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dayRow(_ day: WeekDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: expanded.contains(day.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(day.hasEntries ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 12)

                Text(day.dayName)
                    .frame(width: 90, alignment: .leading)
                    .fontWeight(day.isToday ? .semibold : .regular)

                Text(day.dateString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)

                if day.isToday {
                    Text("TODAY")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(day.hasEntries ? formatDuration(day.summary.total) : "–")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(day.hasEntries ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                guard day.hasEntries else { return }
                if expanded.contains(day.id) { expanded.remove(day.id) } else { expanded.insert(day.id) }
            }

            if expanded.contains(day.id) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(day.taskTotals.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(item.total > 0 ? formatDuration(item.total) : "–")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 56, alignment: .leading)
                            Text(item.task).lineLimit(1)
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 38)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }
        }
        .background(day.isToday ? Color.accentColor.opacity(0.05) : .clear)
    }

    private var footer: some View {
        HStack {
            Button {
                expanded = expanded.isEmpty
                    ? Set(week.days.filter(\.hasEntries).map(\.id))
                    : []
            } label: {
                Text(expanded.isEmpty ? "Expand All" : "Collapse All")
            }
            .buttonStyle(.borderless)

            Spacer()

            Text("Grand total")
                .font(.callout).foregroundStyle(.secondary)
            Text(week.grandTotal > 0 ? formatDuration(week.grandTotal) : "0m")
                .font(.title3).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func reload() {
        week = Ledger.week(weeksAgo: weeksAgo)
        expanded = []
    }
}
