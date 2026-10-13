// UsageCalculator.cs
// Port of Sources/notchcode/Features/Usage/UsageCalculator.swift.
// Token totals and an estimated USD cost from transcript turns. The rate table is ours,
// not reported by Claude Code, so every snapshot says `CostIsEstimate = true`.
// The five-hour and weekly limits are not in transcripts and stay null.

using Notchcode.Core;

namespace Notchcode.Features.Usage;

public static class UsageCalculator
{
    /// USD per million tokens.
    public readonly record struct Rates(double Input, double Output, double CacheRead, double CacheWrite);

    // Anthropic first-party prices (root PLAN, "Usage tab layout", cached 2026-09-25).
    public static readonly Rates Fable = new(10, 50, 0.25, 12.5);
    public static readonly Rates Opus55 = new(4, 20, 0.20, 5);
    public static readonly Rates Opus = new(5, 25, 0.50, 6.25);
    public static readonly Rates Sonnet = new(2, 10, 0.20, 2.5);
    public static readonly Rates Haiku = new(1, 5, 0.10, 1.25);

    public enum ModelFamily { Fable, Opus, Sonnet, Haiku, Other }

    /// By substring of the model id, lowercased: "claude-fable-5-1", "fable", "claude-opus-5", …
    public static ModelFamily Family(string? model)
    {
        var m = (model ?? "").ToLowerInvariant();
        if (m.Contains("fable") || m.Contains("mythos")) return ModelFamily.Fable;
        if (m.Contains("opus")) return ModelFamily.Opus;
        if (m.Contains("sonnet")) return ModelFamily.Sonnet;
        if (m.Contains("haiku")) return ModelFamily.Haiku;
        return ModelFamily.Other;
    }

    /// Fable and Mythos share a price; Opus 5.5 has its own; unknown models are priced like Sonnet.
    public static Rates RatesFor(string? model) => Family(model) switch
    {
        ModelFamily.Fable => Fable,
        ModelFamily.Opus => (model ?? "").ToLowerInvariant().Contains("opus-5-5") ? Opus55 : Opus,
        ModelFamily.Haiku => Haiku,
        _ => Sonnet,
    };

    public static double CostUSD(TokenUsage usage, string? model)
    {
        var r = RatesFor(model);
        return (usage.Input * r.Input + usage.Output * r.Output + usage.CacheRead * r.CacheRead + usage.CacheWrite * r.CacheWrite) / 1_000_000;
    }

    /// `Session*` and `ContextUsed` for `sessionId` (null when it has no turns);
    /// `Today*` over every session's turns that started today, local time
    /// (null only when there are no turns at all); `TodayFable*` over the same turns on Fable
    /// models (zero, not null, when there are turns but none on Fable).
    public static UsageSnapshot Snapshot(string? sessionId,
                                         IReadOnlyDictionary<string, System.Collections.Immutable.ImmutableList<TranscriptTurn>> turnsBySession,
                                         long contextLimit = 200_000)
    {
        var snap = new UsageSnapshot { CostIsEstimate = true, ContextLimit = contextLimit };

        if (sessionId is not null && turnsBySession.TryGetValue(sessionId, out var turns) && turns.Count > 0)
        {
            var (tokens, cost) = Totals(turns);
            snap = snap with { SessionTokens = tokens, SessionCostUSD = cost, ContextUsed = LastContextTokens(turns) };
        }

        if (turnsBySession.Count > 0)
        {
            var today = DateTime.Now.Date;
            var todays = turnsBySession.Values.SelectMany(t => t).Where(t => t.StartedAt.ToLocalTime().Date == today).ToList();
            var (tokens, cost) = Totals(todays);
            var (fableTokens, fableCost) = Totals(todays.Where(t => Family(t.Model) == ModelFamily.Fable));
            snap = snap with
            {
                TodayTokens = tokens,
                TodayCostUSD = cost,
                TodayFableTokens = fableTokens,
                TodayFableCostUSD = fableCost,
            };
        }
        return snap;
    }

    /// Tokens currently in the context window, approximated as the input side (input + cache
    /// read + cache write) of the session's last assistant message.
    ///
    /// For turns that `TranscriptReader` parsed, that exact per-message value is on the
    /// turn (`ContextTokens`). Otherwise it falls back to the last turn's summed input-side
    /// tokens, which overstates context when that turn made several API calls.
    /// Null when there are no turns or the last one has no input-side tokens.
    public static long? LastContextTokens(IReadOnlyList<TranscriptTurn> turns)
    {
        var last = turns.LastOrDefault(t => t.Tokens.Total > 0) ?? turns.LastOrDefault();
        if (last is null) return null;
        if (last.ContextTokens is long exact) return exact;
        long approx = last.Tokens.Input + last.Tokens.CacheRead + last.Tokens.CacheWrite;
        return approx > 0 ? approx : null;
    }

    private static (TokenUsage Tokens, double Cost) Totals(IEnumerable<TranscriptTurn> turns)
    {
        long input = 0, output = 0, cacheRead = 0, cacheWrite = 0;
        double cost = 0;
        foreach (var t in turns)
        {
            input += t.Tokens.Input;
            output += t.Tokens.Output;
            cacheRead += t.Tokens.CacheRead;
            cacheWrite += t.Tokens.CacheWrite;
            cost += CostUSD(t.Tokens, t.Model);
        }
        return (new TokenUsage { Input = input, Output = output, CacheRead = cacheRead, CacheWrite = cacheWrite }, cost);
    }
}
