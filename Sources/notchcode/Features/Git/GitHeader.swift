// GitHeader.swift
// The Git tool's header row: the target pill, the branch, the status line (where it stands
// against its upstream, and where every result lands), and the sync pill (Publish, Pull,
// Push or Fetch; pulsing while git writes), which travels into the stage for its confirm.

import SwiftUI

// MARK: - Header

/// "notchcode › seadevil ▾ W   user-friendly-distribution-plan   [Push 3  P]", or a write's
/// result in the status's place. While a sync is asked the pill is away in the stage, armed
/// with ⏎ under the question, and an outline holds its place; while any write runs the pill
/// is home, pulsing. A branch checked out nowhere:
/// "notchcode › design/toolbar ▾ W   not checked out · 4 commits ahead of main".
@MainActor
struct GitHeader: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The picker is open: the pill has become the picker's repository pill and the rest has
    /// slid out to the right. The row keeps its height.
    let open: Bool
    let pillSpace: Namespace.ID
    /// The sync pill travels to the stage's confirm in this space.
    let stageSpace: Namespace.ID
    /// The pill's width, for the outline that holds its place while it is away.
    @State private var pillWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            if !open {
                GitTargetPill(parts: state.gitTargetParts) { state.toggleGitPicker() }
                    .matchedGeometryEffect(id: GitTab.pillID, in: pillSpace, anchor: .leading)
                    .transition(.opacity)
                    .layoutPriority(2)
            }
            if !open {
                rest
                    .transition(Theme.Motion.pickerHeaderTransition)
            }
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.gitHeaderHeight)
    }

    /// The branch, the status and the sync pill.
    private var rest: some View {
        let phase = state.gitPhase
        return HStack(spacing: Theme.Size.spaceM) {
            if snap.checkedOut {
                Text(snap.branch ?? "detached HEAD")
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.gitBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            HStack(spacing: Theme.Size.spaceM) {
                status(phase)
                if snap.checkedOut && !state.gitTargetIsFocused {
                    Text("not the focused session")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.gitTargetNote)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pill(phase)
        }
    }

    /// The status line: a result drops the old line and rises in, and after its hold drops
    /// back out for the status (the stage swap's transition, run by the phase's animation).
    private func status(_ phase: GitPhase) -> some View {
        let text: String
        let font: Font
        let color: Color
        switch phase {
        case .idle, .confirming, .running:
            // The confirm asks in the stage; the status stays what it was.
            (text, font, color) = (state.gitStatusText, Theme.Fonts.caption, Theme.Colors.gitStatus)
        case .done(_, let message):
            (text, font, color) = (message, Theme.Fonts.captionMedium, Theme.Colors.gitPushed)
        case .failed(let op, let message):
            if op == .commit && state.gitDraft.composing {
                // The form says why, next to its Commit pill.
                (text, font, color) = (state.gitStatusText, Theme.Fonts.caption, Theme.Colors.gitStatus)
            } else {
                (text, font, color) = (message, Theme.Fonts.caption, Theme.Colors.gitError)
            }
        }
        return ZStack(alignment: .leading) {
            if !text.isEmpty {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .id(text)
                    .transition(Theme.Motion.paneSwapTransition)
            }
        }
    }

    /// The sync pill: "Push 3  P", "Pull 2  P", "Publish 4  P" in white, "Fetch  P" dark;
    /// away in the stage while a publish, push or pull is asked (an outline of its size stays
    /// here); pulsing while any write runs; a check and "Pushed" while a sync's result holds,
    /// so it cannot ask again for the commits just sent. After a commit or an undo the plain
    /// pill stays. Each look carries the travel id, so the one here is the one that travels;
    /// the running and done looks crossfade in place; the plain pill travels (`travelTransition`), so only one copy shows. Its count pops as it moves; a
    /// failed sync shakes it once.
    private func pill(_ phase: GitPhase) -> some View {
        let op = state.gitSyncOp
        let verb = state.gitSyncVerb
        let enabled = state.gitCanSync
        let role: ActionRole = enabled && op != .fetch ? .allow : .neutral
        var running: GitOp?
        var done: GitOp?
        var confirming = false
        switch phase {
        case .running(let o): running = o
        case .done(let o, _) where o != .commit && o != .undo: done = o
        case .confirming: confirming = true
        case .idle, .done, .failed: break
        }
        return ZStack(alignment: .trailing) {
            if let running {
                GitRunningPill(title: running.runningTitle)
                    .matchedGeometryEffect(id: GitTab.syncPillID, in: stageSpace)
                    .transition(.opacity)
            }
            if let done {
                GitDonePill(title: done.doneTitle)
                    .matchedGeometryEffect(id: GitTab.syncPillID, in: stageSpace)
                    .transition(.opacity)
            }
            if confirming {
                RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                    .strokeBorder(Theme.Colors.gitGhost, style: StrokeStyle(lineWidth: Theme.Size.gitGhostStroke, dash: Theme.Size.gitGhostDash))
                    .frame(width: pillWidth, height: Theme.Size.actionHeight)
                    .transition(.opacity)
            }
            if running == nil && done == nil && !confirming {
                ActionSegment(title: verb, key: Theme.Keys.push, role: role, count: state.gitSyncCount) { state.pressGitPill() }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : Theme.Opacity.disabled)
                    .help(enabled ? help(op) : state.gitStatusText)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                    .countPop(state.gitSyncCount)
                    .matchedGeometryEffect(id: GitTab.syncPillID, in: stageSpace)
                    .transition(Theme.Motion.travelTransition)
            }
        }
        .shake(trigger: syncFailure(phase))
    }

    /// A failed publish, push, pull or fetch's message: the pill shakes when one arrives.
    private func syncFailure(_ phase: GitPhase) -> String? {
        guard case .failed(let op, let message) = phase, op != .commit, op != .undo else { return nil }
        return message
    }

    private func help(_ op: GitOp?) -> String {
        let remote = snap.remote ?? ""
        switch op {
        case .fetch?: return "Fetch from " + remote
        case .pull?: return "Pull from " + (snap.upstream ?? remote) + " (asks first)"
        default: return (op ?? .push).verb + " this branch (asks first)"
        }
    }
}

/// "notchcode › seadevil ▾  W": the repository dim, then the worktree folder in ink (or the
/// branch in mono when it is checked out nowhere); a press opens the picker.
@MainActor
private struct GitTargetPill: View {
    let parts: (repo: String?, place: String, placeIsBranch: Bool)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.actionKeyGap) {
                HStack(spacing: Theme.Size.spaceS) {
                    if let repo = parts.repo {
                        Text(repo)
                            .font(Theme.Fonts.captionMedium)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                            .lineLimit(1)
                        Text(Theme.Glyphs.pathChevron)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                    }
                    Text(parts.place)
                        .font(parts.placeIsBranch ? Theme.Fonts.monoCaption : Theme.Fonts.action)
                        .foregroundStyle(Theme.Colors.gitTargetPlace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(Theme.Glyphs.pickerChevron)
                        .font(Theme.Fonts.tiny)
                        .foregroundStyle(Theme.Colors.gitTargetRepo)
                }
                InlineKeycap(Theme.Keys.worktree)
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .frame(maxWidth: Theme.Size.gitTargetMaxWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .layoutPriority(2)
        .help("Choose the branch (\(Theme.Keys.worktree))")
    }
}

/// The pill while git writes: Claude's pulsing spark and "Pushing", "Pulling", "Committing",
/// not pressable. The commit form's Commit pill turns into it too.
@MainActor
struct GitRunningPill: View {
    let title: String

    var body: some View {
        Button {} label: {
            HStack(spacing: Theme.Size.actionKeyGap) {
                SparkleGlyph(size: Theme.Size.gitPushingGlyph)
                Text(title)
                    .font(Theme.Fonts.action)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .disabled(true)
    }
}

/// The pill while a sync's result holds: the green check drawing itself and "Pushed",
/// "Pulled", "Fetched", not pressable. After the hold it crossfades to the plain pill.
@MainActor
private struct GitDonePill: View {
    let title: String

    var body: some View {
        Button {} label: {
            HStack(spacing: Theme.Size.actionKeyGap) {
                DoneCheckGlyph(size: Theme.Size.gitPushingGlyph)
                Text(title)
                    .font(Theme.Fonts.action)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .disabled(true)
    }
}
