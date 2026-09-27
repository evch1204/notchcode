// SessionsTab.swift
// Every session at a glance, grouped by repository: a slim header per repo
// ("notchcode · 2 worktrees") that sticks while its rows scroll, then one row per
// session: state dot, the worktree name bold, branch in mono, model, state word and
// clock on the right, the current prompt dimmed below. A plain checkout is its own
// group with one row named after its folder. Groups with someone waiting come first.
// Two sessions in one folder also show their start time, and the newest gets a tag.
// Clicking a row (or ⏎) selects the session and shows its Changes; the chevron (or ⌥⏎)
// teleports to its terminal. Each subagent gets a lane with its own colour square;
// finished ones collapse into "N done", which opens on click. Counts live in the footer.

import SwiftUI

@MainActor
struct SessionsTab: View {
    @ObservedObject var state: AppState
    /// Sessions whose finished agents are expanded.
    @State private var expandedDone: Set<String> = []

    var body: some View {
        let pendingIds = Set(state.pending.map { $0.sessionId })
        let groups = state.sessionGroups
        let ordered = groups.flatMap { $0.sessions }
        if ordered.isEmpty {
            EmptyNote(text: "No Claude Code sessions in the last few hours")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Theme.Size.spaceXS, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    let index = ordered.firstIndex { $0.id == session.id } ?? 0
                                    sessionBlock(session, index: index, isPending: pendingIds.contains(session.id))
                                        .id(session.id)
                                }
                            } header: {
                                RepoHeader(group: group)
                            }
                        }
                    }
                }
                .onChange(of: state.sessionCursor) { _, cursor in
                    guard ordered.indices.contains(cursor) else { return }
                    withAnimation(Theme.Motion.tap) { proxy.scrollTo(ordered[cursor].id) }
                }
            }
        }
    }

    private func sessionBlock(_ session: Session, index: Int, isPending: Bool) -> some View {
        let all = state.agents(for: session.id)
        let running = all.enumerated().filter { $0.element.isRunning }
        let finished = all.enumerated().filter { !$0.element.isRunning }
        let expanded = expandedDone.contains(session.id)
        let isCursor = index == state.sessionCursor
        let isFocused = state.focusedSession?.id == session.id

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    state.selectSession(session)
                } label: {
                    SessionRow(
                        session: session,
                        prompt: state.currentPrompt(for: session.id),
                        turnStart: state.turnStart(for: session),
                        model: state.modelShortName(for: session.id),
                        isPending: isPending,
                        isFocused: isFocused,
                        twin: state.isAmbiguous(session) ? SessionRow.Twin(
                            startedAt: state.startTime(for: session),
                            isNewest: state.isNewest(session)
                        ) : nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    state.sessionCursor = index
                    state.teleport(session: session)
                } label: {
                    Image(systemName: Theme.Symbols.chevron)
                        .font(Theme.Fonts.chevron)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .frame(width: Theme.Size.chevronColumn + Theme.Size.rowHPadding, height: Theme.Size.pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in \(state.terminalName(for: session)) (\(Theme.Keys.optionEnter))")
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isPending ? Theme.Colors.attentionHighlight : (isCursor ? Theme.Colors.selection : Color.clear))
            )

            ForEach(running, id: \.element.id) { entry in
                AgentLane(agent: entry.element, colorIndex: entry.offset)
            }

            if !finished.isEmpty {
                Button {
                    withAnimation(Theme.Motion.tap) {
                        if expanded { expandedDone.remove(session.id) } else { expandedDone.insert(session.id) }
                    }
                } label: {
                    DoneLane(count: finished.count, expanded: expanded)
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(finished, id: \.element.id) { entry in
                        AgentLane(agent: entry.element, colorIndex: entry.offset)
                    }
                }
            }
        }
    }
}

/// "notchcode · 2 worktrees": slim, pinned while its rows scroll. Carries the card's black so
/// rows pass cleanly beneath it.
@MainActor
private struct RepoHeader: View {
    let group: SessionGroup

    var body: some View {
        HStack(spacing: 0) {
            Text(group.name)
                .font(Theme.Fonts.groupHeader)
                .foregroundStyle(Theme.Colors.groupHeaderName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(Theme.Glyphs.separator + detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.groupHeaderCount)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.repoHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.groupHeaderBackground)
    }

    /// "2 worktrees", plus "3 sessions" when a worktree runs more than one.
    private var detail: String? {
        var parts: [String] = []
        if group.hasWorktrees { parts.append(Format.worktrees(group.worktreeCount)) }
        if group.sessions.count > group.worktreeCount { parts.append(Format.sessions(group.sessions.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: Theme.Glyphs.separator)
    }
}

@MainActor
private struct SessionRow: View {
    /// What tells two sessions in the same folder apart.
    struct Twin {
        var startedAt: Date
        var isNewest: Bool
    }

    let session: Session
    let prompt: String?
    let turnStart: Date?
    let model: String?
    let isPending: Bool
    let isFocused: Bool
    let twin: Twin?

    private var shownState: SessionState { isPending ? .needsYou : session.state }
    private var secondLine: String {
        let text = prompt ?? ""
        guard let twin else { return text.isEmpty ? " " : text }
        return Format.started(twin.startedAt) + (text.isEmpty ? "" : Theme.Glyphs.separator + text)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Size.spaceM) {
            StatusDot(state: shownState)
                .frame(width: Theme.Size.glyph)

            VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Size.spaceM) {
                    Text(session.rowName)
                        .font(Theme.Fonts.bodySemibold)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let branch = session.branch {
                        Text(branch)
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let model {
                        Text(model)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if twin?.isNewest == true {
                        SmallTag(text: "newest")
                    }
                    if isFocused {
                        SmallTag(text: "Showing")
                    }
                }
                Text(secondLine)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.Size.spaceM)

            HStack(spacing: Theme.Size.spaceM) {
                Text(Format.stateText(session, pending: isPending))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                if shownState == .working, let turnStart {
                    ElapsedText(since: turnStart, color: Theme.Colors.inkTertiary)
                } else {
                    Text(Format.ago(session.lastEventAt))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
        .padding(.leading, Theme.Size.rowHPadding)
        .padding(.vertical, Theme.Size.rowVPadding)
    }

    private var stateColor: Color {
        switch shownState {
        case .needsYou: return Theme.Colors.attentionText
        case .working: return Theme.Colors.clay
        case .done: return Theme.Colors.green
        case .idle: return Theme.Colors.inkTertiary
        }
    }
}

/// A small tertiary capsule: "Showing", "newest".
@MainActor
private struct SmallTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .padding(.horizontal, Theme.Size.smallPillHPadding)
            .frame(height: Theme.Size.smallPillHeight)
            .background(Capsule(style: .continuous).fill(Theme.Colors.doneChipFill))
            .fixedSize()
    }
}

/// One subagent under its session: colour square, type, description, elapsed (or how long it ran).
@MainActor
private struct AgentLane: View {
    let agent: Agent
    let colorIndex: Int

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Rectangle()
                .fill(Theme.Colors.laneLine)
                .frame(width: Theme.Size.laneLineWidth)
                .frame(maxHeight: .infinity)
            AgentSquare(colorIndex: colorIndex, finished: !agent.isRunning)
            Text(agent.type)
                .font(Theme.Fonts.captionSemibold)
                .foregroundStyle(agent.isRunning ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                .lineLimit(1)
                .fixedSize()
            if let description = agent.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(agent.isRunning ? Theme.Colors.inkSecondary : Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Size.spaceM)
            if let ended = agent.endedAt {
                Text(Format.duration(ended.timeIntervalSince(agent.startedAt)))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .fixedSize()
            } else {
                ElapsedText(since: agent.startedAt, color: Theme.Colors.inkTertiary)
            }
        }
        .padding(.leading, Theme.Size.laneIndent)
        .padding(.trailing, Theme.Size.rowHPadding + Theme.Size.chevronColumn)
        .padding(.vertical, Theme.Size.laneVPadding)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "▸ 3 done": finished agents, collapsed. Click to show their lanes.
@MainActor
private struct DoneLane: View {
    let count: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Rectangle()
                .fill(Theme.Colors.laneLine)
                .frame(width: Theme.Size.laneLineWidth)
                .frame(maxHeight: .infinity)
            HStack(spacing: Theme.Size.spaceS) {
                Image(systemName: Theme.Symbols.chevron)
                    .font(Theme.Fonts.chevron)
                    .rotationEffect(.degrees(expanded ? Theme.Motion.chevronOpenDegrees : 0))
                Text("\(count) done")
                    .font(Theme.Fonts.caption)
            }
            .foregroundStyle(Theme.Colors.inkTertiary)
            .padding(.horizontal, Theme.Size.smallPillHPadding)
            .frame(height: Theme.Size.smallPillHeight)
            .background(Capsule(style: .continuous).fill(Theme.Colors.doneChipFill))
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Size.laneIndent)
        .padding(.vertical, Theme.Size.laneVPadding)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}
