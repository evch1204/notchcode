// GitHeader.swift
// The Git tool's header row: the target pill, the branch, where it stands against its
// upstream, and the Push pill (pulsing while git pushes).

import SwiftUI

// MARK: - Header

/// "notchcode › seadevil ▾ W   user-friendly-distribution-plan   [Push 3  P]", or a push's
/// result in the status's place. While the push is asked the pill stays put, armed with ⏎
/// (the question is in the diff pane); while it runs the pill pulses. A branch checked out nowhere:
/// "notchcode › design/toolbar ▾ W   not checked out · 4 commits ahead of main".
@MainActor
struct GitHeader: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The picker is open: the pill has become the picker's repository pill and the rest has
    /// slid out to the right. The row keeps its height.
    let open: Bool
    let pillSpace: Namespace.ID

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

    /// The branch, the status and the Push pill.
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

    @ViewBuilder
    private func status(_ phase: GitPushPhase) -> some View {
        switch phase {
        case .idle, .confirming, .pushing:
            // The confirm asks in the diff pane; the status stays what it was.
            line(state.gitStatusText, font: Theme.Fonts.caption, color: Theme.Colors.gitStatus)
        case .pushed(let message):
            line(message, font: Theme.Fonts.captionMedium, color: Theme.Colors.gitPushed)
        case .failed(let message):
            line(message, font: Theme.Fonts.caption, color: Theme.Colors.gitError)
                .help(message)
        }
    }

    @ViewBuilder
    private func line(_ text: String, font: Font, color: Color) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The Push pill, in the same place in every phase: "Push 3  P"; armed with ⏎ while the
    /// push is asked (it pops once as it arms, the keycap crossfading); pulsing while git
    /// pushes. The three overlap so each swap is a crossfade in place.
    private func pill(_ phase: GitPushPhase) -> some View {
        let verb = state.gitPushVerb
        let enabled = state.gitCanPush
        return ZStack(alignment: .trailing) {
            if phase == .pushing {
                GitPushingPill(title: verb == "Publish" ? "Publishing" : "Pushing")
                    .transition(.opacity)
            }
            if phase == .confirming {
                ActionSegment(title: verb, key: Theme.Keys.enter, role: .allow, count: state.gitPushCount) { state.pressGitPill() }
                    .help(state.gitConfirmText)
                    .popIn()
                    .transition(.opacity)
            }
            if phase != .pushing && phase != .confirming {
                ActionSegment(title: verb, key: Theme.Keys.push, role: enabled ? .allow : .neutral, count: state.gitPushCount) { state.pressGitPill() }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : Theme.Opacity.disabled)
                    .help(enabled ? verb + " this branch (asks first)" : state.gitStatusText)
                    .transition(.opacity)
            }
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

/// The pill while git pushes: Claude's pulsing spark and "Pushing", not pressable.
@MainActor
private struct GitPushingPill: View {
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
