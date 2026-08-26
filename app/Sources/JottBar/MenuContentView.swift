import SwiftUI
import AppKit

// ======================================================================
// MENUBAR DROPDOWN
// ======================================================================
// The persistent-visible-state half: what you are on, for how long, and
// the day so far without opening a terminal.
struct MenuContentView: View {
    @EnvironmentObject var store: LedgerStore
    var onPerform: (HotKeyAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            todayList
            Divider()
            actions
        }
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let task = store.summary.currentTask, let elapsed = store.summary.currentElapsed {
                Text(task)
                    .font(.headline)
                    .lineLimit(2)
                Text("Running for \(formatDuration(elapsed))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if store.summary.isOnBreak {
                Text("Stopped").font(.headline)
                Text("Nothing is being tracked")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Not tracking").font(.headline)
                Text("Nothing logged yet today")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var todayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TODAY").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Text(formatDuration(store.summary.total))
                    .font(.caption).bold().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if store.summary.rows.isEmpty {
                Text("No entries yet")
                    .font(.callout).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.summary.rows.reversed()) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String(row.start.prefix(5)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(row.task)
                                    .lineLimit(1)
                                    .foregroundStyle(row.isBreak ? .secondary : .primary)
                                Spacer(minLength: 8)
                                Text(row.duration > 0 ? formatDuration(row.duration) : "–")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(row.isActive ? Color.accentColor : .secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .padding(.bottom, 6)
            }
        }
    }

    /// Shows the shortcut the user has actually configured, or nothing when
    /// an action is unbound -- rather than advertising a fixed key that may
    /// not be assigned to anything.
    private func shortcut(_ action: HotKeyAction) -> String? {
        let binding = Preferences.binding(for: action)
        return binding.isBound ? binding.description : nil
    }

    private var actions: some View {
        VStack(spacing: 0) {
            MenuButton(title: "New Entry…", shortcut: shortcut(.newEntry)) {
                onPerform(.newEntry)
            }
            MenuButton(title: "Log Retroactively…", shortcut: shortcut(.retroactiveEntry)) {
                onPerform(.retroactiveEntry)
            }
            MenuButton(title: "Continue Last Task", shortcut: shortcut(.continueLast)) {
                onPerform(.continueLast)
            }
            MenuButton(title: "Stop Tracking", shortcut: shortcut(.stopTracking)) {
                onPerform(.stopTracking)
            }
            Divider().padding(.vertical, 4)
            MenuButton(title: "Weekly Timesheet…", shortcut: shortcut(.weeklyTimesheet)) {
                onPerform(.weeklyTimesheet)
            }
            MenuButton(title: "Edit Today's Log…", shortcut: shortcut(.editToday)) {
                onPerform(.editToday)
            }
            MenuButton(title: "Reveal in Finder") { revealTodayLog() }
            Divider().padding(.vertical, 4)
            MenuButton(title: "Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                SettingsWindow.shared.show(store: store)
            }
            MenuButton(title: "Quit JottBar", shortcut: "⌘Q") { NSApp.terminate(nil) }
                // A real shortcut, unlike the decorative labels this replaces.
                .overlay(
                    Button("") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                )
        }
        .padding(.vertical, 6)
    }

    private func revealTodayLog() {
        let path = JottConfig.filePath(for: Date())
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: JottConfig.logBaseDir()))
        }
    }
}

/// Row that behaves like a native menu item but lives in a SwiftUI window.
struct MenuButton: View {
    var title: String
    var shortcut: String? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
