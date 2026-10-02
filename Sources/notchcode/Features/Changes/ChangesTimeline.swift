// ChangesTimeline.swift
// The Changes tool's timeline column. A 1 pt spine at x 10 from the first node down; on it an
// 8 pt node per turn that changed files (ink), the live turn's node in clay with a breathing
// 14 pt halo, a 6 × 1 pt tick per quiet turn and three stacked ticks per quiet group. Titles
// start at 26 pt.
//
// An entry: the prompt in body semibold (two lines at most, cut with a fade, not an
// ellipsis), its clock time at the right of the first line (and its duration when the column
// is wide; on hover when narrow), then its files as 20 pt chips wrapping in rows: the agent
// square when a subagent made the change, the name (mono, middle-truncated, 120 pt at most),
// the five cells and the counts. The live turn: "Working 4:12" in clay instead of the time,
// and "no edits yet" until its first chip pops in. A quiet group: "4 quiet turns · questions
// and decisions" and a chevron; ⏎ or a click unfolds one 20 pt row per turn under it.
// Entries are 12 pt apart; blocks rise in and drop out, the rest sliding to make room.

import SwiftUI

@MainActor
struct ChangesTimeline: View {
    @ObservedObject var state: AppState
    /// The column's width: the duration and the quiet groups' tail show past `changesWideColumn`.
    let width: CGFloat
    let cursorSpace: Namespace.ID

    var body: some View {
        let blocks = state.changesBlocks
        let wide = width >= Theme.Size.changesWideColumn
        let cursor = state.cursorRowKey
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Size.changesEntryGap) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        blockView(block, wide: wide, cursor: cursor)
                            .transition(Theme.Motion.changesRowTransition(quietIndex(of: block, in: blocks)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) { spine }
                .animation(Theme.Motion.changesLayout, value: blocks.map(\.id))
                .animation(Theme.Motion.changesLayout, value: state.changesTool.unfoldedGroups)
            }
            .onChange(of: state.rowCursor) { _, _ in
                guard let key = state.cursorRowKey else { return }
                withAnimation(Theme.Motion.changesLayout) { proxy.scrollTo(key) }
            }
        }
    }

    /// The hairline from the first node's centre to the bottom of the last block.
    private var spine: some View {
        Rectangle()
            .fill(Theme.Colors.changesSpine)
            .frame(width: Theme.Size.changesRing)
            .frame(maxHeight: .infinity)
            .padding(.top, Theme.Size.changesRowHeight / 2)
            .padding(.leading, Theme.Size.changesSpineX - Theme.Size.changesRing / 2)
    }

    /// Quiet groups leave and come back one after another (the `/` filter); entries at once.
    private func quietIndex(of block: ChangesBlock, in blocks: [ChangesBlock]) -> Int {
        guard case .quiet = block else { return 0 }
        return blocks.prefix { $0.id != block.id }.filter { if case .quiet = $0 { return true } else { return false } }.count
    }

    @ViewBuilder
    private func blockView(_ block: ChangesBlock, wide: Bool, cursor: String?) -> some View {
        switch block {
        case .entry(let turn, _, let live):
            ChangesEntry(
                turn: turn,
                live: live,
                wide: wide,
                cursor: cursor,
                selection: state.changesPaneShown ? state.changesTool.selection : nil,
                cursorSpace: cursorSpace,
                agentColor: { id in
                    guard let sid = state.focusedSession?.id else { return 0 }
                    return state.agents(for: sid).firstIndex { $0.id == id } ?? 0
                },
                onChip: { state.selectChangesChip($0) }
            )
        case .quiet(let id, let turns):
            ChangesQuietGroup(
                id: id,
                turns: turns,
                unfolded: state.changesTool.unfoldedGroups.contains(id),
                wide: wide,
                cursor: cursor,
                cursorSpace: cursorSpace,
                onToggle: { state.toggleChangesGroup(id) }
            )
        }
    }
}

// MARK: - Nodes

/// What sits on the spine at a row's centre: a node, the live node with its halo, a tick,
/// or the quiet group's three ticks. Its frame is twice the spine's x, so it centres on it.
@MainActor
private struct ChangesNode: View {
    enum Kind { case entry, live, tick, group }
    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .entry:
                circle(Theme.Colors.changesNode)
            case .live:
                BreathingHalo()
                circle(Theme.Colors.changesNodeLive)
            case .tick:
                tick
            case .group:
                VStack(spacing: Theme.Size.changesTickGap - Theme.Size.changesTickHeight) { tick; tick; tick }
            }
        }
        .frame(width: 2 * Theme.Size.changesSpineX, height: Theme.Size.changesRowHeight)
    }

    private func circle(_ color: Color) -> some View {
        Circle().fill(color).frame(width: Theme.Size.changesNode, height: Theme.Size.changesNode)
    }

    private var tick: some View {
        Rectangle()
            .fill(Theme.Colors.changesTick)
            .frame(width: Theme.Size.changesTickWidth, height: Theme.Size.changesTickHeight)
    }
}

/// The live node's halo: out to 1.5× and gone over 1.6 s, again and again. Reduce Motion: still.
@MainActor
private struct BreathingHalo: View {
    @State private var out = false

    var body: some View {
        Circle()
            .fill(Theme.Colors.changesHalo)
            .frame(width: Theme.Size.changesHalo, height: Theme.Size.changesHalo)
            .scaleEffect(out ? Theme.Size.changesHaloScale : 1)
            .opacity(out ? 0 : 1)
            .onAppear {
                guard let breath = Theme.Motion.changesBreath else { return }
                withAnimation(breath) { out = true }
            }
    }
}

// MARK: - Cursor

/// The keyboard cursor: a ring around a chip, a row's fill on a quiet row. One matched frame,
/// so it glides from stop to stop.
@MainActor
private struct CursorMark: View {
    let onChip: Bool
    let cursorSpace: Namespace.ID

    var body: some View {
        Group {
            if onChip {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.Colors.changesChipRing, lineWidth: Theme.Size.changesRing)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.Colors.rowCursor)
            }
        }
        .matchedGeometryEffect(id: "changesCursor", in: cursorSpace)
        .transition(AnyTransition.opacity.animation(Theme.Motion.changesHover))
        .allowsHitTesting(false)
    }
}

// MARK: - Entry

/// A turn that changed files, or the live turn.
@MainActor
private struct ChangesEntry: View {
    let turn: TranscriptTurn
    let live: Bool
    let wide: Bool
    let cursor: String?
    /// The chip whose diff the pane shows, while it shows.
    let selection: ChangesChipKey?
    let cursorSpace: Namespace.ID
    let agentColor: (String) -> Int
    let onChip: (ChangesChipKey) -> Void

    var body: some View {
        let liveKey = ChangesItem.live(turnId: turn.id).id
        HStack(alignment: .top, spacing: 0) {
            ChangesNode(kind: live ? .live : .entry)
                .frame(width: Theme.Size.changesTitleInset, alignment: .leading)
                .animation(Theme.Motion.changesLayout, value: live)
            VStack(alignment: .leading, spacing: Theme.Size.changesTitleGap) {
                HStack(alignment: .top, spacing: Theme.Size.spaceM) {
                    FadeText(text: turn.prompt, font: Theme.Fonts.bodySemibold, color: Theme.Colors.ink, lines: 2)
                        .padding(.vertical, Theme.Size.changesTitleVPadding)
                    trailing
                        .frame(height: Theme.Size.changesRowHeight)
                        .animation(Theme.Motion.changesLayout, value: live)
                }
                if turn.files.isEmpty {
                    Text("no edits yet")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .padding(.horizontal, Theme.Size.changesChipHPadding)
                        .frame(height: Theme.Size.changesRowHeight)
                        .background { if cursor == liveKey { CursorMark(onChip: false, cursorSpace: cursorSpace) } }
                        .id(liveKey)
                        .transition(.opacity)
                } else {
                    ChipFlow {
                        ForEach(turn.files) { file in
                            let key = ChangesChipKey(turnId: turn.id, path: file.path)
                            ChangesChip(
                                file: file,
                                agentColor: file.agentId.map(agentColor),
                                isCursor: cursor == AppState.changesChipID(key),
                                isSelected: selection == key,
                                cursorSpace: cursorSpace
                            ) { onChip(key) }
                            .id(AppState.changesChipID(key))
                            .transition(Theme.Motion.changesChipTransition)
                        }
                    }
                    .animation(Theme.Motion.changesLayout, value: turn.files.map(\.path))
                }
            }
        }
    }

    /// "14:32  3m 30s" (the duration only when the column is wide, else on hover), or
    /// "Working 4:12" in clay while the turn runs.
    @ViewBuilder
    private var trailing: some View {
        if live {
            HStack(spacing: Theme.Size.spaceS) {
                Text("Working")
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.clay)
                ElapsedText(since: turn.startedAt, color: Theme.Colors.clay)
            }
            .fixedSize()
            .transition(.opacity)
        } else {
            let duration = turn.endedAt.map { Format.duration($0.timeIntervalSince(turn.startedAt)) }
            HStack(spacing: Theme.Size.spaceS) {
                Text(Format.timeOfDay(turn.startedAt))
                if wide, let duration { Text(duration) }
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .fixedSize()
            .help(duration.map { "took " + $0 } ?? "")
            .transition(.opacity)
        }
    }
}

/// "▪ GitTab.swift ▮▮▮▯▯ +53 −19": one file a turn changed. The keyboard cursor rings it; the
/// selected chip (its diff showing) and the hovered one fill a step brighter.
@MainActor
private struct ChangesChip: View {
    let file: FileChange
    /// The subagent's colour slot when a subagent made the change.
    let agentColor: Int?
    let isCursor: Bool
    let isSelected: Bool
    let cursorSpace: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        Button(action: action) {
            HStack(spacing: Theme.Size.changesChipHPadding) {
                if let agentColor {
                    AgentSquare(colorIndex: agentColor)
                }
                Text(Format.fileName(file.path))
                    .font(Theme.Fonts.monoCaption)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Theme.Size.changesChipMaxWidth, alignment: .leading)
                HStack(spacing: Theme.Size.changesChipGap) {
                    DiffCells(added: file.added, removed: file.removed)
                    DiffCounts(added: file.added, removed: file.removed)
                }
                .fixedSize()
            }
            .padding(.horizontal, Theme.Size.changesChipHPadding)
            .frame(height: Theme.Size.changesChipHeight)
            .background(shape.fill(isSelected || hovered ? Theme.Colors.changesChipSelected : Theme.Colors.changesChipFill))
            .overlay { if isCursor { CursorMark(onChip: true, cursorSpace: cursorSpace) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Theme.Motion.changesHover) { hovered = inside } }
        .help(help)
    }

    private var help: String {
        var parts = [file.path]
        if agentColor != nil { parts.append("edited by an agent") }
        if file.kind == "shell" { parts.append("changed by a shell command, diff against HEAD") }
        return parts.joined(separator: Theme.Glyphs.separator)
    }
}

// MARK: - Quiet turns

/// "≡ 4 quiet turns · questions and decisions ▸": a run of turns without files, one row.
/// Unfolded, one row per turn under it: a tick, the prompt (one line, cut with a fade), the time.
@MainActor
private struct ChangesQuietGroup: View {
    let id: String
    let turns: [TranscriptTurn]
    let unfolded: Bool
    let wide: Bool
    let cursor: String?
    let cursorSpace: Namespace.ID
    let onToggle: () -> Void

    var body: some View {
        let groupKey = ChangesItem.group(id: id).id
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 0) {
                    ChangesNode(kind: .group)
                        .frame(width: Theme.Size.changesTitleInset, alignment: .leading)
                    HStack(spacing: 0) {
                        Text(Format.quietTurns(turns.count))
                            .foregroundStyle(Theme.Colors.inkSecondary)
                        if wide {
                            Text(Theme.Glyphs.separator + "questions and decisions")
                                .foregroundStyle(Theme.Colors.inkTertiary)
                        }
                        Spacer(minLength: Theme.Size.spaceM)
                        RowChevron(open: unfolded, width: nil)
                    }
                    .font(Theme.Fonts.caption)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Size.changesChipHPadding)
                    .frame(height: Theme.Size.changesRowHeight)
                    .background { if cursor == groupKey { CursorMark(onChip: false, cursorSpace: cursorSpace) } }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(groupKey)

            if unfolded {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    quietRow(turn)
                        .transition(Theme.Motion.changesRowTransition(index))
                }
            }
        }
    }

    private func quietRow(_ turn: TranscriptTurn) -> some View {
        let key = ChangesItem.quiet(turnId: turn.id).id
        return HStack(spacing: 0) {
            ChangesNode(kind: .tick)
                .frame(width: Theme.Size.changesTitleInset, alignment: .leading)
            HStack(spacing: Theme.Size.spaceM) {
                FadeText(text: turn.prompt, font: Theme.Fonts.caption, color: Theme.Colors.inkSecondary)
                Text(Format.timeOfDay(turn.startedAt))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.changesChipHPadding)
            .frame(height: Theme.Size.changesRowHeight)
            .background { if cursor == key { CursorMark(onChip: false, cursorSpace: cursorSpace) } }
        }
        .help(turn.prompt)
        .id(key)
    }
}
