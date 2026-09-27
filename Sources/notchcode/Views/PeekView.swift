// PeekView.swift
// One line when something completes: a finished turn ("Done · ponyfish", its
// files and ± totals), a finished subagent, or (opt-in) a single file edit.
// A thin white line at the bottom shrinks over the peek's lifetime.
// Done: the check circle pops and draws on, and the ± counts count up. After the
// peek, the notch settles into Resting (AppState's mode rule).

import SwiftUI

@MainActor
struct PeekView: View {
    @ObservedObject var state: AppState
    let peek: Peek
    let bodySize: CGSize
    @State private var remaining: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            WingRow(layout: state.layout, bodyWidth: bodySize.width) {
                left
            } right: {
                right
            }
            Rectangle()
                .fill(Theme.Colors.ink)
                .frame(width: bodySize.width * remaining, height: Theme.Size.peekLine)
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .contentShape(Rectangle())
        .onTapGesture { state.tapPeek(peek) }
        .onAppear {
            remaining = 1
            withAnimation(.linear(duration: state.prefs.peekSeconds)) { remaining = 0 }
        }
    }

    @ViewBuilder
    private var left: some View {
        HStack(spacing: Theme.Size.wingSpacing) {
            switch peek.kind {
            case .edit:
                CircleGlyph(symbol: Theme.Symbols.diff, tint: Theme.Colors.green)
                Text(peek.title)
                    .font(Theme.Fonts.monoCaption)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .done:
                DoneCheckGlyph()
                Text(peek.title)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .agent:
                AgentSquare(colorIndex: peek.colorIndex ?? 0)
                Text(peek.title)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var right: some View {
        HStack(spacing: Theme.Size.spaceS) {
            switch peek.kind {
            case .edit:
                if let added = peek.added {
                    CountPill(text: Format.added(added), tint: Theme.Colors.green, fill: Theme.Colors.greenFill)
                }
                if let removed = peek.removed {
                    CountPill(text: Format.removed(removed), tint: Theme.Colors.red, fill: Theme.Colors.redFill)
                }
                if let detail = peek.detail {
                    Text(detail)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .lineLimit(1)
                }
            case .done:
                if let detail = peek.detail {
                    Text(detail)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                }
                if let added = peek.added {
                    CountUpPill(count: added, format: Format.added, tint: Theme.Colors.green, fill: Theme.Colors.greenFill)
                }
                if let removed = peek.removed {
                    CountUpPill(count: removed, format: Format.removed, tint: Theme.Colors.red, fill: Theme.Colors.redFill)
                }
            case .agent:
                Text(state.session(id: peek.sessionId)?.displayFull ?? "")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
