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

    static let opus = Rates(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
    static let sonnet = Rates(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)
    static let haiku = Rates(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)

    /// By substring of the model id. "fable" and "mythos" are priced like opus; unknown like sonnet.
    static func rates(forModel model: String?) -> Rates {
        let m = (model ?? "").lowercased()
        if m.contains("opus") || m.contains("fable") || m.contains("mythos") { return opus }
        if m.contains("sonnet") { return sonnet }
        if m.contains("haiku") { return haiku }
        return sonnet
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
    /// (nil only when there are no turns at all).
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
        }
        return snap
    }

    /// Tokens currently in the context window, approximated as the input side (input + cache
    /// read + cache write) of the session's last assistant message.
    ///
    /// For turns that `TranscriptReader` parsed, that exact per-message value is looked up by
    /// the last turn's id. Otherwise it falls back to the last turn's summed input-side
    /// tokens, which overstates context when that turn made several API calls.
    /// Nil when there are no turns or the last one has no input-side tokens.
    static func lastContextTokens(turns: [TranscriptTurn]) -> Int? {
        guard let last = turns.last(where: { $0.tokens.total > 0 }) ?? turns.last else { return nil }
        if let exact = TranscriptReader.lastMessageContextTokens(turnId: last.id) { return exact }
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
