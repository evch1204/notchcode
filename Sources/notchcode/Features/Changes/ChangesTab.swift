// ChangesTab.swift
// Each turn of the selected session, newest first, in the Toolbar layout: one flat list.
// A turn is one row: chevron, prompt, file count, ± totals, how long it took. Under an
// open turn its files, indented one chevron column so their chevrons sit under the turn's
// title: open for the newest turn, folded for older ones (click the row, or ⏎ on it). A
// file row opens to its whole diff in a rounded box under it, scrollable and capped.
// Diffs under 8 lines open by default. Rows use the app's shared type scale and row
// metrics, the same as a Sessions row.

import SwiftUI

@MainActor
struct ChangesTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        let turns = state.turns(for: state.focusedSession?.id)
        if turns.isEmpty {
            EmptyNote(text: "Nothing changed yet in this session")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { item in
                            turnBlock(item.element, newest: item.offset == 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.rowCursor) { _, _ in
                    guard let key = state.cursorRowKey else { return }
                    withAnimation(Theme.Motion.tap) { proxy.scrollTo(key) }
                }
            }
        }
    }

    private func turnBlock(_ turn: TranscriptTurn, newest: Bool) -> some View {
        let open = state.isTurnOpen(turn, newest: newest)
        let key = AppState.turnRowKey(turn)
        return VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
            Button {
                state.setRowCursor(key: key)
                guard !turn.files.isEmpty else { return }
                withAnimation(Theme.Motion.disclosure) { state.toggleTurn(turn.id) }
            } label: {
                TurnRow(turn: turn, open: open, isCursor: state.cursorRowKey == key)
            }
            .buttonStyle(.plain)
            .id(key)

            if open {
                ForEach(Array(turn.files.enumerated()), id: \.element.id) { item in
                    let row = DiffRowItem(key: AppState.changesRowKey(turn: turn, file: item.element), file: item.element)
                    let hasDiff = !AppState.diffLines(row.file).isEmpty
                    FileDiffRow(
                        file: row.file,
                        open: hasDiff && state.isDiffOpen(row),
                        isCursor: state.cursorRowKey == row.key
                    ) {
                        state.setRowCursor(key: row.key)
                        guard hasDiff else { return }
                        withAnimation(Theme.Motion.tap) { state.toggleDiff(row.key) }
                    } diff: {
                        DiffView(file: row.file)
                    }
                    .id(row.key)
                    .padding(.leading, Theme.Size.chevronColumn)
                    .transition(Theme.Motion.childTransition(item.offset))
                }
            }
        }
    }
}

/// "▸ Wire the permission card to the socket   3 files  +48 −9  Working 4:12", on one
/// line. A turn without files says "no file changes" instead of the counts, and has no
/// chevron.
@MainActor
private struct TurnRow: View {
    let turn: TranscriptTurn
    let open: Bool
    let isCursor: Bool

    var body: some View {
        let hasFiles = !turn.files.isEmpty
        HStack(spacing: Theme.Size.spaceM) {
            RowChevron(open: open)
                .opacity(hasFiles ? 1 : 0)
            Text(turn.prompt)
                .font(Theme.Fonts.bodySemibold)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Size.spaceM)
            HStack(spacing: Theme.Size.spaceM) {
                if hasFiles {
                    Text(Format.files(turn.files.count))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                    DiffCounts(
                        added: turn.files.reduce(0) { $0 + $1.added },
                        removed: turn.files.reduce(0) { $0 + $1.removed }
                    )
                } else {
                    Text("no file changes")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
                elapsed
            }
            .fixedSize()
        }
        .rowCursorFill(isCursor)
    }

    @ViewBuilder
    private var elapsed: some View {
        if let end = turn.endedAt {
            Text(Format.duration(end.timeIntervalSince(turn.startedAt)))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        } else {
            HStack(spacing: Theme.Size.spaceM) {
                Text("Working")
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.clay)
                ElapsedText(since: turn.startedAt)
            }
        }
    }
}
