import SwiftUI
import AppKit

// ======================================================================
// MAIN WINDOW
// ======================================================================
// One window with a sidebar, rather than four windows that happened to
// share a process. The dashboard, the day editor, the weekly timesheet
// and settings are now pages inside it, so moving between them keeps
// the same frame, the same theme and the same running-task footer.
//
// The menubar dropdown is unchanged and still the fast path -- this is
// the place you go when you want to look at more than one thing.

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard, today, previousDays, week, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .today: return "Today"
        case .previousDays: return "Previous days"
        case .week: return "Weekly view"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .today: return "clock"
        case .previousDays: return "clock.arrow.circlepath"
        case .week: return "calendar"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class MainWindow: NSWindow {
    static let shared = MainWindow()

    /// Shared with MainView so the window's minimum stays tied to it.
    static let sidebarWidth: CGFloat = 272

    private var selection = MainTabSelection()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Jott"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        contentView = NSHostingView(
            rootView: MainView(selection: selection)
                .environmentObject(LedgerStore.shared)
                .tint(Theme.accent)
        )
        // Set AFTER the hosting view: NSHostingView publishes its own
        // sizing when it is installed, which was overriding a minSize
        // assigned beforehand -- the window could be dragged far below it.
        // contentMinSize is the one SwiftUI content actually respects;
        // minSize stays as the belt to its braces.
        //
        // The floor is the fixed sidebar plus enough page for the day
        // editor's timeline and inspector to sit side by side.
        let floor = NSSize(width: Self.sidebarWidth + 620, height: 620)
        contentMinSize = floor
        minSize = floor
        center()
    }

    func show(tab: MainTab) {
        selection.tab = tab
        makeKeyAndOrderFront(nil)
    }
}

/// Shared so `MainWindow.show(tab:)` can change pages on a window that is
/// already open, without rebuilding the hosting view.
@MainActor
final class MainTabSelection: ObservableObject {
    @Published var tab: MainTab = .dashboard
}

// ----------------------------------------------------------------------

struct MainView: View {
    @ObservedObject var selection: MainTabSelection
    @EnvironmentObject var store: LedgerStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            content
        }
        .background(Theme.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch selection.tab {
        case .dashboard: DashboardView(selection: selection)
        case .today: LogEditorView(showsBrand: false)
        case .previousDays: PreviousDaysView()
        case .week: WeekView(showsBrand: false)
        case .settings:
            SettingsView()
                .formStyle(.grouped)
        }
    }

    // ----- Sidebar ---------------------------------------------------
    // Always the dark surface, in either theme. It is chrome, and the
    // contrast against the page is what makes the shell read as a shell.

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clears the traffic lights, which float over the sidebar
            // because the window draws its content full-size.
            Color.clear.frame(height: 28)

            HStack(spacing: 0) {
                BrandMark(size: 62)
                Text("Jott")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 18)
                Spacer()
            }

            VStack(spacing: 4) {
                ForEach([MainTab.dashboard, .today, .previousDays, .week]) { tab in
                    navRow(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)

            Spacer()

            trackingCard
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            navRow(.settings)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(width: MainWindow.sidebarWidth)
        .background(Theme.sidebar)
    }

    private func navRow(_ tab: MainTab) -> some View {
        let active = selection.tab == tab
        return Button {
            selection.tab = tab
        } label: {
            HStack(spacing: 14) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(active ? Theme.accent : Color.white.opacity(0.65))
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .white : Color.white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.white.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackingCard: some View {
        let identity = store.summary.currentTask.map(TicketIdentity.parse)

        VStack(alignment: .leading, spacing: 8) {
            if let task = store.summary.currentTask,
               let elapsed = store.summary.currentElapsed {
                HStack(spacing: 7) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Tracking since \(store.summary.startClock(of: task) ?? "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                Text(identity?.title ?? task)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(identity?.subtitle ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))

                HStack {
                    Text(clockElapsed(elapsed))
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button { store.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Stop tracking")
                }
                .padding(.top, 2)
            } else {
                Text(store.summary.isOnBreak ? "Stopped" : "Not tracking")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text(store.summary.entries.isEmpty
                     ? "Nothing logged yet today."
                     : "Pick up where you left off.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))

                Button { store.continueLast() } label: {
                    Text("Continue last task")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(store.summary.entries.isEmpty)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

/// `0:39` -- hours and minutes, the shape of a stopwatch rather than a
/// duration summary, because this one is still counting.
func clockElapsed(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
}
