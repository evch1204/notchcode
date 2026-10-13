// UsageModel.cs
// Port of Sources/notchcode/Features/Usage/UsageModel.swift.
// The Usage tool's value types: what the status line said about a session, the plan limits
// from Claude Code's usage cache (the per-model weekly windows and where the week went), the
// "What's contributing to your limits usage?" lines, and how a refresh can fail.

using Notchcode.Core;

namespace Notchcode.Features.Usage;

/// What Claude Code's status line input said about one session. Every field optional.
public sealed record StatuslineFacts
{
    public double? ContextPercent { get; init; }
    public long? ContextUsed { get; init; }
    public long? ContextLimit { get; init; }
    public double? CostUSD { get; init; }
    public string? Model { get; init; }
    /// "Fable 5.1": `model.display_name`.
    public string? DisplayName { get; init; }
    /// `effort.level`: "low" … "max", only for models that have it.
    public string? Effort { get; init; }
    public bool? ThinkingEnabled { get; init; }
    public bool? FastMode { get; init; }
    public bool? Exceeds200k { get; init; }
    /// `cost.total_duration_ms` and `cost.total_api_duration_ms`.
    public long? DurationMs { get; init; }
    public long? ApiDurationMs { get; init; }
    public long? LinesAdded { get; init; }
    public long? LinesRemoved { get; init; }
    /// The last API call's `context_window.current_usage`.
    public TokenUsage? CurrentUsage { get; init; }
    public DateTime UpdatedAt { get; init; }
}

/// What Claude Code's own usage cache (%USERPROFILE%\.claude.json, cachedUsageUtilization) said.
public sealed record PlanUsage
{
    public DateTime FetchedAt { get; init; }
    public double? FiveHourPercent { get; init; }
    public DateTime? FiveHourResetsAt { get; init; }
    public double? WeekPercent { get; init; }
    public DateTime? WeekResetsAt { get; init; }
    public IReadOnlyList<ModelWeek> ModelWeeks { get; init; } = [];
    /// Rows with percent > 0 first, in the file's order.
    public IReadOnlyList<NamedShare> WeekBreakdown { get; init; } = [];

    public bool Equals(PlanUsage? o)
        => o is not null && FetchedAt == o.FetchedAt && FiveHourPercent == o.FiveHourPercent
           && FiveHourResetsAt == o.FiveHourResetsAt && WeekPercent == o.WeekPercent && WeekResetsAt == o.WeekResetsAt
           && ModelWeeks.SequenceEqual(o.ModelWeeks) && WeekBreakdown.SequenceEqual(o.WeekBreakdown);

    public override int GetHashCode() => HashCode.Combine(FetchedAt, FiveHourPercent, WeekPercent, ModelWeeks.Count);
}

/// One period of "What's contributing to your limits usage?".
public sealed record UsageBehaviorPeriod
{
    /// "Last 24h"
    public string Title { get; init; } = "";
    public int Requests { get; init; }
    public int Sessions { get; init; }
    public IReadOnlyList<string> Lines { get; init; } = [];

    public bool Equals(UsageBehaviorPeriod? o)
        => o is not null && Title == o.Title && Requests == o.Requests && Sessions == o.Sessions && Lines.SequenceEqual(o.Lines);

    public override int GetHashCode() => HashCode.Combine(Title, Requests, Sessions, Lines.Count);
}

/// The "What's contributing to your limits usage?" section of `claude -p /usage`.
public sealed record UsageBehaviors
{
    public UsageBehaviorPeriod? Day { get; init; }
    public UsageBehaviorPeriod? Week { get; init; }
}

public enum PlanUsageError
{
    /// No `claude.exe` on PATH or in %USERPROFILE%\.local\bin.
    NotFound,
    /// It ran but failed, timed out or printed no result.
    Failed,
}
