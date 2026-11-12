import Foundation

// ======================================================================
// READ PATH
// ======================================================================
// The app parses the markdown directly for display. This is the only
// logic duplicated from Python, and it is deliberately the trivial half:
// reading. Every WRITE still goes through the `jott` CLI so the
// write-cached report engine stays single-source.
//
// Mirrors storage.parse_log + storage.calculate_daily_durations.

/// Task names that mean "not billable" -- kept identical to the Python.
let breakKeywords: Set<String> = ["stop", "break", "end"]

func isBreakTask(_ message: String) -> Bool {
    breakKeywords.contains(message.trimmingCharacters(in: .whitespaces).lowercased())
}

/// Consecutive pairs closer together than the minimum entry length.
/// Mirrors storage.short_gaps: breaks are exempt on BOTH sides, so the
/// rule only ever governs a direct switch between two real tasks.
///
/// `entries` must be chronological. Returns the index of the EARLIER
/// entry of each offending pair, with the gap in seconds.
func shortGaps(_ entries: [(time: String, message: String)],
               minSeconds: Int = JottConfig.minEntrySeconds()) -> [(index: Int, gap: Int)] {
    guard minSeconds > 0 else { return [] }
    var out: [(index: Int, gap: Int)] = []
    for i in 0..<max(0, entries.count - 1) {
        let (t1, m1) = entries[i]
        let (t2, m2) = entries[i + 1]
        if isBreakTask(m1) || isBreakTask(m2) { continue }
        guard let s1 = Ledger.seconds(from: t1), let s2 = Ledger.seconds(from: t2) else { continue }
        if s2 - s1 < minSeconds { out.append((i, s2 - s1)) }
    }
    return out
}

struct LedgerEntry {
    var time: String        // HH:MM:SS
    var message: String
    var seconds: Int        // seconds since midnight, for arithmetic
    var isBreak: Bool { breakKeywords.contains(message.lowercased()) }
}

struct LedgerRow: Identifiable {
    var id: Int             // 1-based, matches the ID column in the markdown table
    var start: String
    var end: String
    var duration: TimeInterval
    var task: String
    var isBreak: Bool
    var isActive: Bool
}

struct DaySummary {
    var rows: [LedgerRow] = []
    var total: TimeInterval = 0
    var entries: [LedgerEntry] = []

    /// The entry currently being tracked, or nil when stopped / nothing logged.
    var currentTask: String? {
        guard let last = entries.last, !last.isBreak else { return nil }
        return last.message
    }

    /// How long the current task has been running.
    var currentElapsed: TimeInterval? {
        guard let last = entries.last, !last.isBreak else { return nil }
        return max(0, Date().secondsSinceMidnight - Double(last.seconds))
    }

    var isOnBreak: Bool {
        guard let last = entries.last else { return false }
        return last.isBreak
    }

    /// Distinct task names, most recent first -- feeds prompt autocomplete.
    var recentTasks: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries.reversed() where !e.isBreak {
            let key = e.message.lowercased()
            if seen.insert(key).inserted { out.append(e.message) }
        }
        return out
    }
}

enum Ledger {
    /// Reads `- HH:MM:SS | task` lines, ignoring the generated summary table.
    static func parse(path: String) -> [LedgerEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var entries: [LedgerEntry] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("- ") else { continue }
            let body = line.dropFirst(2)
            guard let sep = body.range(of: " | ") else { continue }
            let time = String(body[body.startIndex..<sep.lowerBound])
            let message = String(body[sep.upperBound...])
            guard let secs = seconds(from: time) else { continue }
            entries.append(LedgerEntry(time: time, message: message, seconds: secs))
        }
        entries.sort { $0.time < $1.time }
        return entries
    }

    /// Walks the timeline pairing each entry against the next one's start.
    /// Breaks are excluded from the billable total, matching the CLI.
    static func summarize(entries: [LedgerEntry], isToday: Bool) -> DaySummary {
        var summary = DaySummary()
        summary.entries = entries
        let nowSecs = Date().secondsSinceMidnight

        for (i, entry) in entries.enumerated() {
            var endStr = "-"
            var duration: TimeInterval = 0
            let isLast = (i == entries.count - 1)

            if !isLast {
                endStr = entries[i + 1].time
                duration = TimeInterval(entries[i + 1].seconds - entry.seconds)
            } else if !entry.isBreak && isToday {
                // Live delta for the row still running.
                endStr = Self.clockString(nowSecs)
                duration = max(0, nowSecs - Double(entry.seconds))
            }

            if !entry.isBreak { summary.total += duration }

            summary.rows.append(LedgerRow(
                id: i + 1,
                start: entry.time,
                end: endStr,
                duration: duration,
                task: entry.message,
                isBreak: entry.isBreak,
                isActive: isToday && isLast && !entry.isBreak
            ))
        }
        return summary
    }

    static func today() -> DaySummary {
        let path = JottConfig.filePath(for: Date())
        return summarize(entries: parse(path: path), isToday: true)
    }

    /// Range-checked to match Python's strptime("%H:%M:%S"), which rejects
    /// values like 25:00:00 or 12:60:00. Keeping these in step matters: the
    /// editor gates its Save button on this, and a looser check here would
    /// let the CLI reject the save with a confusing error instead.
    static func seconds(from hhmmss: String) -> Int? {
        let parts = hhmmss.split(separator: ":")
        guard parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(s)
        else { return nil }
        return h * 3600 + m * 60 + s
    }

    static func clockString(_ secs: TimeInterval) -> String {
        let t = Int(secs)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

extension Date {
    var secondsSinceMidnight: TimeInterval {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: self)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        return TimeInterval(hour * 3600 + minute * 60 + second)
    }
}

/// '2h 15m' / '45m' -- matches helpers.format_duration.
func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

/// 'Wednesday, August 26th, 2026' -- matches helpers.get_ordinal_date.
func ordinalDateString(_ date: Date) -> String {
    let day = Calendar.current.component(.day, from: date)
    let suffix: String
    switch day {
    case 11, 12, 13: suffix = "th"
    default:
        switch day % 10 {
        case 1: suffix = "st"
        case 2: suffix = "nd"
        case 3: suffix = "rd"
        default: suffix = "th"
        }
    }
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMMM"
    let weekdayMonth = f.string(from: date)
    f.dateFormat = "yyyy"
    return "\(weekdayMonth) \(day)\(suffix), \(f.string(from: date))"
}

// ======================================================================
// WEEKLY AGGREGATION
// ======================================================================
// Mirrors commands.show_weekly_summary: Monday-anchored week, per-day
// billable totals, and a per-day task rollup that preserves the order
// tasks first appeared and excludes breaks.

struct WeekDay: Identifiable {
    var id: String { dateString }
    var date: Date
    var dateString: String
    var dayName: String
    var summary: DaySummary
    var taskTotals: [(task: String, total: TimeInterval)]
    var isToday: Bool
    var hasEntries: Bool { !summary.entries.isEmpty }
}

struct WeekSummary {
    var monday: Date
    var days: [WeekDay] = []
    var grandTotal: TimeInterval = 0
}

extension Ledger {
    static func summary(for date: Date) -> DaySummary {
        let path = JottConfig.filePath(for: date)
        let isToday = Calendar.current.isDateInToday(date)
        return summarize(entries: parse(path: path), isToday: isToday)
    }

    /// Monday of the week containing `date`. Calendar.weekday is 1=Sunday,
    /// so it is shifted to Python's Monday=0 convention first.
    static func monday(of date: Date) -> Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        let mondayOffset = (weekday + 5) % 7
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: -mondayOffset, to: start) ?? start
    }

    /// `weeksAgo: 0` is the current week, `1` the previous one.
    static func week(weeksAgo: Int) -> WeekSummary {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: -7 * weeksAgo, to: Date()) ?? Date()
        let mon = monday(of: base)

        var week = WeekSummary(monday: mon)
        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "EEEE"
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyy-MM-dd"

        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: mon) else { continue }
            let daySummary = summary(for: day)
            week.grandTotal += daySummary.total

            // Aggregate by task name, first-appearance order, breaks excluded.
            var totals: [String: TimeInterval] = [:]
            var order: [String] = []
            for row in daySummary.rows where !row.isBreak {
                if totals[row.task] == nil {
                    totals[row.task] = 0
                    order.append(row.task)
                }
                totals[row.task, default: 0] += row.duration
            }

            week.days.append(WeekDay(
                date: day,
                dateString: stampFormatter.string(from: day),
                dayName: nameFormatter.string(from: day),
                summary: daySummary,
                taskTotals: order.map { ($0, totals[$0] ?? 0) },
                isToday: cal.isDateInToday(day)
            ))
        }
        return week
    }
}

// ======================================================================
// TICKET PIVOT
// ======================================================================
// The weekly timesheet is transcribed into the client's system ticket by
// ticket, not day by day -- so the same ticket touched on four days is
// one row with four numbers, and the thing you actually copy is the row
// total. This turns the day-major `WeekSummary` into that ticket-major
// grid.
//
// Task text carries the classification already, because that is what the
// prompt writes:
//
//     SKYALYNE-322 PR Review      -> ticket SKYALYNE-322, project SKYALYNE
//     General Internal - Tech Share -> non-billable, group "General Internal"
//
// Anything matching neither shape is grouped under "Other" rather than
// dropped: unclassified time you can still see is a prompt you will fix,
// time that vanished is one you never notice.

struct TicketIdentity {
    var group: String
    var title: String
    /// The ticket key, or "Internal" for non-billable rows.
    var subtitle: String
    var isBillable: Bool
    /// Stable per-row identity -- the ticket key where there is one, so two
    /// differently-worded entries for the same ticket collapse together.
    var key: String

    /// Matches a leading Jira key: uppercase project, hyphen, digits.
    private static let ticketPattern = try? NSRegularExpression(
        pattern: "^([A-Z][A-Z0-9]*)-([0-9]+)\\s+(.*)$"
    )

    static func parse(_ task: String) -> TicketIdentity {
        let trimmed = task.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        if let match = ticketPattern?.firstMatch(in: trimmed, range: range),
           let project = Range(match.range(at: 1), in: trimmed),
           let number = Range(match.range(at: 2), in: trimmed),
           let rest = Range(match.range(at: 3), in: trimmed) {
            let ticket = "\(trimmed[project])-\(trimmed[number])"
            let summary = trimmed[rest].trimmingCharacters(in: .whitespaces)
            return TicketIdentity(
                group: String(trimmed[project]),
                title: summary.isEmpty ? ticket : summary,
                subtitle: ticket,
                isBillable: true,
                key: ticket
            )
        }

        // "<something> - <something>" is the convention for non-ticket time.
        if let sep = trimmed.range(of: " - ") {
            let group = String(trimmed[trimmed.startIndex..<sep.lowerBound])
            let rest = String(trimmed[sep.upperBound...])
            return TicketIdentity(
                group: group,
                title: rest.isEmpty ? group : rest,
                subtitle: "Internal",
                isBillable: false,
                key: trimmed.lowercased()
            )
        }

        return TicketIdentity(
            group: "Other",
            title: trimmed,
            subtitle: "Uncategorised",
            isBillable: false,
            key: trimmed.lowercased()
        )
    }
}

struct TicketRow: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var isBillable: Bool
    /// One slot per day in the pivot. `nil` means the task was never logged
    /// that day; `0` means it was logged but earned no time -- a real and
    /// different thing, and the grid draws them differently.
    var days: [TimeInterval?]
    var total: TimeInterval
}

struct TicketGroup: Identifiable {
    var id: String
    var name: String
    var isBillable: Bool
    var rows: [TicketRow]
    var days: [TimeInterval?]
    var total: TimeInterval
}

struct WeekPivot {
    var groups: [TicketGroup] = []
    var days: [TimeInterval] = []
    var grandTotal: TimeInterval = 0
    /// Biggest single cell, so the heat tint has something to scale against.
    var maxCell: TimeInterval = 0
}

extension WeekSummary {
    /// `dayCount` is 5 for the working week, 7 with the weekend shown.
    func pivot(dayCount: Int) -> WeekPivot {
        var pivot = WeekPivot()
        pivot.days = Array(repeating: 0, count: dayCount)

        // group name -> row key -> row under construction
        var groups: [String: (billable: Bool, order: Int, rows: [String: TicketRow], order2: [String])] = [:]
        var groupOrder: [String] = []

        for (index, day) in days.prefix(dayCount).enumerated() {
            for item in day.taskTotals {
                let id = TicketIdentity.parse(item.task)

                if groups[id.group] == nil {
                    groups[id.group] = (id.isBillable, groupOrder.count, [:], [])
                    groupOrder.append(id.group)
                }
                if groups[id.group]!.rows[id.key] == nil {
                    groups[id.group]!.rows[id.key] = TicketRow(
                        id: "\(id.group)/\(id.key)",
                        title: id.title,
                        subtitle: id.subtitle,
                        isBillable: id.isBillable,
                        days: Array(repeating: nil, count: dayCount),
                        total: 0
                    )
                    groups[id.group]!.order2.append(id.key)
                }
                groups[id.group]!.rows[id.key]!.days[index] =
                    (groups[id.group]!.rows[id.key]!.days[index] ?? 0) + item.total
                groups[id.group]!.rows[id.key]!.total += item.total

                pivot.days[index] += item.total
                pivot.grandTotal += item.total
            }
        }

        for name in groupOrder {
            guard let bucket = groups[name] else { continue }
            var rows = bucket.order2.compactMap { bucket.rows[$0] }
            rows.sort { $0.total > $1.total }

            var dayTotals: [TimeInterval?] = Array(repeating: nil, count: dayCount)
            for row in rows {
                for (i, value) in row.days.enumerated() where value != nil {
                    dayTotals[i] = (dayTotals[i] ?? 0) + (value ?? 0)
                }
                pivot.maxCell = max(pivot.maxCell, row.days.compactMap { $0 }.max() ?? 0)
            }

            pivot.groups.append(TicketGroup(
                id: name,
                name: name,
                isBillable: bucket.billable,
                rows: rows,
                days: dayTotals,
                total: rows.reduce(0) { $0 + $1.total }
            ))
        }

        // Billable work first, then the heaviest group -- the order you
        // actually fill the timesheet in.
        pivot.groups.sort {
            $0.isBillable == $1.isBillable ? $0.total > $1.total : $0.isBillable
        }
        return pivot
    }
}

// ======================================================================
// DAY INDEX
// ======================================================================
// Mirrors storage.iter_log_dates: walk LOG_BASE_DIR/YYYY/MM/*.md rather
// than keeping an index, because the files on disk ARE the index and
// anything cached would go stale the moment the CLI wrote a day.

extension Ledger {
    /// One entry per day that has a ledger, newest first.
    static func availableDates(limit: Int = 400) -> [Date] {
        let base = JottConfig.logBaseDir()
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"

        guard let years = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var out: [Date] = []

        for year in years {
            let yearPath = (base as NSString).appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath) else { continue }
            for month in months {
                let monthPath = (yearPath as NSString).appendingPathComponent(month)
                guard let files = try? fm.contentsOfDirectory(atPath: monthPath) else { continue }
                for file in files where file.hasSuffix(".md") {
                    if let date = stamp.date(from: String(file.dropLast(3))) {
                        out.append(date)
                    }
                }
            }
        }
        return Array(out.sorted(by: >).prefix(limit))
    }
}
