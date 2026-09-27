// RestingView.swift
// Sessions exist but none works or needs the owner. Left: a static dot in the
// session's colour (green done, grey idle) and the worktree name at 60%. Right:
// "+N" only when other sessions exist. Nothing moves. Hover brightens the name
// (the root view lights the rim); a click opens the card.

import SwiftUI

@MainActor
struct RestingView: View {
    @ObservedObject var state: AppState
    let bodySize: CGSize

    var body: some View {
        let session = state.primarySession
        let others = state.otherSessionCount(besides: session)
        WingRow(layout: state.layout, bodyWidth: bodySize.width) {
            HStack(spacing: Theme.Size.wingSpacing) {
                Circle()
                    .fill(session?.state == .done ? Theme.Colors.restingDone : Theme.Colors.restingIdle)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
                    .frame(width: Theme.Size.glyph, height: Theme.Size.glyph)
                Text(session?.displayFull ?? "notchcode")
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.wingsName)
                    .opacity(state.hovering ? Theme.Opacity.restingHover : Theme.Opacity.resting)
                    .animation(state.hovering ? Theme.Motion.rimIn : Theme.Motion.rimOut, value: state.hovering)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } right: {
            if others > 0 {
                Text(others == 1 ? "+1 session" : "+\(others) sessions")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.wingsCountText)
                    .lineLimit(1)
                    .help(others == 1 ? "1 other session" : "\(others) other sessions")
            }
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleFromNotchTap() }
    }
}
