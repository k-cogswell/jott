import SwiftUI
import AppKit

// ======================================================================
// HISTORY SEARCH
// ======================================================================
// "When did I last touch this?" -- across every ledger on disk. The search
// itself runs in the CLI (`jott find --json`), so the terminal and the app
// return identical results from one implementation.

struct SearchMatch: Identifiable, Decodable {
    var date: String
    var start: String
    var end: String
    var duration: String
    var seconds: Int
    var task: String

    var id: String { date + "|" + start + "|" + task }
}

private struct SearchResponse: Decodable {
    var ok: Bool
    var matches: [SearchMatch]
    var totalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case ok, matches
        case totalSeconds = "total_seconds"
    }
}

enum HistorySearch {
    static func find(_ query: String, limit: Int = 200) -> (matches: [SearchMatch], total: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ([], 0) }

        let result = JottCLI.run(["find", trimmed, "--limit", String(limit), "--json"])
        guard let data = result.output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return ([], 0)
        }
        return (decoded.matches, decoded.totalSeconds)
    }
}

// ----------------------------------------------------------------------

@MainActor
final class SearchWindow {
    static let shared = SearchWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Search History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = NSHostingView(rootView: SearchView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var matches: [SearchMatch] = []
    @State private var totalSeconds = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    private var grouped: [(date: String, rows: [SearchMatch])] {
        var order: [String] = []
        var buckets: [String: [SearchMatch]] = [:]
        for match in matches {
            if buckets[match.date] == nil { order.append(match.date) }
            buckets[match.date, default: []].append(match)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search every entry you've logged…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onChange(of: query) { _, _ in scheduleSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""; matches = []; totalSeconds = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                placeholder("Type to search across every day you've logged.")
            } else if searching && matches.isEmpty {
                placeholder("Searching…")
            } else if matches.isEmpty {
                placeholder("No entries match “\(query)”.")
            } else {
                results
                Divider()
                footer
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.date) { group in
                    HStack {
                        Text(group.date)
                            .font(.caption).bold()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(dayTotal(group.rows))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    ForEach(group.rows) { row in
                        HStack(spacing: 10) {
                            Text(String(row.start.prefix(5)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .leading)
                            Text(row.task).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.duration)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(row.seconds > 0 ? .secondary : .tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    Divider().opacity(0.4)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(matches.count) \(matches.count == 1 ? "entry" : "entries")")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Total tracked")
                .font(.callout).foregroundStyle(.secondary)
            Text(formatDuration(TimeInterval(totalSeconds)))
                .font(.title3).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func dayTotal(_ rows: [SearchMatch]) -> String {
        formatDuration(TimeInterval(rows.reduce(0) { $0 + $1.seconds }))
    }

    /// Debounced: each keystroke would otherwise spawn a CLI process.
    private func scheduleSearch() {
        searchTask?.cancel()
        let current = query
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached { HistorySearch.find(current) }.value
            guard !Task.isCancelled, current == query else { return }
            await MainActor.run {
                matches = result.matches
                totalSeconds = result.total
                searching = false
            }
        }
    }
}
