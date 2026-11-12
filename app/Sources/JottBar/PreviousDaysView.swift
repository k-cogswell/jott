import SwiftUI

// ======================================================================
// PREVIOUS DAYS
// ======================================================================
// Every past day with a ledger, and the same editor used for today.
//
// Today is deliberately absent from the list. It has its own page, and
// two editors open on one day would each hold their own unsaved copy --
// whichever saved second would silently discard the other's work.

struct PreviousDaysView: View {
    @EnvironmentObject var store: LedgerStore

    struct DayEntry: Identifiable {
        var id: String
        var date: Date
        var total: TimeInterval
        var entryCount: Int
        var isUnclosed: Bool
    }

    @State private var days: [DayEntry] = []
    @State private var selected: Date?
    @State private var loading = true

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            dayList
            Rectangle().fill(Theme.hairline).frame(width: 1)
            editor
        }
        .background(Theme.surface)
        .task(id: store.summary.entries.count) { await reload() }
    }

    // ----- List --------------------------------------------------------

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Previous days")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if !loading {
                    Text("\(days.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 12)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if days.isEmpty {
                Text("No earlier days logged yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(days) { day in
                            dayRow(day)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 248)
        .background(Theme.surfaceMuted.opacity(0.5))
    }

    private func dayRow(_ day: DayEntry) -> some View {
        let isSelected = selected.map { Self.stamp.string(from: $0) == day.id } ?? false
        return Button {
            selected = day.date
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekdayLabel(day.date))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                    HStack(spacing: 5) {
                        Text(day.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                        if day.isUnclosed {
                            // storage.is_unclosed: the day's final entry is
                            // a task rather than a break, so its last stretch
                            // counts as zero. Worth flagging where you can
                            // actually go and fix it.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Spacer(minLength: 6)
                Text(day.total > 0 ? formatDuration(day.total) : "–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(day.total > 0 ? Theme.primaryText : Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isSelected ? Theme.accent.opacity(0.12) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Theme.accent : .clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ----- Editor ------------------------------------------------------

    @ViewBuilder
    private var editor: some View {
        if let selected {
            // .id forces a fresh editor per day, so switching days cannot
            // carry one day's unsaved edits into another's ledger.
            LogEditorView(date: selected, showsBrand: false, onSaved: { Task { await reload() } })
                .id(Self.stamp.string(from: selected))
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("Pick a day")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Choose a date on the left to view or edit it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ----- Data --------------------------------------------------------

    /// Parses every ledger to get its total. Off the main actor: this is
    /// a few hundred small file reads, and it runs again after each save.
    private func reload() async {
        let today = Calendar.current.startOfDay(for: Date())
        let entries: [DayEntry] = await Task.detached {
            Ledger.availableDates()
                .filter { Calendar.current.startOfDay(for: $0) < today }
                .map { date in
                    let summary = Ledger.summarize(
                        entries: Ledger.parse(path: JottConfig.filePath(for: date)),
                        isToday: false
                    )
                    let last = summary.entries.last
                    return DayEntry(
                        id: Self.stamp.string(from: date),
                        date: date,
                        total: summary.total,
                        entryCount: summary.entries.count,
                        isUnclosed: last.map { !$0.isBreak } ?? false
                    )
                }
        }.value

        days = entries
        loading = false
        if selected == nil { selected = entries.first?.date }
    }

    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
}
