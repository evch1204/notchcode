// UsageTab.swift
// One fixed page, never scrolls. Row 1: two big tiles, 5-hour and Week (percent, bar,
// reset). Row 2: four small tiles, Context, This session, Today, Fable. Row 3: one four-part
// token bar with inline legend chips. Footer: where the numbers come from, and how
// old the limits are. Limits keep their last known value between status line reports
// (it only reports when Claude Code redraws it); "—" and "connect the status line"
// only until the first report. Numbers are never invented, and the layout never changes.

import SwiftUI

@MainActor
struct UsageTab: View {
    @ObservedObject var state: AppState
    /// Bars start empty and fill once the pane has landed.
    @State private var filled = false

    var body: some View {
        let usage = state.usage
        VStack(alignment: .leading, spacing: Theme.Size.usageRowSpacing) {
            HStack(spacing: Theme.Size.usageTileSpacing) {
                LimitTile(
                    title: "5-hour",
                    percent: usage.fiveHourPercent,
                    resetsAt: usage.fiveHourResetsAt,
                    filled: filled
                )
                LimitTile(
                    title: "Week",
                    percent: usage.weekPercent,
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
                fableTile(usage)
            }
            .frame(height: Theme.Size.usageSmallTileHeight)

            TokenBlock(tokens: usage.sessionTokens ?? TokenUsage(), filled: filled)
                .frame(height: Theme.Size.usageTokenBlockHeight)

            // "updated 3m ago" has to age on its own while the status line is quiet.
            TimelineView(.periodic(from: .now, by: Theme.Timing.limitsFootnoteTick)) { context in
                Text(footnote(now: context.date))
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// Today's tokens on Fable models, "~$9.80 · 78%" (cost, share of today's tokens).
    /// No weekly Fable percent: the status line forwards no per-model window.
    private func fableTile(_ usage: UsageSnapshot) -> some View {
        let fable = usage.todayFableTokens
        let todayTotal = usage.todayTokens?.total ?? 0
        let detail = usage.todayFableCostUSD.map { costUSD -> String in
            let text = cost(Format.money(costUSD), estimated: usage.costIsEstimate)
            guard let fable, todayTotal > 0 else { return text }
            return text + Theme.Glyphs.separator + Format.percent(Double(fable.total) / Double(todayTotal) * 100)
        }
        return SmallTile(
            title: "Fable",
            value: fable.map { Format.tokens($0.total) },
            detail: detail
        )
    }

    /// "cost estimated from tokens · limits updated 3m ago" once limits have arrived;
    /// before that, where they will come from.
    private func footnote(now: Date) -> String {
        let limits = state.limitsUpdatedAt.map { Format.limitsAsOf($0, now: now) }
            ?? "limits from Claude Code's status line"
        return "cost estimated from tokens" + Theme.Glyphs.separator + limits
    }

    /// "~$1.42" when estimated from tokens, "$1.42" when Claude Code reported it.
    private func cost(_ text: String, estimated: Bool) -> String {
        estimated ? Theme.Glyphs.estimate + text : text
    }
}

/// "5-hour", "61%" large, a bar, "resets in 1h 52m". Before any limit has arrived: "—",
/// an empty bar, and "connect the status line", in the same places. When the window has
/// rolled over since the last report, the old percent dims and the line says when it reset.
@MainActor
private struct LimitTile: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?
    let filled: Bool

    var body: some View {
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true) {
            VStack(alignment: .leading, spacing: Theme.Size.usageLineSpacing) {
                Text(title)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(percent.map { Format.percent(min(100, $0)) } ?? Theme.Glyphs.emDash)
                    .font(Theme.Fonts.bigNumber)
                    .foregroundStyle(percent == nil || hasReset ? Theme.Colors.inkTertiary : Theme.Colors.ink)
                    .lineLimit(1)
                UsageBar(fraction: filled ? (percent ?? 0) / 100 : 0, tint: Theme.Colors.limitBar)
                Text(footnote)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var hasReset: Bool { AppState.limitWindowHasReset(resetsAt) }

    private var footnote: String {
        guard percent != nil else { return "connect the status line" }
        if hasReset, let resetsAt { return Format.resetAt(resetsAt) }
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
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true) {
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
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true) {
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
