// ChangesTab.swift
// The Changes tool, Direction G (Timeline; owner, 2026-09-30). Inside the well: a 26 pt header
// with the session's totals ("14 turns · 9 files · +607 −0 · 1h 12m", the session's, not the
// view's) and the "With edits /" pill; under it the timeline (ChangesTimeline.swift): a spine
// with one node per turn, newest first, the live turn breathing at the top, each turn that
// changed files as an entry with its files as chips, and every run of quiet turns folded
// into one row. ⏎ or a click on a chip opens the diff pane on the right (ChangesDiffPane.swift),
// the Git tool's split: the column springs from the full width to 236 pt, a hairline, the
// pane. The diff never opens inline, so the timeline never jumps. Esc closes the pane, ⌘B
// hides the column while it shows, `/` hides the quiet turns.

import SwiftUI

@MainActor
struct ChangesTab: View {
    @ObservedObject var state: AppState
    /// The cursor's ring glides from chip to chip, and becomes a row's fill on a quiet row.
    @Namespace private var cursorSpace

    var body: some View {
        let turns = state.turns(for: state.focusedSession?.id)
        if turns.isEmpty {
            EmptyNote(text: "Nothing changed yet in this session")
        } else {
            VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
                ChangesHeader(state: state, turns: turns)
                    .frame(height: Theme.Size.changesHeaderHeight)
                split
            }
        }
    }

    /// The timeline column, then (while a chip's diff shows) gap, hairline, gap and the pane.
    /// Hidden (⌘B), the column keeps its width inside and is clipped to nothing, so its text
    /// does not re-wrap while the width springs.
    private var split: some View {
        GeometryReader { geo in
            let selected = state.changesSelectedFile
            let shown = state.changesTool.paneOpen && selected != nil
            let hidden = shown && state.changesTool.columnHidden
            let narrow = min(Theme.Size.changesColumnWidth, geo.size.width)
            let contentWidth = shown ? narrow : geo.size.width
            HStack(alignment: .top, spacing: 0) {
                // Text re-wraps at once when the width changes; only the column's edge springs.
                ChangesTimeline(state: state, width: contentWidth, cursorSpace: cursorSpace)
                    .transaction(value: contentWidth) { $0.animation = nil }
                    .frame(width: contentWidth, height: geo.size.height, alignment: .topLeading)
                    .frame(width: hidden ? 0 : contentWidth, alignment: .leading)
                    .clipped()
                if shown, let selected {
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle()
                            .fill(Theme.Colors.paneDivider)
                            .frame(width: Theme.Size.hairline)
                            .padding(.horizontal, Theme.Size.filesColumnGap)
                            .frame(width: hidden ? 0 : nil)
                            .opacity(hidden ? 0 : 1)
                            .fadeIn()
                        ChangesDiffPane(state: state, turn: selected.turn, file: selected.file, number: selected.number)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .transition(Theme.Motion.changesPaneTransition)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Theme.Motion.changesLayout, value: shown)
            .animation(Theme.Motion.changesLayout, value: hidden)
        }
    }
}

/// "14 turns · 9 files · +607 −0 · 1h 12m" on the left (the whole session, whatever the
/// filter), "· 3 with edits" after it while the filter is on, and the "With edits /" pill on
/// the right: neutral, white while on; it pops when pressed.
@MainActor
private struct ChangesHeader: View {
    @ObservedObject var state: AppState
    let turns: [TranscriptTurn]

    var body: some View {
        let on = state.changesTool.editsOnly
        let paths = Set(turns.flatMap { $0.files.map(\.path) })
        let files = turns.flatMap(\.files)
        HStack(spacing: Theme.Size.spaceM) {
            HStack(spacing: 0) {
                Text(Format.turns(turns.count) + Theme.Glyphs.separator + Format.files(paths.count) + Theme.Glyphs.separator)
                DiffCounts(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                span
                if on {
                    Text(Theme.Glyphs.separator + "\(turns.filter { !$0.files.isEmpty }.count) with edits")
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .transition(Theme.Motion.paneSwapTransition)
                }
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .lineLimit(1)
            Spacer(minLength: Theme.Size.spaceM)
            ActionSegment(title: "With edits", key: Theme.Keys.slash, role: on ? .allow : .neutral) {
                state.toggleChangesEditsOnly()
            }
            .countPop(on)
            .help(on ? "Show every turn" : "Show only the turns that changed files")
        }
        .animation(Theme.Motion.changesLayout, value: on)
    }

    /// " · 1h 12m": the first turn's start to the last turn's end, or to now while one runs.
    private var span: some View {
        let first = turns.last?.startedAt ?? Date()
        let live = state.changesLiveTurnId(turns) != nil
        let end = turns.compactMap(\.endedAt).max() ?? first
        return TimelineView(.periodic(from: .now, by: Theme.Timing.clockTick)) { context in
            Text(Theme.Glyphs.separator + Format.duration((live ? context.date : end).timeIntervalSince(first)))
        }
    }
}
