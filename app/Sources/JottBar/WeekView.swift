import SwiftUI
import AppKit

// ======================================================================
// WEEKLY TIMESHEET
// ======================================================================
// The grid you transcribe into the client's timesheet, without leaving
// the app. Ticket-major rather than day-major: the same ticket touched
// across four days is one row with four numbers and a row total, which
// is the number actually being copied. Read-only by design -- edits
// belong in the day editor, where a day's chronology is validated whole.

// ----------------------------------------------------------------------
// Layout constants. The header, every body row and the totals bar are
// separate views that must line up to the pixel, so the widths live in
// one place rather than being repeated three times.
// ----------------------------------------------------------------------
private enum Grid {
    static let ticketColumn: CGFloat = 250
    static let dayColumn: CGFloat = 96
    static let totalColumn: CGFloat = 84
    static let gutter: CGFloat = 14
    static let rowPadding: CGFloat = 16
}

struct WeekView: View {
    /// False when hosted inside the main window's shell, which supplies
    /// the branding -- the week controls stay either way.
    var showsBrand: Bool = true

    @State private var weeksAgo = 0
    @State private var week = Ledger.week(weeksAgo: 0)
    @State private var showWeekend = false
    @State private var copied = false
    @State private var appearance = Preferences.appearance

    private var dayCount: Int { showWeekend ? 7 : 5 }
    private var pivot: WeekPivot { week.pivot(dayCount: dayCount) }
    private var visibleDays: [WeekDay] { Array(week.days.prefix(dayCount)) }

    /// Exactly what one row occupies, so the horizontal scroll view knows
    /// when there is something to scroll.
    private var tableWidth: CGFloat {
        Grid.ticketColumn
            + Grid.dayColumn * CGFloat(dayCount)
            + Grid.totalColumn
            + Grid.gutter * CGFloat(dayCount + 1)
            + Grid.rowPadding * 2
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let last = Calendar.current.date(byAdding: .day, value: 6, to: week.monday) ?? week.monday
        let year = DateFormatter()
        year.dateFormat = "yyyy"
        return "\(f.string(from: week.monday)) – \(f.string(from: last)), \(year.string(from: last))"
    }

    private var weekLabel: String {
        switch weeksAgo {
        case 0: return "This week"
        case 1: return "Last week"
        default: return "\(weeksAgo) weeks ago"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    // The grid's columns are fixed widths -- they have to
                    // be, or the header, body and totals bar would drift
                    // out of alignment. So when the window is narrower
                    // than the grid, the grid scrolls sideways instead of
                    // overflowing the card.
                    ScrollView(.horizontal, showsIndicators: true) {
                        table.frame(minWidth: tableWidth, alignment: .leading)
                    }
                    legend
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.surface)
        .onAppear(perform: reload)
    }

    // ----- Chrome ----------------------------------------------------

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                if showsBrand {
                    BrandMark(size: 30, cornerRadius: 6)
                    Text("Jott").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Timesheet").font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                circleButton("chevron.left", enabled: true) { weeksAgo += 1; reload() }
                VStack(spacing: 1) {
                    Text(weekLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(rangeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(width: 160)
                circleButton("chevron.right", enabled: weeksAgo > 0) {
                    if weeksAgo > 0 { weeksAgo -= 1; reload() }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                appearanceButton
                Button(action: reload) {
                    Text("Refresh")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    /// Cycles system -> light -> dark. Three states is few enough that a
    /// cycling button beats a menu, and it is the control you reach for
    /// while looking at the thing whose theme you want changed.
    private var appearanceButton: some View {
        Button {
            appearance = appearance.next
            Theme.setAppearance(appearance)
        } label: {
            Image(systemName: appearance.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceMuted))
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Theme: \(appearance.label)")
    }

    private func circleButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primaryText : Theme.tertiaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceMuted))
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var titleBlock: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hours by ticket")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("The same ticket on different days lands on one row, ready to copy into the client timesheet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            HStack(spacing: 12) {
                Button {
                    showWeekend.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showWeekend ? "arrow.left" : "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.surfaceMuted))
                            .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                        Text(showWeekend ? "Hide weekend" : "Show weekend")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                .buttonStyle(.plain)

                Button(action: copyCSV) {
                    Text(copied ? "Copied" : "Copy as CSV")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(copied ? Theme.slate : Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    // ----- Table -----------------------------------------------------

    private var table: some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(pivot.groups) { group in
                groupRow(group)
                ForEach(group.rows) { row in
                    ticketRow(row, billable: group.isBillable)
                }
            }
            if pivot.groups.isEmpty { emptyState }
            totalsBar
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var columnHeader: some View {
        HStack(spacing: Grid.gutter) {
            Text("TICKET")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: Grid.ticketColumn, alignment: .leading)

            ForEach(Array(visibleDays.enumerated()), id: \.offset) { _, day in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(shortDayName(day))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(day.isToday ? Theme.accent : Theme.primaryText)
                    Text(shortDate(day))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(width: Grid.dayColumn, alignment: .trailing)
            }

            Text("TOTAL")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: Grid.totalColumn, alignment: .trailing)
        }
        .padding(.horizontal, Grid.rowPadding)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func groupRow(_ group: TicketGroup) -> some View {
        HStack(spacing: Grid.gutter) {
            HStack(spacing: 9) {
                Circle()
                    .fill(group.isBillable ? Theme.accent : Theme.slate)
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: Grid.ticketColumn, alignment: .leading)

            ForEach(Array(group.days.prefix(dayCount).enumerated()), id: \.offset) { _, value in
                Text(value.map(formatDuration) ?? "–")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(value == nil ? Theme.tertiaryText : Theme.secondaryText)
                    .frame(width: Grid.dayColumn, alignment: .trailing)
            }

            Text(formatDuration(group.total))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .frame(width: Grid.totalColumn, alignment: .trailing)
        }
        .padding(.horizontal, Grid.rowPadding)
        .padding(.vertical, 10)
        .background(Theme.surfaceMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func ticketRow(_ row: TicketRow, billable: Bool) -> some View {
        HStack(spacing: Grid.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1).truncationMode(.tail)
                Text(row.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: Grid.ticketColumn, alignment: .leading)
            .padding(.leading, 17)

            ForEach(Array(row.days.enumerated()), id: \.offset) { _, value in
                cell(value, billable: billable)
            }

            Text(formatDuration(row.total))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .frame(width: Grid.totalColumn, alignment: .trailing)
        }
        .padding(.horizontal, Grid.rowPadding)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Three states, deliberately distinct: nothing logged, logged but
    /// worth no time, and a real duration tinted by how big it is.
    @ViewBuilder
    private func cell(_ value: TimeInterval?, billable: Bool) -> some View {
        if let value {
            let fraction = pivot.maxCell > 0 ? value / pivot.maxCell : 0
            Text(value > 0 ? formatDuration(value) : "none")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value > 0 ? Theme.primaryText : Theme.secondaryText)
                .frame(width: Grid.dayColumn, height: 30)
                .background {
                    if value > 0 {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.heat(fraction, billable: billable))
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                Theme.tertiaryText,
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                    }
                }
        } else {
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: Grid.dayColumn, height: 30)
        }
    }

    private var totalsBar: some View {
        HStack(spacing: Grid.gutter) {
            Text("Day total")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onInk)
                .frame(width: Grid.ticketColumn, alignment: .leading)

            ForEach(Array(pivot.days.enumerated()), id: \.offset) { _, value in
                Text(value > 0 ? formatDuration(value) : "–")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: Grid.dayColumn, alignment: .trailing)
            }

            Text(formatDuration(pivot.grandTotal))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.onInk)
                .frame(width: Grid.totalColumn, alignment: .trailing)
        }
        .padding(.horizontal, Grid.rowPadding)
        .padding(.vertical, 14)
        .background(Theme.ink)
    }

    private var emptyState: some View {
        Text("Nothing logged this week.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    private var legend: some View {
        Text("Stronger tint means more time. A dashed cell is an entry with no time logged.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .padding(.top, 14)
    }

    // ----- Helpers ---------------------------------------------------

    private func shortDayName(_ day: WeekDay) -> String {
        String(day.dayName.prefix(3))
    }

    private func shortDate(_ day: WeekDay) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: day.date)
    }

    /// Row-per-ticket CSV, matching what is on screen -- including the
    /// weekend only when the weekend is being shown.
    private func copyCSV() {
        var lines: [String] = []
        lines.append((["Group", "Ticket", "Task"] + visibleDays.map(\.dateString) + ["Total"])
            .map(csvEscape).joined(separator: ","))
        for group in pivot.groups {
            for row in group.rows {
                let cells = row.days.map { $0.map { formatDuration($0) } ?? "" }
                lines.append(([group.name, row.subtitle, row.title] + cells + [formatDuration(row.total)])
                    .map(csvEscape).joined(separator: ","))
            }
        }
        lines.append((["", "", "Day total"] + pivot.days.map(formatDuration) + [formatDuration(pivot.grandTotal)])
            .map(csvEscape).joined(separator: ","))

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func csvEscape(_ field: String) -> String {
        field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
            : field
    }

    private func reload() {
        week = Ledger.week(weeksAgo: weeksAgo)
    }
}
