import SwiftUI

// ======================================================================
// DAY TIMELINE
// ======================================================================
// One day drawn to scale: an hour is `hourHeight` points, so a block's
// height is its duration. Shared by the day editor (interactive, tall)
// and the dashboard's "Today so far" card (read-only, condensed), which
// is the whole reason it lives here rather than inside the editor --
// the placement rules below are fiddly enough that a second copy would
// drift within a week.

/// Neutral input, so callers can feed it either editable rows or parsed
/// ledger rows. `id` is a String rather than a UUID because the dashboard
/// has no stable identity to hand over -- it derives one from the entry.
struct DayTimelineItem: Identifiable {
    var id: String
    var time: String        // HH:MM:SS
    var task: String

    var isBreak: Bool { isBreakTask(task) }
}

struct TimelineBlock: Identifiable {
    var id: String
    var item: DayTimelineItem
    var startSeconds: Int
    var endSeconds: Int
    var duration: TimeInterval
    var endLabel: String
    var isRunning: Bool
}

/// A block resolved to real coordinates. The y position is not purely a
/// function of the start time: a run of very short entries would overlap
/// once the minimum height kicks in, so each is pushed below the one above.
struct BlockPlacement: Identifiable {
    var id: String { block.id }
    var block: TimelineBlock
    var y: CGFloat
    var height: CGFloat
    /// True when the floor pushed this block off its true time position.
    var isNudged: Bool

    enum Detail { case full, compact, bare }

    /// How much of the label fits. Under ~20pt there is room for a colour
    /// band and nothing else, and squeezing text in anyway just produced
    /// clipped glyphs.
    var detail: Detail {
        if height >= 46 { return .full }
        if height >= 20 { return .compact }
        return .bare
    }
}

enum TimelineGeometry {
    /// The editor's scale. At 76pt an hour a 9-minute entry fell under
    /// the minimum height and had to be nudged; 120 puts the floor at
    /// nine real minutes, which almost no entry is under.
    static let editorHourHeight: CGFloat = 120
    /// The dashboard shows a whole day inside a card, so it trades
    /// precision for fitting on screen.
    static let compactHourHeight: CGFloat = 64

    static let gutter: CGFloat = 64
    static let blockGap: CGFloat = 2

    /// Scales with the hour height, so the floor is always the same
    /// number of minutes rather than the same number of points.
    static func minBlockHeight(_ hourHeight: CGFloat) -> CGFloat {
        hourHeight * 0.15
    }
}

struct DayTimeline: View {
    var items: [DayTimelineItem]
    /// Drives the now-line and whether the last entry is still running.
    var isToday: Bool
    var now: TimeInterval
    var hourHeight: CGFloat = TimelineGeometry.editorHourHeight
    /// nil makes the timeline read-only: no hit testing, no highlight.
    var selection: Binding<String?>?
    /// Block id -> gap in seconds, for entries under the minimum length.
    var offending: [String: Int] = [:]

    private var isInteractive: Bool { selection != nil }

    // ----- Derivation ---------------------------------------------------

    var blocks: [TimelineBlock] {
        let placeable = items
            .filter { Ledger.seconds(from: $0.time) != nil }
            .sorted { $0.time < $1.time }

        let ledgerEntries = placeable.compactMap { item -> LedgerEntry? in
            guard let secs = Ledger.seconds(from: item.time) else { return nil }
            return LedgerEntry(time: item.time, message: item.task, seconds: secs)
        }
        let summary = Ledger.summarize(entries: ledgerEntries, isToday: isToday)

        return placeable.enumerated().map { index, item in
            let start = Ledger.seconds(from: item.time) ?? 0
            let row = index < summary.rows.count ? summary.rows[index] : nil
            let isLast = index == placeable.count - 1
            let running = isToday && isLast && !item.isBreak

            let end: Int
            if index + 1 < placeable.count {
                end = Ledger.seconds(from: placeable[index + 1].time) ?? start
            } else if running {
                end = max(start, Int(now))
            } else {
                end = start
            }

            return TimelineBlock(
                id: item.id,
                item: item,
                startSeconds: start,
                endSeconds: end,
                duration: row?.duration ?? 0,
                endLabel: running ? "now" : Self.shortClock(end),
                isRunning: running
            )
        }
    }

    /// Whole hours spanned, padded so the first and last blocks are not
    /// flush against the card edge.
    var hourRange: ClosedRange<Int> {
        var starts = blocks.map(\.startSeconds)
        var ends = blocks.map(\.endSeconds)
        if isToday {
            starts.append(Int(now))
            ends.append(Int(now))
        }
        let low = max(0, (starts.min() ?? 9 * 3600) / 3600 - 1)
        // At least four hours of context, so an empty or one-entry day
        // still looks like a day rather than a sliver.
        let high = min(24, max((ends.max() ?? 0) / 3600 + 2, low + 4))
        return low...high
    }

    var placements: [BlockPlacement] {
        let floor = TimelineGeometry.minBlockHeight(hourHeight)
        var out: [BlockPlacement] = []
        var cursor = -CGFloat.greatestFiniteMagnitude

        for block in blocks {
            let ideal = offset(for: block.startSeconds)
            let natural = CGFloat(block.endSeconds - block.startSeconds) / 3600 * hourHeight
            let height = max(floor, natural)
            let y = max(ideal, cursor)
            out.append(BlockPlacement(block: block, y: y, height: height,
                                      isNudged: y - ideal > 0.5))
            cursor = y + height + TimelineGeometry.blockGap
        }
        return out
    }

    var totalHeight: CGFloat {
        let grid = CGFloat(hourRange.upperBound - hourRange.lowerBound) * hourHeight
        // The cascade can run past the last hour line; the card has to
        // grow with it or the final block is clipped.
        let lowest = placements.map { $0.y + $0.height }.max() ?? 0
        return max(grid, lowest + 12)
    }

    func offset(for seconds: Int) -> CGFloat {
        (CGFloat(seconds) - CGFloat(hourRange.lowerBound * 3600)) / 3600 * hourHeight
    }

    // ----- Body -----------------------------------------------------------

    var body: some View {
        ZStack(alignment: .topLeading) {
            hourGrid
            ForEach(placements) { placement in
                blockView(placement)
                    .padding(.leading, TimelineGeometry.gutter + 8)
                    .padding(.trailing, 12)
                    .offset(y: placement.y)
            }
            if isToday { nowLine }
        }
        .frame(height: totalHeight, alignment: .topLeading)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selection?.wrappedValue = nil }
    }

    private var hourGrid: some View {
        ForEach(Array(hourRange), id: \.self) { hour in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.leading, TimelineGeometry.gutter)
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .offset(x: 14, y: -7)
            }
            .offset(y: offset(for: hour * 3600))
        }
    }

    @ViewBuilder
    private func blockView(_ placement: BlockPlacement) -> some View {
        let block = placement.block
        let selected = selection?.wrappedValue == block.id
        let identity = TicketIdentity.parse(block.item.task)
        let billable = identity.isBillable && !block.item.isBreak
        let title = block.item.task.isEmpty ? "Untitled entry" : block.item.task
        let range = "\(Self.shortClock(block.startSeconds)) – \(block.endLabel)"
        let tooShort = offending[block.id] != nil
        let durationText = block.duration > 0 ? formatDuration(block.duration) : "–"

        Group {
            switch placement.detail {
            case .bare:
                // No room for a label; the tooltip carries it.
                Color.clear
            case .compact:
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(block.item.task.isEmpty ? Theme.secondaryText : Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(durationText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .full:
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(block.item.task.isEmpty ? Theme.secondaryText : Theme.primaryText)
                            .lineLimit(1)
                        Text(range)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Text(durationText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: placement.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill(block, billable: billable))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    selected ? Theme.accent : (tooShort ? Theme.accent.opacity(0.7) : Theme.hairline),
                    style: StrokeStyle(lineWidth: selected ? 2 : 1,
                                       dash: tooShort && !selected ? [4, 3] : [])
                )
        )
        // A nudged block no longer sits exactly on its hour line, so the
        // tooltip carries the real time rather than letting the position
        // quietly misreport it.
        .help(placement.isNudged
              ? "\(title) · \(range) · \(durationText) (shown below its exact position)"
              : "\(title) · \(range) · \(durationText)")
        .contentShape(Rectangle())
        .allowsHitTesting(isInteractive)
        .onTapGesture { selection?.wrappedValue = block.id }
    }

    /// Breaks read as absence, not activity -- flat, no tint. Otherwise
    /// the same red/slate split the weekly grid uses, so a ticket looks
    /// like a ticket everywhere.
    private func fill(_ block: TimelineBlock, billable: Bool) -> Color {
        if block.item.isBreak { return Theme.surfaceMuted.opacity(0.6) }
        if block.isRunning { return Theme.accent.opacity(0.22) }
        return billable ? Theme.accent.opacity(0.10) : Theme.slate.opacity(0.14)
    }

    private var nowLine: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.accent).frame(height: 1.5)
                .padding(.leading, TimelineGeometry.gutter)
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                .offset(x: TimelineGeometry.gutter - 4)
        }
        .offset(y: offset(for: Int(now)))
    }

    static func shortClock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }
}
