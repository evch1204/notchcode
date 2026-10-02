// UsageTab.swift
// One fixed page, never scrolls, never changes shape with data. Row 1: the limit tiles,
// 5-hour, Week, one per model week ("Fable week") and Spend behind a gateway (percent, bar,
// reset). Row 2: context, with what the last call cached. Row 3: This session (tokens, cost,
// time, lines), Today (tokens, cost, Fable share), This week (where it went). Row 4: what's
// using your limits. Footer: where the numbers come from and how old they are. Unknown
// values show "—" in the same place; numbers are never invented.
//
// Sources: Claude Code's status line (limits, context, cost, time, lines, model), its usage
// cache in ~/.claude.json (model weeks, the week breakdown; refreshed by a headless
// `claude -p /usage` run, see AppState+PlanUsage) and the transcripts (tokens, today).

import SwiftUI

@MainActor
struct UsageTab: View {
    @ObservedObject var state: AppState
    /// Bars start empty and fill once the pane has landed.
    @State private var filled = false

    var body: some View {
        let usage = state.usage
        VStack(alignment: .leading, spacing: Theme.Size.usageRowSpacing) {
            limitsRow(usage)
                .frame(height: Theme.Size.usageLimitsRowHeight)

            ContextTile(
                percent: state.contextPercent,
                used: usage.contextUsed,
                limit: usage.contextLimit ?? AppState.standardContextLimit,
                facts: state.focusedStatusline,
                modelName: modelName,
                filled: filled
            )
            .frame(height: Theme.Size.usageContextRowHeight)

            HStack(spacing: Theme.Size.usageTileSpacing) {
                SmallTile(
                    title: "This session",
                    value: usage.sessionTokens.map { Format.tokens($0.total) },
                    detail: sessionDetail(usage),
                    tokens: usage.sessionTokens ?? TokenUsage(),
                    showsBar: true,
                    filled: filled
                )
                SmallTile(
                    title: "Today",
                    value: usage.todayTokens.map { Format.tokens($0.total) },
                    detail: todayDetail(usage),
                    filled: filled
                )
                SmallTile(
                    title: "This week",
                    value: usage.weekBreakdown.first.map(share),
                    detail: usage.weekBreakdown.isEmpty ? "from /usage" : weekRest(usage),
                    filled: filled
                )
            }
            .frame(height: Theme.Size.usageSessionRowHeight)

            BehaviorsTile(behaviors: state.usageBehaviors, note: state.planUsageNote)
                .frame(height: Theme.Size.usageBehaviorsRowHeight)

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

    // MARK: Rows

    /// 5-hour, Week, one tile per model week (a "Fable week" placeholder until the usage
    /// cache has been read), then Spend when the status line reports one.
    private func limitsRow(_ usage: UsageSnapshot) -> some View {
        HStack(spacing: Theme.Size.usageTileSpacing) {
            LimitTile(title: "5-hour", percent: usage.fiveHourPercent, resetsAt: usage.fiveHourResetsAt,
                      emptyNote: "connect the status line", filled: filled)
            LimitTile(title: "Week", percent: usage.weekPercent, resetsAt: usage.weekResetsAt,
                      emptyNote: "connect the status line", filled: filled)
            if usage.modelWeeks.isEmpty {
                LimitTile(title: "Fable week", percent: nil, resetsAt: nil, emptyNote: "from /usage", filled: filled)
            } else {
                ForEach(usage.modelWeeks) { week in
                    LimitTile(title: week.name + " week", percent: week.percent, resetsAt: week.resetsAt,
                              emptyNote: "from /usage", filled: filled)
                }
            }
            if let spend = usage.spendLimit {
                LimitTile(
                    title: "Spend",
                    percent: spend.percent,
                    resetsAt: spend.resetsAt,
                    emptyNote: " ",
                    detail: spend.usedUSD.flatMap { used in spend.limitUSD.map { Format.spend(used: used, limit: $0) } },
                    filled: filled
                )
            }
        }
    }

    /// "Fable 5.1" from the status line, else "Fable" from the model id.
    private var modelName: String? {
        if let name = state.focusedStatusline?.displayName { return name }
        guard let id = state.focusedSession?.id else { return nil }
        return state.modelShortName(for: id)?.capitalized
    }

    /// "$1.42 · 3h 27m · +2351 −147", unknown parts left out.
    private func sessionDetail(_ usage: UsageSnapshot) -> String? {
        let facts = state.focusedStatusline
        var parts: [String] = []
        if let costUSD = usage.sessionCostUSD {
            parts.append(cost(Format.money(costUSD), estimated: !state.sessionCostIsReported))
        }
        if let ms = facts?.durationMs { parts.append(Format.duration(Double(ms) / 1000)) }
        let lines = [facts?.linesAdded.map(Format.added), facts?.linesRemoved.map(Format.removed)].compactMap { $0 }
        if !lines.isEmpty { parts.append(lines.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: Theme.Glyphs.separator)
    }

    /// "~$12.40 · Fable 78%": today's cost, then today's Fable share of tokens (left out at zero).
    private func todayDetail(_ usage: UsageSnapshot) -> String? {
        var parts: [String] = []
        if let costUSD = usage.todayCostUSD { parts.append(cost(Format.money(costUSD), estimated: usage.costIsEstimate)) }
        if let fable = usage.todayFableTokens?.total, let total = usage.todayTokens?.total, fable > 0, total > 0 {
            parts.append("Fable " + Format.percent(Double(fable) / Double(total) * 100))
        }
        return parts.isEmpty ? nil : parts.joined(separator: Theme.Glyphs.separator)
    }

    /// "Claude Code 98%".
    private func share(_ row: NamedShare) -> String {
        row.name + " " + Format.percent(row.percent)
    }

    /// "Chats 2%": the breakdown after its first row, the ones above zero.
    private func weekRest(_ usage: UsageSnapshot) -> String? {
        let rest = usage.weekBreakdown.dropFirst().filter { $0.percent > 0 }
        return rest.isEmpty ? nil : rest.map(share).joined(separator: Theme.Glyphs.separator)
    }

    /// "cost from Claude Code · limits updated 3m ago · plan usage 8m ago".
    private func footnote(now: Date) -> String {
        let costPart = state.sessionCostIsReported ? "cost from Claude Code" : "cost estimated from tokens"
        let limits = state.limitsUpdatedAt.map { Format.limitsAsOf($0, now: now) }
            ?? "limits from Claude Code's status line"
        let plan: String
        if state.planUsageRefreshing {
            plan = "plan usage refreshing" + Theme.Glyphs.ellipsis
        } else if let note = state.planUsageNote {
            plan = note
        } else if !state.prefs.planUsageRefresh {
            plan = "plan usage off in Settings"
        } else if let fetched = state.planUsage?.fetchedAt {
            plan = "plan usage " + Format.ago(fetched, now: now)
        } else {
            plan = "plan usage from /usage"
        }
        return [costPart, limits, plan].joined(separator: Theme.Glyphs.separator)
    }

    /// "~$1.42" when estimated from tokens, "$1.42" when Claude Code reported it.
    private func cost(_ text: String, estimated: Bool) -> String {
        estimated ? Theme.Glyphs.estimate + text : text
    }
}

/// "5-hour", "61%" large, a bar, "resets in 1h 52m". Before any limit has arrived: "—",
/// an empty bar and `emptyNote`, in the same places. When the window has rolled over since
/// the last report, the old percent dims and the line says when it reset. The bar turns clay
/// at `Theme.Limits.limitWarnPercent`.
@MainActor
private struct LimitTile: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?
    let emptyNote: String
    /// Replaces the reset line while the window is current ("$12.40 of $50").
    var detail: String? = nil
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
                    .minimumScaleFactor(Theme.Size.footerMinScale)
                UsageBar(fraction: filled ? (percent ?? 0) / 100 : 0, tint: tint)
                Text(footnote)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var hasReset: Bool { AppState.limitWindowHasReset(resetsAt) }

    private var tint: Color {
        (percent ?? 0) >= Theme.Limits.limitWarnPercent ? Theme.Colors.limitBarHigh : Theme.Colors.limitBar
    }

    private var footnote: String {
        guard percent != nil else { return emptyNote }
        if hasReset, let resetsAt { return Format.resetAt(resetsAt) }
        if let detail { return detail }
        // A blank line keeps the tile's layout identical when no reset time is known.
        return resetsAt.map { Format.resets(at: $0) } ?? " "
    }
}

private struct TokenSegment: Identifiable {
    let id: String
    let label: String
    let count: Int
    let color: Color
}

/// "Context · Fable 5.1 · effort high · thinking · past 200k" with "36% · 357k of 1M" at the
/// right; an 8 pt bar filled to the percent, split by the last call's input side (cached, new
/// to cache, fresh) when the status line sent it; the legend and "643k free".
@MainActor
private struct ContextTile: View {
    let percent: Double?
    let used: Int?
    let limit: Int
    let facts: StatuslineFacts?
    let modelName: String?
    let filled: Bool

    /// The last call's input side, when known.
    private var segments: [TokenSegment]? {
        guard let current = facts?.currentUsage else { return nil }
        return [
            TokenSegment(id: "cacheRead", label: "cached", count: current.cacheRead, color: Theme.Colors.tokenCacheRead),
            TokenSegment(id: "cacheWrite", label: "new to cache", count: current.cacheWrite, color: Theme.Colors.tokenCacheWrite),
            TokenSegment(id: "input", label: "fresh", count: current.input, color: Theme.Colors.tokenInput),
        ]
    }

    var body: some View {
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true) {
            VStack(alignment: .leading, spacing: Theme.Size.usageLineSpacing) {
                HStack(spacing: Theme.Size.spaceM) {
                    headline
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Size.spaceM)
                    Text(amount ?? Theme.Glyphs.emDash)
                        .font(Theme.Fonts.captionMedium)
                        .foregroundStyle(amount == nil ? Theme.Colors.inkTertiary : Theme.Colors.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                bar
                legend
            }
        }
    }

    /// "Context" then the model and its modes, "past 200k" in clay.
    private var headline: Text {
        var details: [String] = []
        if let modelName { details.append(modelName) }
        if let effort = facts?.effort { details.append("effort " + effort) }
        if facts?.thinkingEnabled == true { details.append("thinking") }
        if facts?.fastMode == true { details.append("fast") }
        var text = Text("Context")
            .font(Theme.Fonts.captionMedium)
            .foregroundStyle(Theme.Colors.inkSecondary)
        if !details.isEmpty {
            text = text + Text(Theme.Glyphs.separator + details.joined(separator: Theme.Glyphs.separator))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        }
        if facts?.exceeds200k == true {
            text = text
                + Text(Theme.Glyphs.separator).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.inkTertiary)
                + Text("past 200k").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.limitBarHigh)
        }
        return text
    }

    /// "36% · 357k of 1M", or "36% of 1M" without a token count.
    private var amount: String? {
        guard let percent else { return nil }
        let of = " of " + Format.tokens(limit)
        guard let used else { return Format.percent(percent) + of }
        return Format.percent(percent) + Theme.Glyphs.separator + Format.tokens(used) + of
    }

    private var bar: some View {
        let fraction = CGFloat(min(max((percent ?? 0) / 100, 0), 1)) * (filled ? 1 : 0)
        let parts = segments
        let total = parts.map { $0.reduce(0) { $0 + $1.count } } ?? 0
        return GeometryReader { geo in
            let width = geo.size.width * fraction
            HStack(spacing: 0) {
                if let parts, total > 0 {
                    ForEach(parts) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: width * CGFloat(segment.count) / CGFloat(total))
                    }
                } else {
                    Rectangle()
                        .fill(Theme.Colors.contextBar)
                        .frame(width: width)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(Theme.Colors.track)
        }
        .frame(height: Theme.Size.tokenBarHeight)
        .clipShape(Capsule(style: .continuous))
    }

    private var legend: some View {
        HStack(spacing: Theme.Size.usageLegendSpacing) {
            if let parts = segments {
                ForEach(parts) { segment in
                    HStack(spacing: Theme.Size.spaceS) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: Theme.Size.legendDot, height: Theme.Size.legendDot)
                        Text(segment.label)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        Text(Format.tokens(segment.count))
                            .foregroundStyle(Theme.Colors.inkSecondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
            // A blank line keeps the height when nothing is known.
            Text(used.map { Format.tokens(max(0, limit - $0)) + " free" } ?? " ")
                .foregroundStyle(Theme.Colors.inkTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(Theme.Fonts.tiny)
    }
}

/// "This session", "357k" (semibold), an optional 6 pt four-part token bar, a caption.
/// The bar's slot is kept empty in tiles without one, so the row's lines line up.
@MainActor
private struct SmallTile: View {
    let title: String
    let value: String?
    let detail: String?
    var tokens = TokenUsage()
    var showsBar = false
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
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true, verticalPadding: Theme.Size.usageCompactPadding) {
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
                Group {
                    if showsBar { tokenBar } else { Color.clear }
                }
                .frame(height: Theme.Size.usageMiniBarHeight)
                Text(detail ?? " ")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var tokenBar: some View {
        let total = tokens.total
        return GeometryReader { geo in
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
        .clipShape(Capsule(style: .continuous))
    }
}

/// "Last 24h · 155 requests · 2 sessions" with the week's counts at the right, then the
/// day's behaviours on one line ("94% from subagent-heavy sessions · 82% at >150k context").
@MainActor
private struct BehaviorsTile: View {
    let behaviors: UsageBehaviors?
    let note: String?

    var body: some View {
        let day = behaviors?.day
        let lines = (day ?? behaviors?.week)?.lines ?? []
        InsetGroup(radius: Theme.Radius.tile, fillsHeight: true, verticalPadding: Theme.Size.usageCompactPadding) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Size.spaceM) {
                    Text(day.map(Format.behaviorPeriod) ?? "What's using your limits")
                        .font(Theme.Fonts.captionMedium)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Size.spaceM)
                    if let week = behaviors?.week {
                        Text(Format.behaviorPeriod(week))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(lines.isEmpty
                     ? (note ?? "from /usage")
                     : lines.map(Format.behavior).joined(separator: Theme.Glyphs.separator))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
