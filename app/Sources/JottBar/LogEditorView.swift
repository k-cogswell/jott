import SwiftUI
import AppKit

// ======================================================================
// IN-APP LEDGER EDITOR
// ======================================================================
// Today's entries as a proportional timeline rather than a list of rows.
// The point of the shape: an entry's duration is the gap to the NEXT
// entry, which a table states but a timeline shows -- a 3-minute entry
// wedged between two long ones is obvious here and invisible in a list.
//
// Saving pipes the whole set through `jott rewrite`, so the CLI still
// owns file layout and summary-table regeneration -- the app never
// writes a ledger itself.

struct EditableEntry: Identifiable, Equatable {
    let id: UUID
    var time: String
    var task: String

    init(id: UUID = UUID(), time: String, task: String) {
        self.id = id
        self.time = time
        self.task = task
    }

    var timeIsValid: Bool { Ledger.seconds(from: time) != nil }
    var taskIsValid: Bool { !task.trimmingCharacters(in: .whitespaces).isEmpty }
    var isValid: Bool { timeIsValid && taskIsValid }
    var isBreak: Bool { breakKeywords.contains(task.trimmingCharacters(in: .whitespaces).lowercased()) }

    var line: String { "\(time) | \(task.trimmingCharacters(in: .whitespaces))" }
}

/// One entry placed on the timeline: where it starts, where it ends, and
/// how tall that makes it.
private enum Timeline {
    static let inspectorWidth: CGFloat = 320
}


struct LogEditorView: View {
    /// The day being edited. Defaults to today; the Previous days page
    /// passes an older one. Everything date-dependent hangs off this --
    /// which ledger is read, which date `jott rewrite` is given, and
    /// whether there is a "now" on the timeline at all.
    var date: Date = Date()
    /// False when hosted inside the main window's shell, which supplies
    /// the branding -- the date and totals stay either way.
    var showsBrand: Bool = true
    /// Called after a successful write, so a list of days showing totals
    /// can refresh rather than go stale.
    var onSaved: (() -> Void)?

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    @EnvironmentObject var store: LedgerStore

    @State private var entries: [EditableEntry] = []
    @State private var original: [EditableEntry] = []
    @State private var selection: String?
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var saving = false
    @State private var now = Date().secondsSinceMidnight
    /// Page width, so the inspector can move below the timeline rather
    /// than squeezing it to nothing.
    @State private var width: CGFloat = 0

    private var isNarrow: Bool { width > 0 && width < 820 }

    private var isDirty: Bool { entries != original }
    private var allValid: Bool { entries.allSatisfy(\.isValid) }
    private var canSave: Bool {
        isDirty && allValid && !saving && gapCheck.introduced.isEmpty
    }

    // ----- Minimum entry length ---------------------------------------
    // Mirrors what `jott rewrite` will do, so the Save button can explain
    // the refusal before you press it rather than after. A day that was
    // ALREADY short stays saveable -- otherwise every historical day with
    // a two-minute entry would become uneditable -- but it may not gain
    // new ones, so violations are diffed against the loaded state.

    private struct GapCheck {
        /// Earlier entry of each offending pair -> the gap, in seconds.
        var offending: [String: Int] = [:]
        /// Those that were not already there when the day was loaded.
        var introduced: Set<String> = []
    }

    private var minEntrySeconds: Int { JottConfig.minEntrySeconds() }

    private var gapCheck: GapCheck {
        func scan(_ list: [EditableEntry]) -> [(id: String, key: String, gap: Int)] {
            let sorted = list.filter(\.timeIsValid).sorted { $0.time < $1.time }
            let pairs = sorted.map { (time: $0.time, message: $0.task) }
            return shortGaps(pairs, minSeconds: minEntrySeconds).map {
                (sorted[$0.index].id.uuidString,
                 "\(sorted[$0.index].time)|\(sorted[$0.index + 1].time)",
                 $0.gap)
            }
        }

        let current = scan(entries)
        let before = Set(scan(original).map(\.key))

        var check = GapCheck()
        for item in current {
            check.offending[item.id] = item.gap
            if !before.contains(item.key) { check.introduced.insert(item.id) }
        }
        return check
    }

    private var minimumLabel: String {
        let minutes = minEntrySeconds / 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    // ----- Derived timeline -------------------------------------------
    // The drawing, placement and scale rules live in DayTimeline, which
    // the dashboard shares. This view owns only the editing state.

    /// Current edits as timeline input, so moving a start time updates
    /// every neighbour's duration before anything touches disk.
    private var timelineItems: [DayTimelineItem] {
        entries.filter(\.timeIsValid).map {
            DayTimelineItem(id: $0.id.uuidString, time: $0.time, task: $0.task)
        }
    }

    private var timeline: DayTimeline {
        DayTimeline(
            items: timelineItems,
            isToday: isToday,
            now: now,
            hourHeight: TimelineGeometry.editorHourHeight,
            selection: $selection,
            offending: gapCheck.offending
        )
    }

    /// Entries whose time will not parse. They cannot be placed on a
    /// timeline, but losing sight of them would be worse -- they get a
    /// strip of their own below it.
    private var unplaceable: [EditableEntry] {
        entries.filter { !$0.timeIsValid }
    }

    private var totalLogged: TimeInterval {
        timeline.blocks.filter { !$0.item.isBreak }.reduce(0) { $0 + $1.duration }
    }

    private var selectedEntry: EditableEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id.uuidString == selection }
    }

    private var selectedBlock: TimelineBlock? {
        guard let selection else { return nil }
        return timeline.blocks.first { $0.id == selection }
    }


    // ----- Body --------------------------------------------------------

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                Group {
                    if isNarrow {
                        VStack(alignment: .leading, spacing: 18) {
                            dayHeader
                            inspector
                            timelineCard
                            if !unplaceable.isEmpty { unplaceableStrip }
                            legend
                        }
                    } else {
                        HStack(alignment: .top, spacing: 22) {
                            VStack(alignment: .leading, spacing: 0) {
                                dayHeader
                                timelineCard
                                if !unplaceable.isEmpty { unplaceableStrip }
                                legend
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            inspector
                                .frame(width: Timeline.inspectorWidth)
                                .padding(.top, 58)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width, initial: true) { _, new in
                        width = new
                    }
                }
            )

            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .background(Theme.surface)
        .onAppear(perform: load)
        .task {
            // Keeps the now-line and the running block's duration moving.
            // A `.task` rather than a Timer publisher: it is cancelled with
            // the view instead of outliving re-inits of this struct.
            while !Task.isCancelled {
                now = Date().secondsSinceMidnight
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // ----- Chrome ------------------------------------------------------

    private var topBar: some View {
        HStack(spacing: 10) {
            if showsBrand {
                BrandMark(size: 30, cornerRadius: 6)
                Text("Jott").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(isToday ? "Today's log" : "Day log").font(.system(size: 16))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(longDateString())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                HStack(spacing: 5) {
                    Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") ·")
                        .foregroundStyle(Theme.secondaryText)
                    Text(formatDuration(totalLogged))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                    Text("logged").foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isToday ? "Your day" : longDateString())
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 16)
            Button(action: addEntry) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.surfaceMuted))
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    Text("Add entry at")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .fixedSize()
                    Text(shortClock(Int(newEntrySeconds)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // ----- Timeline ----------------------------------------------------

    private var timelineCard: some View { timeline }


    private var legend: some View {
        Text(isToday
             ? "Select a block to edit it. The red line is now; gaps between blocks are untracked time."
             : "Select a block to edit it. Gaps between blocks are untracked time.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .padding(.top, 12)
    }

    private var unplaceableStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEEDS A VALID TIME")
                .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                .foregroundStyle(Theme.accent)
            ForEach(unplaceable) { entry in
                HStack(spacing: 10) {
                    Text(entry.time.isEmpty ? "(empty)" : entry.time)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(entry.task.isEmpty ? "Untitled entry" : entry.task)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.08)))
                .contentShape(Rectangle())
                .onTapGesture { selection = entry.id.uuidString }
            }
        }
        .padding(.top, 14)
    }

    // ----- Inspector ---------------------------------------------------

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let entry = selectedEntry, let index = entries.firstIndex(where: { $0.id == entry.id }) {
                HStack {
                    Text("Edit entry")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    if selectedBlock?.isRunning == true { runningBadge }
                }

                field("Task") {
                    // No onCommit: this field edits a row in place, and
                    // the change lands with Save like every other edit.
                    TaskSuggestionField(
                        text: Binding(
                            get: { entries[index].task },
                            set: { entries[index].task = $0 }
                        ),
                        placeholder: "What are you working on?"
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    field("Start") {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                TextField("HH:MM:SS", text: Binding(
                                    get: { entries[index].time },
                                    set: { entries[index].time = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(inputBackground(valid: entries[index].timeIsValid))

                            Text(entries[index].timeIsValid
                                 ? twelveHour(Ledger.seconds(from: entries[index].time) ?? 0)
                                 : "Use HH:MM:SS")
                                .font(.system(size: 10))
                                .foregroundStyle(entries[index].timeIsValid ? Theme.secondaryText : Theme.accent)
                        }
                    }

                    // Read-only on purpose: an entry has no stored end. It
                    // ends when the next one starts, so the way to change
                    // this number is to move the next entry.
                    field("End") {
                        Text(endDescription)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.surfaceMuted)
                            )
                    }
                }

                Text("An entry ends when the next one starts — move the next entry to change this.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)

                Rectangle().fill(Theme.hairline).frame(height: 1)

                HStack {
                    Text("Duration")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text(selectedBlock.map { $0.duration > 0 ? formatDuration($0.duration) : "–" } ?? "–")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                }

                Button {
                    delete(entry)
                } label: {
                    Text("Delete entry")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(entries.isEmpty
                     ? "Nothing logged today yet. Add an entry to get started."
                     : "Select a block on the left to edit its task or start time.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private var runningBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
            Text("Running")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.accent.opacity(0.14)))
    }

    private var endDescription: String {
        guard let block = selectedBlock else { return "–" }
        return block.isRunning ? "Now (\(shortClock(Int(now))))" : shortClock(block.endSeconds)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputBackground(valid: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(valid ? Theme.hairline : Theme.accent, lineWidth: 1)
            )
    }

    // ----- Footer ------------------------------------------------------

    private var footer: some View {
        HStack(spacing: 12) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
            } else if !gapCheck.introduced.isEmpty {
                Label("Entries must be at least \(minimumLabel). Lengthen the dashed blocks to save.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            } else if !gapCheck.offending.isEmpty {
                Label("Some entries are under \(minimumLabel) (dashed). They were already "
                      + "that short, so saving keeps them.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            } else if let noticeMessage {
                Label(noticeMessage, systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            } else if !allValid {
                Label("Every entry needs a valid time and a task before saving",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            }

            Spacer()

            Button { load() } label: {
                Text("Revert")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDirty && !saving ? Theme.primaryText : Theme.tertiaryText)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(
                        Capsule().stroke(Theme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isDirty || saving)

            Button { save() } label: {
                Text(saving ? "Saving…" : "Save changes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.accent.opacity(canSave ? 1 : 0.45)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // ----- Actions -----------------------------------------------------

    private func load() {
        // Today comes from the store so it stays live while the editor is
        // open; any other day is read straight from disk.
        let source: [LedgerEntry]
        if isToday {
            store.reload()
            source = store.summary.entries
        } else {
            source = Ledger.parse(path: JottConfig.filePath(for: date))
        }
        let loaded = source.map {
            EditableEntry(time: $0.time, task: $0.message)
        }
        entries = loaded
        original = loaded
        errorMessage = nil
        noticeMessage = nil
        now = Date().secondsSinceMidnight
        if let selection, !loaded.contains(where: { $0.id.uuidString == selection }) {
            self.selection = nil
        }
    }

    private func addEntry() {
        let entry = EditableEntry(time: Ledger.clockString(newEntrySeconds), task: "")
        entries.append(entry)
        selection = entry.id.uuidString
    }

    /// Today: now, which is what you want when adding something you forgot
    /// to log as it happened. A past day has no "now", so it goes a legal
    /// gap after the last entry instead -- landing on a timestamp the
    /// minimum-length rule will accept rather than one it refuses.
    private var newEntrySeconds: TimeInterval {
        if isToday { return Date().secondsSinceMidnight }
        let last = entries.filter(\.timeIsValid)
            .compactMap { Ledger.seconds(from: $0.time) }
            .max()
        guard let last else { return 9 * 3600 }
        return TimeInterval(min(last + max(minEntrySeconds, 60), 23 * 3600 + 59 * 60))
    }

    private func delete(_ entry: EditableEntry) {
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id.uuidString { selection = nil }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        errorMessage = nil

        let lines = entries
            .sorted { $0.time < $1.time }
            .map(\.line)

        let stamp = Self.stampFormatter.string(from: date)
        Task.detached {
            let result = JottCLI.rewrite(lines: lines, date: stamp)
            await MainActor.run {
                saving = false
                if result.succeeded {
                    // The CLI warns about short entries it kept; that is
                    // worth repeating here, since the save looked silent.
                    let warnings = result.output
                        .components(separatedBy: .newlines)
                        .filter { $0.hasPrefix("Warning:") }
                    if isToday { store.reload() }
                    load()
                    onSaved?()
                    if !warnings.isEmpty {
                        noticeMessage = "Saved. \(warnings.count) entr\(warnings.count == 1 ? "y" : "ies") under \(minimumLabel) kept."
                    }
                } else {
                    // The CLI validates before writing, so a failure here
                    // means nothing on disk changed.
                    errorMessage = result.output.isEmpty ? "Save failed." : result.output
                }
            }
        }
    }

    // ----- Formatting --------------------------------------------------

    private func shortClock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    private func twelveHour(_ seconds: Int) -> String {
        let h24 = seconds / 3600
        let minute = (seconds % 3600) / 60
        let suffix = h24 < 12 ? "AM" : "PM"
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return String(format: "%d:%02d %@", h12, minute, suffix)
    }

    private func longDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    /// yyyy-MM-dd, the form `jott rewrite` takes.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
