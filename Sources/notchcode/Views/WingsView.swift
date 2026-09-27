// WingsView.swift
// The collapsed state, readable in one glance. Left: a state glyph and the
// focused session's worktree name. Right: one word of state, then "· 2 agents"
// while that session runs subagents and "+1" for each other live session.
// No clock here: the only timer in the collapsed states is the permission
// countdown in the two-row attention state. Nothing is drawn over the camera.

import SwiftUI

@MainActor
struct WingsView: View {
    @ObservedObject var state: AppState
    let bodySize: CGSize

    var body: some View {
        let session = state.primarySession
        let shown = session.map { state.shownState($0) } ?? .idle
        WingRow(layout: state.layout, bodyWidth: bodySize.width) {
            left(session: session, shown: shown)
        } right: {
            right(session: session, shown: shown)
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleFromNotchTap() }
    }

    private func left(session: Session?, shown: SessionState) -> some View {
        HStack(spacing: Theme.Size.wingSpacing) {
            WingStateGlyph(state: shown)
            Text(session?.displayFull ?? "notchcode")
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(Theme.Colors.wingsName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Right wing: the agent count when subagents run, else a state word only when it says
    /// something the glyph does not (Needs you, Done), then "+N" for other live sessions.
    private func right(session: Session?, shown: SessionState) -> some View {
        let agents = (state.prefs.showAgentsInWings && session != nil) ? state.runningAgents(for: session!.id).count : 0
        let others = state.otherLiveSessionCount(besides: session)
        let showWord = agents == 0 && (shown == .needsYou || shown == .done)
        return HStack(spacing: Theme.Size.wingSpacing) {
            if agents > 0 {
                Text(Format.agents(agents))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.wingsCountText)
                    .lineLimit(1)
                    .layoutPriority(2)
            } else if showWord {
                Text(Format.stateWord(shown, verb: session?.verb))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(wordColor(shown))
                    .lineLimit(1)
                    .layoutPriority(2)
            }
            if others > 0 {
                Text(others == 1 ? "+1 session" : "+\(others) sessions")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.wingsCountText)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(others == 1 ? "1 other session" : "\(others) other sessions")
            }
        }
    }

    private func wordColor(_ shown: SessionState) -> Color {
        switch shown {
        case .needsYou: return Theme.Colors.attentionText
        case .working: return Theme.Colors.wingsWorkingText
        case .done: return Theme.Colors.wingsDoneText
        case .idle: return Theme.Colors.wingsIdleText
        }
    }
}

/// Spark pulsing while working, clay triangle when it needs you, green check when done, dim dot when idle.
@MainActor
private struct WingStateGlyph: View {
    let state: SessionState

    var body: some View {
        Group {
            switch state {
            case .working:
                SparkleGlyph(pulsing: true)
            case .needsYou:
                BreathingTriangle()
            case .done:
                Image(systemName: Theme.Symbols.done)
                    .font(Theme.Fonts.symbol(Theme.Size.glyph))
                    .foregroundStyle(Theme.Colors.doneGlyph)
            case .idle:
                Circle()
                    .fill(Theme.Colors.idleGlyph)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
            }
        }
        .frame(width: Theme.Size.glyph, height: Theme.Size.glyph)
    }
}
