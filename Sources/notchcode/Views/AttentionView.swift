// AttentionView.swift
// Two rows, clay. Row 1 in the wings: Needs you · session · countdown; a click
// opens the card with the request in the well. Row 2 below the notch: what
// Claude wants on the left ("Allow Bash?" and the command), and the answers on
// the right as toolbar segments (Deny · Always · Allow, or Skip · Edit · Commit),
// the countdown draining along Allow. One press answers without opening anything.

import SwiftUI

@MainActor
struct AttentionView: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    let bodySize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            WingRow(layout: state.layout, bodyWidth: bodySize.width) {
                HStack(spacing: Theme.Size.wingSpacing) {
                    BreathingTriangle()
                    Text("Needs you")
                        .font(Theme.Fonts.captionMedium)
                        .foregroundStyle(Theme.Colors.attentionText)
                        .lineLimit(1)
                }
            } right: {
                HStack(spacing: Theme.Size.wingSpacing) {
                    Text(state.session(id: request.sessionId)?.displayFull ?? "")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    DeadlineCountdown(request: request)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { state.openCard() }
            .help("Open the card (\(Theme.Keys.option) \(Theme.Keys.space))")

            HStack(spacing: Theme.Size.spaceM) {
                HStack(spacing: Theme.Size.spaceM) {
                    // Never fixed-size: a long tool name must not push Allow out of the clip.
                    Text(request.headline)
                        .font(Theme.Fonts.bodySemibold)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(request.summary)
                        .font(Theme.Fonts.monoCaption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { state.openCard() }

                ActionStrip(state: state, request: request, allKeys: true)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.horizontal, Theme.Size.sidePadding)
            .frame(width: bodySize.width, height: Theme.Size.attentionExtraHeight)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
    }

}
