// AppState+Usage.swift
// The Usage tool's derived values: status line facts, context limits and the usage snapshot.

import AppKit
import SwiftUI

/// What Claude Code's status line input said about one session. Every field optional.
struct StatuslineFacts: Equatable {
    var contextPercent: Double?
    var contextUsed: Int?
    var contextLimit: Int?
    var costUSD: Double?
    var model: String?
    /// "Fable 5.1": `model.display_name`.
    var displayName: String?
    /// `effort.level`: "low" … "max", only for models that have it.
    var effort: String?
    var thinkingEnabled: Bool?
    var fastMode: Bool?
    var exceeds200k: Bool?
    /// `cost.total_duration_ms` and `cost.total_api_duration_ms`.
    var durationMs: Int?
    var apiDurationMs: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    /// The last API call's `context_window.current_usage`.
    var currentUsage: TokenUsage?
    var updatedAt: Date
}

extension AppState {

    /// "fable", "opus", "sonnet", "haiku" from the model of the newest turn that names one.
    func modelShortName(for sessionId: String) -> String? {
        let model = statusline[sessionId]?.model ?? turns(for: sessionId).lazy.compactMap { $0.model }.first
        return Self.modelShortName(model)
    }

    static func modelShortName(_ model: String?) -> String? {
        guard let m = model?.lowercased() else { return nil }
        return ["fable", "opus", "sonnet", "haiku"].first { m.contains($0) }
    }

    /// Context used as 0-100, never above 100. Nil when unknown.
    var contextPercent: Double? {
        if let id = focusedSession?.id, let percent = statusline[id]?.contextPercent { return min(100, percent) }
        guard let used = usage.contextUsed, let limit = usage.contextLimit, limit > 0 else { return nil }
        return min(100, Double(used) / Double(limit) * 100)
    }

    /// What the status line last said about the focused session.
    var focusedStatusline: StatuslineFacts? {
        focusedSession.flatMap { statusline[$0.id] }
    }

    /// The focused session's cost came from Claude Code, not from our rate table.
    var sessionCostIsReported: Bool {
        guard let id = focusedSession?.id else { return false }
        return statusline[id]?.costUSD != nil
    }

    /// Claude Code's status line input: `rate_limits.five_hour` / `seven_day` ({used_percentage, resets_at}),
    /// `rate_limits.spend_limit` (gateways only), `context_window` ({used_percentage} or {used, limit}),
    /// `cost`, `model`, `effort.level`, `thinking.enabled`, `fast_mode`, `exceeds_200k_tokens`.
    func handleStatusline(_ payload: JSONValue, sessionId sid: String) {
        let now = Date()
        func resets(_ value: JSONValue?) -> Date? {
            value?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        }

        let limits = payload["rate_limits"]
        let fiveHour = limits?["five_hour"]
        let week = limits?["seven_day"]
        var next = usage
        var gotLimits = false
        if let percent = fiveHour?["used_percentage"]?.doubleValue {
            next.fiveHourPercent = min(100, max(0, percent))
            next.fiveHourResetsAt = resets(fiveHour?["resets_at"])
            gotLimits = true
        }
        if let percent = week?["used_percentage"]?.doubleValue {
            next.weekPercent = min(100, max(0, percent))
            next.weekResetsAt = resets(week?["resets_at"])
            gotLimits = true
        }
        if let spend = limits?["spend_limit"], let percent = spend["used_percentage"]?.doubleValue {
            next.spendLimit = SpendLimit(
                percent: min(100, max(0, percent)),
                resetsAt: resets(spend["resets_at"]),
                usedUSD: spend["used_usd"]?.doubleValue,
                limitUSD: spend["limit_usd"]?.doubleValue,
                period: spend["period"]?.stringValue
            )
        }
        if gotLimits { limitsUpdatedAt = now }
        if next != usage { usage = next }

        let context = payload["context_window"]
        var facts = StatuslineFacts(updatedAt: now)
        facts.contextPercent = context?["used_percentage"]?.doubleValue.map { min(100, max(0, $0)) }
        // Tokens in context: the latest response's input side (input + cache write + cache
        // read in `current_usage`), else `total_input_tokens`; `used` / `limit` are fallbacks
        // no Claude Code version was seen to send.
        let current = context?["current_usage"]
        let inputSide = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { current?[$0]?.intValue }
        let latest = inputSide.isEmpty ? nil : inputSide.reduce(0, +)
        facts.contextUsed = latest ?? (context?["total_input_tokens"] ?? context?["used"])?.intValue
        facts.contextLimit = (context?["context_window_size"] ?? context?["limit"])?.intValue
        let cost = payload["cost"]
        facts.costUSD = cost?["total_cost_usd"]?.doubleValue
        facts.durationMs = cost?["total_duration_ms"]?.intValue
        facts.apiDurationMs = cost?["total_api_duration_ms"]?.intValue
        facts.linesAdded = cost?["total_lines_added"]?.intValue
        facts.linesRemoved = cost?["total_lines_removed"]?.intValue
        facts.model = payload["model"]?["id"]?.stringValue
        facts.displayName = payload["model"]?["display_name"]?.stringValue
        facts.effort = payload["effort"]?["level"]?.stringValue
        facts.thinkingEnabled = payload["thinking"]?["enabled"]?.boolValue
        facts.fastMode = payload["fast_mode"]?.boolValue
        facts.exceeds200k = payload["exceeds_200k_tokens"]?.boolValue
        if !inputSide.isEmpty {
            facts.currentUsage = TokenUsage(
                input: current?["input_tokens"]?.intValue ?? 0,
                output: current?["output_tokens"]?.intValue ?? 0,
                cacheRead: current?["cache_read_input_tokens"]?.intValue ?? 0,
                cacheWrite: current?["cache_creation_input_tokens"]?.intValue ?? 0
            )
        }
        let hasFacts = facts != StatuslineFacts(updatedAt: now)
        if hasFacts, sid != "unknown" { statusline[sid] = facts }

        recomputeUsage()
    }

    /// A limit window whose reset time has passed since the status line reported it: the
    /// last known percent belongs to the previous window.
    static func limitWindowHasReset(_ resetsAt: Date?, now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// Limits and cost from the turns on hand. Limit percentages come from elsewhere (none yet,
    /// or the demo) and survive a recompute.
    static let standardContextLimit = 200_000
    static let extendedContextLimit = 1_000_000

    /// Context window per model id. The "[1m]" suffix and the 1M-context ids get a million; everything else 200k.
    /// Transcripts drop the "[1m]" suffix, so `recomputeUsage` also switches to a million when the
    /// context in use is already past 200k.
    static func contextLimit(forModel model: String?) -> Int {
        guard let m = model?.lowercased() else { return standardContextLimit }
        if m.contains("[1m]") || m.contains("-1m") || m.contains("1m-") { return extendedContextLimit }
        return standardContextLimit
    }

    func recomputeUsage() {
        let sid = focusedSession?.id
        let reported = sid.flatMap { statusline[$0] }
        let model = reported?.model ?? sid.flatMap { turnsBySession[$0]?.last?.model }
        let limit = AppState.contextLimit(forModel: model)
        var next = UsageCalculator.snapshot(sessionId: sid, turnsBySession: turnsBySession, contextLimit: limit)
        // The status line knows the real window; prefer it to our estimate.
        if let used = reported?.contextUsed { next.contextUsed = used }
        if let reportedLimit = reported?.contextLimit, reportedLimit > 0 { next.contextLimit = reportedLimit }
        if let used = next.contextUsed, used > (next.contextLimit ?? limit) {
            next.contextLimit = max(Self.extendedContextLimit, used)
        }
        if let cost = reported?.costUSD { next.sessionCostUSD = cost }
        next.spendLimit = usage.spendLimit
        // Claude Code's usage cache: the per-model weeks and the breakdown always; the 5-hour
        // and week windows when it is newer than the status line's last report.
        if let plan = planUsage {
            next.modelWeeks = plan.modelWeeks
            next.weekBreakdown = plan.weekBreakdown
            let cacheIsNewer = limitsUpdatedAt.map { $0 < plan.fetchedAt } ?? true
            if cacheIsNewer, plan.fiveHourPercent != nil || plan.weekPercent != nil {
                if let percent = plan.fiveHourPercent {
                    next.fiveHourPercent = percent
                    next.fiveHourResetsAt = plan.fiveHourResetsAt
                }
                if let percent = plan.weekPercent {
                    next.weekPercent = percent
                    next.weekResetsAt = plan.weekResetsAt
                }
                if limitsUpdatedAt != plan.fetchedAt { limitsUpdatedAt = plan.fetchedAt }
            }
        }
        if next.fiveHourPercent == nil {
            next.fiveHourPercent = usage.fiveHourPercent
            next.fiveHourResetsAt = usage.fiveHourResetsAt
        }
        if next.weekPercent == nil {
            next.weekPercent = usage.weekPercent
            next.weekResetsAt = usage.weekResetsAt
        }
        if next != usage { usage = next }
    }
}
