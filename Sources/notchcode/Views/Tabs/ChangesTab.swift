// ChangesTab.swift
// Each turn of the selected session, newest first. The turn header is one line: prompt,
// file count, ± totals, how long it took. Under it, its files: open for the newest turn,
// folded for older ones (click the header, or ⏎ on it). A file row opens to its whole diff,
// scrollable and capped. Diffs under 8 lines open by default.

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
                TurnHeader(turn: turn, open: open, isCursor: state.cursorRowKey == key)
            }
            .buttonStyle(.plain)
            .id(key)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turn.files.enumerated()), id: \.element.id) { item in
                        FileDiffRow(
                            state: state,
                            item: DiffRowItem(key: AppState.changesRowKey(turn: turn, file: item.element), file: item.element),
                            showDirectory: true
                        )
                        .transition(Theme.Motion.childTransition(item.offset))
                    }
                }
                .padding(.leading, Theme.Size.turnFilesIndent)
            }
        }
    }
}

/// "▸ Wire the permission card to the socket   3 files  +48 −9   2m 14s", on one line.
/// A turn without files says "no file changes" instead of the counts, and has no chevron.
@MainActor
private struct TurnHeader: View {
    let turn: TranscriptTurn
    let open: Bool
    let isCursor: Bool

    var body: some View {
        let hasFiles = !turn.files.isEmpty
        HStack(spacing: Theme.Size.spaceM) {
            Image(systemName: Theme.Symbols.chevron)
                .font(Theme.Fonts.chevron)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
                .animation(Theme.Motion.disclosure, value: open)
                .opacity(hasFiles ? 1 : 0)
            Text(turn.prompt)
                .font(Theme.Fonts.bodySemibold)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Size.spaceM)
            Group {
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
        .padding(.horizontal, Theme.Size.rowHPadding)
        .padding(.vertical, Theme.Size.turnHeaderVPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isCursor ? Theme.Colors.rowCursor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var elapsed: some View {
        if let end = turn.endedAt {
            Text(Format.duration(end.timeIntervalSince(turn.startedAt)))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        } else {
            HStack(spacing: Theme.Size.spaceS) {
                Text("Working")
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.clay)
                ElapsedText(since: turn.startedAt, color: Theme.Colors.inkTertiary)
            }
        }
    }
}
