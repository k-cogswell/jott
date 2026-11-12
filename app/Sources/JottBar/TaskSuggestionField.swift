import SwiftUI
import AppKit

// ======================================================================
// TASK FIELD WITH COMPLETION
// ======================================================================
// The capture prompt has had recent-task and Jira completion since the
// Jira integration landed, but that logic lived inside PromptPanel. Any
// other place you type a task name -- the dashboard's switch-task field,
// the day editor's inspector -- was a bare TextField, which made the
// Jira integration look broken when it was simply not wired up.
//
// This is that behaviour as a component. It reads `LedgerStore.suggestions`,
// the same merged list the prompt uses: today's distinct tasks first,
// then assigned Jira issues not already represented.

struct TaskSuggestionField: View {
    @Binding var text: String
    var placeholder: String
    /// Rounded-rectangle by default; the dashboard wants a pill.
    var capsuleShape = false
    /// Called when a suggestion is chosen or Return is pressed. The field
    /// has already been updated by then. Omit it for a field that is only
    /// edited, like the day editor's -- there is nothing to submit to.
    var onCommit: ((String) -> Void)?

    @EnvironmentObject private var store: LedgerStore
    @FocusState private var focused: Bool
    @State private var selection = -1

    /// Capped low: this floats over the page, and a list long enough to
    /// reach the window edge gets clipped by the enclosing ScrollView.
    private static let maxMatches = 5

    private var matches: [Suggestion] {
        guard focused else { return [] }
        let query = text.trimmingCharacters(in: .whitespaces)
        // An exact match is not a suggestion, it is what you already typed.
        let pool = store.suggestions.filter { $0.taskText.lowercased() != query.lowercased() }
        return Array(pool.filter { $0.matches(query) }.prefix(Self.maxMatches))
    }

    var body: some View {
        field
            .overlay(alignment: .topLeading) {
                if !matches.isEmpty {
                    dropdown
                        .offset(y: 44)
                        .zIndex(1)
                }
            }
            .onChange(of: text) { _, _ in selection = -1 }
            .onKeyPress(.downArrow) {
                guard !matches.isEmpty else { return .ignored }
                selection = min(selection + 1, matches.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !matches.isEmpty else { return .ignored }
                selection = max(selection - 1, -1)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !matches.isEmpty else { return .ignored }
                selection = -1
                focused = false
                return .handled
            }
    }

    @ViewBuilder
    private var field: some View {
        let input = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit(commit)
            .padding(.horizontal, capsuleShape ? 16 : 11)
            .padding(.vertical, capsuleShape ? 12 : 9)

        if capsuleShape {
            input.background(
                Capsule().fill(Theme.surface)
                    .overlay(Capsule().stroke(focused ? Theme.accent : Theme.hairline, lineWidth: 1))
            )
        } else {
            input.background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(focused ? Theme.accent : Theme.hairline, lineWidth: 1)
                    )
            )
        }
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                row(match, highlighted: index == selection)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(match) }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    private func row(_ match: Suggestion, highlighted: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: match.kind == .jira ? "ticket" : "arrow.uturn.backward")
                .font(.system(size: 11))
                .foregroundStyle(match.kind == .jira ? Theme.accent : Theme.tertiaryText)
                .frame(width: 16)

            if let key = match.key {
                Text(key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.15)))
                Text(match.taskText.dropFirst(key.count).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            } else {
                Text(match.taskText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let detail = match.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(highlighted ? Theme.accent.opacity(0.14) : .clear)
    }

    private func choose(_ match: Suggestion) {
        text = match.taskText
        selection = -1
        onCommit?(match.taskText)
    }

    /// Return takes the highlighted suggestion if there is one, otherwise
    /// whatever was typed -- so a task that is not in the list is never
    /// blocked by the list.
    private func commit() {
        if selection >= 0, selection < matches.count {
            choose(matches[selection])
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selection = -1
        onCommit?(trimmed)
    }
}
