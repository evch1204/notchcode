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

    /// The focused session's cost came from Claude Code, not from our rate table.
    var sessionCostIsReported: Bool {
        guard let id = focusedSession?.id else { return false }
        return statusline[id]?.costUSD != nil
    }

    /// Claude Code's status line input: `rate_limits.five_hour` / `seven_day` ({used_percentage, resets_at}),
    /// `context_window` ({used_percentage} or {used, limit}), `cost.total_cost_usd`, `model.id`.
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
        if gotLimits { limitsUpdatedAt = now }
        if next != usage { usage = next }

        let context = payload["context_window"]
        var facts = StatuslineFacts(updatedAt: now)
        facts.contextPercent = context?["used_percentage"]?.doubleValue.map { min(100, max(0, $0)) }
        facts.contextUsed = context?["used"]?.intValue
        facts.contextLimit = (context?["limit"] ?? context?["context_window_size"])?.intValue
        facts.costUSD = payload["cost"]?["total_cost_usd"]?.doubleValue
        facts.model = payload["model"]?["id"]?.stringValue
        let hasFacts = facts.contextPercent != nil || facts.contextUsed != nil || facts.costUSD != nil || facts.model != nil
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
