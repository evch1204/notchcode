// UsageCalculator.swift
// Token totals and an estimated USD cost from transcript turns. The rate table is ours,
// not reported by Claude Code, so every snapshot says `costIsEstimate = true`.
// The five-hour and weekly limits are not in transcripts and stay nil.

import Foundation

enum UsageCalculator {

    /// USD per million tokens.
    struct Rates: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    // Anthropic first-party prices (claude-api skill, cached 2026-09-25).
    static let fable = Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)
    static let opus55 = Rates(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)
    static let opus = Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)
    static let sonnet = Rates(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)
    static let haiku = Rates(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25)

    enum ModelFamily { case fable, opus, sonnet, haiku, other }

    /// By substring of the model id, lowercased: "claude-fable-5-1", "fable", "claude-opus-5", …
    static func family(of model: String?) -> ModelFamily {
        let m = (model ?? "").lowercased()
        if m.contains("fable") || m.contains("mythos") { return .fable }
        if m.contains("opus") { return .opus }
        if m.contains("sonnet") { return .sonnet }
        if m.contains("haiku") { return .haiku }
        return .other
    }

    /// Fable and Mythos share a price; Opus 5.5 has its own; unknown models are priced like Sonnet.
    static func rates(forModel model: String?) -> Rates {
        switch family(of: model) {
        case .fable: return fable
        case .opus: return (model ?? "").lowercased().contains("opus-5-5") ? opus55 : opus
        case .sonnet, .other: return sonnet
        case .haiku: return haiku
        }
    }

    static func costUSD(_ usage: TokenUsage, model: String?) -> Double {
        let r = rates(forModel: model)
        return (Double(usage.input) * r.input
              + Double(usage.output) * r.output
              + Double(usage.cacheRead) * r.cacheRead
              + Double(usage.cacheWrite) * r.cacheWrite) / 1_000_000
    }

    /// `session*` and `contextUsed` for `sessionId` (nil when it has no turns);
    /// `today*` over every session's turns that started today, local time
    /// (nil only when there are no turns at all); `todayFable*` over the same turns on Fable
    /// models (zero, not nil, when there are turns but none on Fable).
    static func snapshot(sessionId: String?,
                         turnsBySession: [String: [TranscriptTurn]],
                         contextLimit: Int = 200_000) -> UsageSnapshot {
        var snap = UsageSnapshot()
        snap.costIsEstimate = true
        snap.contextLimit = contextLimit

        if let sessionId, let turns = turnsBySession[sessionId], !turns.isEmpty {
            let (tokens, cost) = totals(turns)
            snap.sessionTokens = tokens
            snap.sessionCostUSD = cost
            snap.contextUsed = lastContextTokens(turns: turns)
        }

        if !turnsBySession.isEmpty {
            let calendar = Calendar.current
            let today = turnsBySession.values.joined().filter { calendar.isDateInToday($0.startedAt) }
            let (tokens, cost) = totals(today)
            snap.todayTokens = tokens
            snap.todayCostUSD = cost
            let (fableTokens, fableCost) = totals(today.filter { family(of: $0.model) == .fable })
            snap.todayFableTokens = fableTokens
            snap.todayFableCostUSD = fableCost
        }
        return snap
    }

    /// Tokens currently in the context window, approximated as the input side (input + cache
    /// read + cache write) of the session's last assistant message.
    ///
    /// For turns that `TranscriptReader` parsed, that exact per-message value is on the
    /// turn (`contextTokens`). Otherwise it falls back to the last turn's summed input-side
    /// tokens, which overstates context when that turn made several API calls.
    /// Nil when there are no turns or the last one has no input-side tokens.
    static func lastContextTokens(turns: [TranscriptTurn]) -> Int? {
        guard let last = turns.last(where: { $0.tokens.total > 0 }) ?? turns.last else { return nil }
        if let exact = last.contextTokens { return exact }
        let approx = last.tokens.input + last.tokens.cacheRead + last.tokens.cacheWrite
        return approx > 0 ? approx : nil
    }

    private static func totals(_ turns: some Sequence<TranscriptTurn>) -> (TokenUsage, Double) {
        var tokens = TokenUsage()
        var cost = 0.0
        for t in turns {
            tokens.input += t.tokens.input
            tokens.output += t.tokens.output
            tokens.cacheRead += t.tokens.cacheRead
            tokens.cacheWrite += t.tokens.cacheWrite
            cost += costUSD(t.tokens, model: t.model)
        }
        return (tokens, cost)
    }
}
