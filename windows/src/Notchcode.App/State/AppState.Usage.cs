// AppState.Usage.cs
// Port of Sources/notchcode/Features/Usage/AppState+Usage.swift.
// The Usage tool's derived values: status line facts, context limits and the usage snapshot.

using Notchcode.Core;
using Notchcode.Features.Usage;

namespace Notchcode.State;

public sealed partial class AppState
{
    /// "fable", "opus", "sonnet", "haiku" from the model of the newest turn that names one.
    public string? ModelShortName(string sessionId)
    {
        var model = Statusline.TryGetValue(sessionId, out var facts) && facts.Model is not null
            ? facts.Model
            : Turns(sessionId).Select(t => t.Model).FirstOrDefault(m => m is not null);
        return ModelShortNameOf(model);
    }

    /// Swift `AppState.modelShortName(_:)`.
    public static string? ModelShortNameOf(string? model)
    {
        if (model?.ToLowerInvariant() is not { } m) return null;
        return new[] { "fable", "opus", "sonnet", "haiku" }.FirstOrDefault(name => m.Contains(name, StringComparison.Ordinal));
    }

    /// Context used as 0-100, never above 100. Null when unknown.
    public double? ContextPercent
    {
        get
        {
            if (FocusedSession?.Id is { } id && Statusline.TryGetValue(id, out var facts) && facts.ContextPercent is double percent)
                return Math.Min(100, percent);
            if (Usage.ContextUsed is not long used || Usage.ContextLimit is not long limit || limit <= 0) return null;
            return Math.Min(100, (double)used / limit * 100);
        }
    }

    /// What the status line last said about the focused session.
    public StatuslineFacts? FocusedStatusline
        => FocusedSession is { } s && Statusline.TryGetValue(s.Id, out var facts) ? facts : null;

    /// The focused session's cost came from Claude Code, not from our rate table.
    public bool SessionCostIsReported
        => FocusedSession?.Id is { } id && Statusline.TryGetValue(id, out var facts) && facts.CostUSD is not null;

    /// Claude Code's status line input: `rate_limits.five_hour` / `seven_day` ({used_percentage, resets_at}),
    /// `rate_limits.spend_limit` (gateways only), `context_window` ({used_percentage} or {used, limit}),
    /// `cost`, `model`, `effort.level`, `thinking.enabled`, `fast_mode`, `exceeds_200k_tokens`.
    public void HandleStatusline(JsonValue payload, string sid)
    {
        var now = DateTime.UtcNow;
        static DateTime? Resets(JsonValue? value) => value?.DoubleValue is double s ? ContractJson.FromUnixSeconds(s) : null;
        static double Clamp(double v) => Math.Min(100, Math.Max(0, v));

        var limits = payload["rate_limits"];
        var fiveHour = limits?["five_hour"];
        var week = limits?["seven_day"];
        var next = Usage;
        bool gotLimits = false;
        if (fiveHour?["used_percentage"]?.DoubleValue is double five)
        {
            next = next with { FiveHourPercent = Clamp(five), FiveHourResetsAt = Resets(fiveHour["resets_at"]) };
            gotLimits = true;
        }
        if (week?["used_percentage"]?.DoubleValue is double seven)
        {
            next = next with { WeekPercent = Clamp(seven), WeekResetsAt = Resets(week["resets_at"]) };
            gotLimits = true;
        }
        if (limits?["spend_limit"] is { } spend && spend["used_percentage"]?.DoubleValue is double spent)
        {
            next = next with
            {
                SpendLimit = new SpendLimit
                {
                    Percent = Clamp(spent),
                    ResetsAt = Resets(spend["resets_at"]),
                    UsedUSD = spend["used_usd"]?.DoubleValue,
                    LimitUSD = spend["limit_usd"]?.DoubleValue,
                    Period = spend["period"]?.StringValue,
                },
            };
        }
        if (gotLimits) LimitsUpdatedAt = now;
        if (next != Usage) Usage = next;

        var context = payload["context_window"];
        // Tokens in context: the latest response's input side (input + cache write + cache
        // read in `current_usage`), else `total_input_tokens`; `used` / `limit` are fallbacks
        // no Claude Code version was seen to send.
        var current = context?["current_usage"];
        var inputSide = new[] { "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" }
            .Select(k => current?[k]?.LongValue).OfType<long>().ToList();
        long? latest = inputSide.Count == 0 ? null : inputSide.Sum();
        var cost = payload["cost"];
        var facts = new StatuslineFacts
        {
            UpdatedAt = now,
            ContextPercent = context?["used_percentage"]?.DoubleValue is double cp ? Clamp(cp) : null,
            ContextUsed = latest ?? (context?["total_input_tokens"] ?? context?["used"])?.LongValue,
            ContextLimit = (context?["context_window_size"] ?? context?["limit"])?.LongValue,
            CostUSD = cost?["total_cost_usd"]?.DoubleValue,
            DurationMs = cost?["total_duration_ms"]?.LongValue,
            ApiDurationMs = cost?["total_api_duration_ms"]?.LongValue,
            LinesAdded = cost?["total_lines_added"]?.LongValue,
            LinesRemoved = cost?["total_lines_removed"]?.LongValue,
            Model = payload["model"]?["id"]?.StringValue,
            DisplayName = payload["model"]?["display_name"]?.StringValue,
            Effort = payload["effort"]?["level"]?.StringValue,
            ThinkingEnabled = payload["thinking"]?["enabled"]?.BoolValue,
            FastMode = payload["fast_mode"]?.BoolValue,
            Exceeds200k = payload["exceeds_200k_tokens"]?.BoolValue,
            CurrentUsage = inputSide.Count == 0 ? null : new TokenUsage
            {
                Input = current?["input_tokens"]?.LongValue ?? 0,
                Output = current?["output_tokens"]?.LongValue ?? 0,
                CacheRead = current?["cache_read_input_tokens"]?.LongValue ?? 0,
                CacheWrite = current?["cache_creation_input_tokens"]?.LongValue ?? 0,
            },
        };
        bool hasFacts = facts != new StatuslineFacts { UpdatedAt = now };
        if (hasFacts && sid != "unknown") Statusline = Statusline.SetItem(sid, facts);

        RecomputeUsage();
    }

    /// A limit window whose reset time has passed since the status line reported it: the
    /// last known percent belongs to the previous window.
    public static bool LimitWindowHasReset(DateTime? resetsAt, DateTime? now = null)
        => resetsAt is DateTime r && r <= (now ?? DateTime.UtcNow);

    /// Limits and cost from the turns on hand. Limit percentages come from elsewhere (none yet,
    /// or the demo) and survive a recompute.
    public const long StandardContextLimit = 200_000;
    public const long ExtendedContextLimit = 1_000_000;

    /// Context window per model id. The "[1m]" suffix and the 1M-context ids get a million; everything else 200k.
    /// Transcripts drop the "[1m]" suffix, so `RecomputeUsage` also switches to a million when the
    /// context in use is already past 200k.
    public static long ContextLimit(string? model)
    {
        if (model?.ToLowerInvariant() is not { } m) return StandardContextLimit;
        if (m.Contains("[1m]") || m.Contains("-1m") || m.Contains("1m-")) return ExtendedContextLimit;
        return StandardContextLimit;
    }

    public void RecomputeUsage()
    {
        var sid = FocusedSession?.Id;
        StatuslineFacts? reported = sid is not null && Statusline.TryGetValue(sid, out var f) ? f : null;
        var model = reported?.Model ?? (sid is not null && TurnsBySession.TryGetValue(sid, out var t) ? t.LastOrDefault()?.Model : null);
        long limit = ContextLimit(model);
        var next = UsageCalculator.Snapshot(sid, TurnsBySession, limit);
        // The status line knows the real window; prefer it to our estimate.
        if (reported?.ContextUsed is long used) next = next with { ContextUsed = used };
        if (reported?.ContextLimit is long reportedLimit && reportedLimit > 0) next = next with { ContextLimit = reportedLimit };
        if (next.ContextUsed is long inUse && inUse > (next.ContextLimit ?? limit))
            next = next with { ContextLimit = Math.Max(ExtendedContextLimit, inUse) };
        if (reported?.CostUSD is double cost) next = next with { SessionCostUSD = cost };
        next = next with { SpendLimit = Usage.SpendLimit };
        // Claude Code's usage cache: the per-model weeks and the breakdown always; the 5-hour
        // and week windows when it is newer than the status line's last report.
        if (PlanUsage is { } plan)
        {
            next = next with { ModelWeeks = plan.ModelWeeks, WeekBreakdown = plan.WeekBreakdown };
            bool cacheIsNewer = LimitsUpdatedAt is not DateTime updated || updated < plan.FetchedAt;
            if (cacheIsNewer && (plan.FiveHourPercent is not null || plan.WeekPercent is not null))
            {
                if (plan.FiveHourPercent is double five)
                    next = next with { FiveHourPercent = five, FiveHourResetsAt = plan.FiveHourResetsAt };
                if (plan.WeekPercent is double week)
                    next = next with { WeekPercent = week, WeekResetsAt = plan.WeekResetsAt };
                if (LimitsUpdatedAt != plan.FetchedAt) LimitsUpdatedAt = plan.FetchedAt;
            }
        }
        if (next.FiveHourPercent is null)
            next = next with { FiveHourPercent = Usage.FiveHourPercent, FiveHourResetsAt = Usage.FiveHourResetsAt };
        if (next.WeekPercent is null)
            next = next with { WeekPercent = Usage.WeekPercent, WeekResetsAt = Usage.WeekResetsAt };
        if (next != Usage) Usage = next;
    }
}
