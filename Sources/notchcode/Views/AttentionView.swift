// AttentionView.swift
// Two rows, amber. Row 1 in the wings: Action required · session · countdown.
// Row 2 below the notch: what Claude wants, and how to open the card.

import SwiftUI

@MainActor
struct AttentionView: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    let bodySize: CGSize

    var body: some View {
        Button {
            state.openCard()
        } label: {
            VStack(spacing: 0) {
                WingRow(layout: state.layout, bodyWidth: bodySize.width) {
                    HStack(spacing: Theme.Size.wingSpacing) {
                        BreathingTriangle()
                        Text("Action required")
                            .font(Theme.Fonts.captionMedium)
                            .foregroundStyle(Theme.Colors.amberText)
                            .lineLimit(1)
                    }
                } right: {
                    HStack(spacing: Theme.Size.wingSpacing) {
                        Text(state.session(id: request.sessionId)?.displayName ?? "")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        DeadlineCountdown(request: request)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }

                HStack(spacing: Theme.Size.spaceM) {
                    Text(question)
                        .font(Theme.Fonts.bodySemibold)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .fixedSize()
                    Text(summary)
                        .font(Theme.Fonts.monoCaption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Size.spaceM)
                    HStack(spacing: Theme.Size.spaceS) {
                        Text("click or")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        Keycap(Theme.Keys.option)
                        Keycap(Theme.Keys.space)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, Theme.Size.sidePadding)
                .frame(width: bodySize.width, height: Theme.Size.attentionExtraHeight)
            }
            .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var question: String {
        request.kind == .commit ? "Commit?" : "Allow \(request.tool)?"
    }

    private var summary: String {
        request.kind == .commit ? request.title : request.detail
    }
}
