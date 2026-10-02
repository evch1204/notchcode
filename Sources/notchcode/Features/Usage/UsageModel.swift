// UsageModel.swift
// The Usage tool's value types: what the status line said about a session, the plan limits
// from Claude Code's usage cache (the per-model weekly windows and where the week went), the
// "What's contributing to your limits usage?" lines, and how a refresh can fail.

import Foundation

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

/// What Claude Code's own usage cache (~/.claude.json, cachedUsageUtilization) said.
struct PlanUsage: Equatable {
    var fetchedAt: Date
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weekPercent: Double?
    var weekResetsAt: Date?
    var modelWeeks: [ModelWeek]
    /// Rows with percent > 0 first, in the file's order.
    var weekBreakdown: [NamedShare]
}

/// The "What's contributing to your limits usage?" section of `claude -p /usage`.
struct UsageBehaviors: Equatable {
    struct Period: Equatable {
        var title: String       // "Last 24h"
        var requests: Int
        var sessions: Int
        var lines: [String]
    }
    var day: Period?
    var week: Period?
}

enum PlanUsageError: Error, Equatable {
    /// No `claude` executable in the usual places or on the login shell's PATH.
    case notFound
    /// It ran but failed, timed out or printed no result.
    case failed
}
