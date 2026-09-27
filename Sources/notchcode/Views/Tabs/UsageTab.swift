// UsageTab.swift
// One fixed page, never scrolls. Row 1: two big tiles, 5-hour and Week (percent, bar,
// reset). Row 2: three small tiles, Context, This session, Today. Row 3: one four-part
// token bar with inline legend chips. Footer: where the numbers come from.
// Numbers are never invented: a missing value shows "—", and the layout never changes.

import SwiftUI

@MainActor
struct UsageTab: View {
    @ObservedObject var state: AppState
    /// Bars start empty and fill once the pane has landed.
    @State private var filled = false

    var body: some View {
        let usage = state.usage
        let fresh = state.limitsAreFresh
        VStack(alignment: .leading, spacing: Theme.Size.usageRowSpacing) {
            HStack(spacing: Theme.Size.usageTileSpacing) {
                LimitTile(
                    title: "5-hour",
                    percent: fresh ? usage.fiveHourPercent : nil,
                    resetsAt: usage.fiveHourResetsAt,
                    filled: filled
                )
                LimitTile(
                    title: "Week",
                    percent: fresh ? usage.weekPercent : nil,
                    resetsAt: usage.weekResetsAt,
                    filled: filled
                )
            }
            .frame(height: Theme.Size.usageBigTileHeight)

            HStack(spacing: Theme.Size.usageTileSpacing) {
                contextTile(usage)
                SmallTile(
                    title: "This session",
                    value: usage.sessionTokens.map { Format.tokens($0.total) },
                    detail: usage.sessionCostUSD.map { cost(Format.money($0), estimated: !state.sessionCostIsReported) }
                )
                SmallTile(
                    title: "Today",
                    value: usage.todayTokens.map { Format.tokens($0.total) },
                    detail: usage.todayCostUSD.map { cost(Format.money($0), estimated: usage.costIsEstimate) }
                )
            }
            .frame(height: Theme.Size.usageSmallTileHeight)

            TokenBlock(tokens: usage.sessionTokens ?? TokenUsage(), filled: filled)
                .frame(height: Theme.Size.usageTokenBlockHeight)

            Text("cost estimated from tokens" + Theme.Glyphs.separator + "limits from Claude Code's status line")
                .font(Theme.Fonts.tiny)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Size.usageFootnoteHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if Theme.Motion.reduceMotion {
                filled = true
            } else {
                withAnimation(Theme.Motion.barFill) { filled = true }
            }
        }
    }

    private func contextTile(_ usage: UsageSnapshot) -> some View {
        let percent = state.contextPercent
        let limit = usage.contextLimit ?? AppState.standardContextLimit
        return SmallTile(
            title: "Context",
            value: percent.map { Format.percent($0) + " of " + Format.tokens(limit) },
            detail: usage.contextUsed.map { Format.tokens($0) }
        )
    }

    /// "~$1.42" when estimated from tokens, "$1.42" when Claude Code reported it.
    private func cost(_ text: String, estimated: Bool) -> String {
        estimated ? Theme.Glyphs.estimate + text : text
    }
}

/// A tile's frame: the inset fill, padding, and the pane parallax.
@MainActor
private struct Tile<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.Size.tilePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(Theme.Colors.inset)
            )
            .parallaxGroup()
    }
}

/// "5-hour", "61%" large, a bar, "resets in 1h 52m". Without a limit: "—", an empty bar,
/// and "connect the status line", in the same places.
@MainActor
private struct LimitTile: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?
    let filled: Bool

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: Theme.Size.usageLineSpacing) {
                Text(title)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(percent.map { Format.percent(min(100, $0)) } ?? Theme.Glyphs.emDash)
                    .font(Theme.Fonts.bigNumber)
                    .foregroundStyle(percent == nil ? Theme.Colors.inkTertiary : Theme.Colors.ink)
                    .lineLimit(1)
                UsageBar(fraction: filled ? (percent ?? 0) / 100 : 0, tint: Theme.Colors.limitBar)
                Text(footnote)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var footnote: String {
        guard percent != nil else { return "connect the status line" }
        // A blank line keeps the tile's layout identical when no reset time is known.
        return resetsAt.map { Format.resets(at: $0) } ?? " "
    }
}

/// "Context", "36% of 1M", "357k".
@MainActor
private struct SmallTile: View {
    let title: String
    let value: String?
    let detail: String?

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: Theme.Size.usageLineSpacing) {
                Text(title)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value ?? Theme.Glyphs.emDash)
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(value == nil ? Theme.Colors.inkTertiary : Theme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(Theme.Size.footerMinScale)
                Text(detail ?? " ")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct TokenSegment: Identifiable {
    let id: String
    let label: String
    let count: Int
    let color: Color
}

/// This session's tokens: one 8 pt four-part bar, then four inline legend chips.
@MainActor
private struct TokenBlock: View {
    let tokens: TokenUsage
    let filled: Bool

    private var segments: [TokenSegment] {
        [
            TokenSegment(id: "input", label: "input", count: tokens.input, color: Theme.Colors.tokenInput),
            TokenSegment(id: "output", label: "output", count: tokens.output, color: Theme.Colors.tokenOutput),
            TokenSegment(id: "cacheRead", label: "cache read", count: tokens.cacheRead, color: Theme.Colors.tokenCacheRead),
            TokenSegment(id: "cacheWrite", label: "cache write", count: tokens.cacheWrite, color: Theme.Colors.tokenCacheWrite),
        ]
    }

    var body: some View {
        let total = tokens.total
        Tile {
            VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        if total > 0 {
                            ForEach(segments) { segment in
                                Rectangle()
                                    .fill(segment.color)
                                    .frame(width: geo.size.width * CGFloat(segment.count) / CGFloat(total))
                            }
                        }
                    }
                    .frame(width: geo.size.width * (filled ? 1 : 0), alignment: .leading)
                    .clipped()
                    .frame(width: geo.size.width, alignment: .leading)
                    .background(Theme.Colors.track)
                }
                .frame(height: Theme.Size.tokenBarHeight)
                .clipShape(Capsule(style: .continuous))

                HStack(spacing: Theme.Size.usageLegendSpacing) {
                    ForEach(segments) { segment in
                        HStack(spacing: Theme.Size.spaceS) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: Theme.Size.legendDot, height: Theme.Size.legendDot)
                            Text(segment.label)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                            Text(Format.tokens(segment.count))
                                .foregroundStyle(Theme.Colors.inkSecondary)
                        }
                        .font(Theme.Fonts.tiny)
                        .lineLimit(1)
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
