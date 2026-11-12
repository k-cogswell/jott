import SwiftUI
import AppKit

// ======================================================================
// IN-APP LEDGER EDITOR
// ======================================================================
// Edits today's entries as structured rows rather than raw markdown.
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

    var line: String { "\(time) | \(task.trimmingCharacters(in: .whitespaces))" }
}

@MainActor
final class LogEditorWindow {
    static let shared = LogEditorWindow()
    private var window: NSWindow?

    func show(store: LedgerStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Today's Log"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.contentView = NSHostingView(rootView: LogEditorView().environmentObject(store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct LogEditorView: View {
    @EnvironmentObject var store: LedgerStore

    @State private var entries: [EditableEntry] = []
    @State private var original: [EditableEntry] = []
    @State private var errorMessage: String?
    @State private var saving = false

    private var isDirty: Bool { entries != original }
    private var allValid: Bool { entries.allSatisfy(\.isValid) }
    private var canSave: Bool { isDirty && allValid && !saving }

    /// Recomputed from the CURRENT edits so durations update as you type,
    /// before anything is written to disk.
    private var preview: DaySummary {
        let ledgerEntries = entries
            .compactMap { e -> LedgerEntry? in
                guard e.isValid, let secs = Ledger.seconds(from: e.time) else { return nil }
                return LedgerEntry(time: e.time, message: e.task, seconds: secs)
            }
            .sorted { $0.time < $1.time }
        return Ledger.summarize(entries: ledgerEntries, isToday: true)
    }

    private func duration(for entry: EditableEntry) -> String {
        guard entry.isValid,
              let row = preview.rows.first(where: { $0.start == entry.time && $0.task == entry.task })
        else { return "–" }
        return row.duration > 0 ? formatDuration(row.duration) : "–"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeaders
            Divider()
            rows
            Divider()
            footer
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ordinalDateString(Date())).font(.headline)
                Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(preview.total))
                    .font(.title3).monospacedDigit()
                Text("logged today").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var columnHeaders: some View {
        HStack(spacing: 10) {
            Text("START").frame(width: 92, alignment: .leading)
            Text("TASK").frame(maxWidth: .infinity, alignment: .leading)
            Text("DURATION").frame(width: 74, alignment: .trailing)
            Color.clear.frame(width: 22)
        }
        .font(.caption).bold()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if entries.isEmpty {
                    Text("Nothing logged today yet.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                ForEach($entries) { $entry in
                    EntryRow(
                        entry: $entry,
                        durationText: duration(for: entry),
                        isBreak: breakKeywords.contains(entry.task.lowercased()),
                        onDelete: { delete(entry) }
                    )
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                addEntry()
            } label: {
                Label("Add Entry", systemImage: "plus")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if !allValid {
                Label("Fix highlighted rows before saving", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer()

            Button("Revert") { load() }
                .disabled(!isDirty || saving)

            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // ------------------------------------------------------------------

    private func load() {
        store.reload()
        let loaded = store.summary.entries.map {
            EditableEntry(time: $0.time, task: $0.message)
        }
        entries = loaded
        original = loaded
        errorMessage = nil
    }

    private func addEntry() {
        // Default to now, which is what you want when adding something you
        // forgot to log as it happened.
        let now = Ledger.clockString(Date().secondsSinceMidnight)
        entries.append(EditableEntry(time: now, task: ""))
    }

    private func delete(_ entry: EditableEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        errorMessage = nil

        let lines = entries
            .sorted { $0.time < $1.time }
            .map(\.line)

        Task.detached {
            let result = JottCLI.rewrite(lines: lines)
            await MainActor.run {
                saving = false
                if result.succeeded {
                    store.reload()
                    load()
                    LogEditorWindow.shared.close()
                } else {
                    // The CLI validates before writing, so a failure here
                    // means nothing on disk changed.
                    errorMessage = result.output.isEmpty ? "Save failed." : result.output
                }
            }
        }
    }
}

// ----------------------------------------------------------------------

private struct EntryRow: View {
    @Binding var entry: EditableEntry
    var durationText: String
    var isBreak: Bool
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("HH:MM:SS", text: $entry.time)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 92)
                .foregroundStyle(entry.timeIsValid ? Color.primary : Color.red)

            TextField("Task description", text: $entry.task)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(isBreak ? Color.secondary : Color.primary)

            Text(durationText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isBreak ? .tertiary : .secondary)
                .frame(width: 74, alignment: .trailing)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help("Delete this entry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }
}
