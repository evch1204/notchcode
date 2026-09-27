// ChangesTab.swift
// Each turn of the selected session, newest first, with its files. A file row
// opens to its whole diff (click, or ⏎ on the keyboard cursor). Diffs under
// 8 lines open by default.

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
                    VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
                        ForEach(turns) { turn in
                            turnBlock(turn)
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

    private func turnBlock(_ turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
            HStack(spacing: Theme.Size.spaceM) {
                Text(turn.prompt)
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Size.spaceM)
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

            if turn.files.isEmpty {
                Text(turn.assistantSummary ?? "No files changed")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ForEach(turn.files) { file in
                FileDiffRow(state: state, item: DiffRowItem(key: AppState.changesRowKey(turn: turn, file: file), file: file))
            }
        }
    }
}
