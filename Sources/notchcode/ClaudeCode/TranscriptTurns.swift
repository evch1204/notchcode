// TranscriptTurns.swift
// Builds turns from transcript lines for TranscriptReader: the main transcript's turns
// (prompt, model, times, the last context size, an AskUserQuestion), a subagent file's
// edits, and the edit log both gather (file edits with their diff lines, token usage,
// started subagents) and merge into a turn.

import Foundation

// MARK: - Turn building

/// One turn as parsed from the main transcript, before its subagents' edits are merged in.
/// An `AskUserQuestion` call's first question: `questions[0]` with its header and option labels.
struct AskedQuestion: Equatable {
    var question: String
    var header: String?
    var options: [String]
}

struct RawTurn {
    var id: String
    var prompt: String
    var startedAt: Date
    var endedAt: Date?
    var model: String?
    var log: EditLog
    var cwd: String?
    var lastContext: Int?
    var question: AskedQuestion?
}

struct TurnBuilder {
    private var turns: [RawTurn] = []
    private var current: RawTurn?
    private var cwd: String?

    mutating func consume(_ line: [String: Any]) {
        if (line["isSidechain"] as? Bool) == true { return }
        if let c = line["cwd"] as? String, !c.isEmpty { cwd = c }
        let date = ISODate.parse(line["timestamp"])
        let type = line["type"] as? String

        if type == "user", let prompt = JSONLines.promptText(line) {
            closeCurrent()
            current = RawTurn(
                id: (line["uuid"] as? String) ?? UUID().uuidString,
                prompt: prompt,
                startedAt: date ?? Date(timeIntervalSince1970: 0),
                endedAt: date,
                log: EditLog()
            )
            return
        }

        guard current != nil else { return }
        if let date { current!.endedAt = max(current!.endedAt ?? date, date) }

        switch type {
        case "assistant":
            guard let message = line["message"] as? [String: Any] else { return }
            if let model = message["model"] as? String, !model.hasPrefix("<") { current!.model = model }
            if let context = current!.log.consumeAssistant(message, at: date) { current!.lastContext = context }
            if let asked = Self.askedQuestion(message) { current!.question = asked }
        case "user":
            current!.log.consumeToolResult(line)
        default:
            break
        }
    }

    /// The last `AskUserQuestion` tool_use in an assistant message, if any.
    private static func askedQuestion(_ message: [String: Any]) -> AskedQuestion? {
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        var found: AskedQuestion?
        for block in blocks where (block["type"] as? String) == "tool_use" && (block["name"] as? String) == "AskUserQuestion" {
            guard let input = block["input"] as? [String: Any],
                  let first = (input["questions"] as? [[String: Any]])?.first,
                  let text = first["question"] as? String else { continue }
            let options = ((first["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
            found = AskedQuestion(question: text, header: first["header"] as? String, options: options)
        }
        return found
    }

    mutating func finish() -> [RawTurn] {
        closeCurrent()
        return turns
    }

    private mutating func closeCurrent() {
        guard var p = current else { return }
        current = nil
        p.cwd = cwd
        turns.append(p)
    }
}

/// A subagent's own transcript (`<session>/subagents/agent-<id>.jsonl`): every line is
/// sidechain. Its tokens belong to the parent turn that started the agent; its edits carry
/// their timestamps and the agent's id, so they land on the turn running when they were made.
struct SubagentBuilder {
    var log = EditLog()

    mutating func consume(_ line: [String: Any]) {
        if log.agentId == nil, let id = line["agentId"] as? String, !id.isEmpty { log.agentId = id }
        switch line["type"] as? String {
        case "assistant":
            if let message = line["message"] as? [String: Any] {
                _ = log.consumeAssistant(message, at: ISODate.parse(line["timestamp"]))
            }
        case "user":
            log.consumeToolResult(line)
        default:
            break
        }
    }
}

// MARK: - Edit log

/// File edits, token usage and started subagents, gathered from one run of transcript lines
/// (a main-thread turn or a whole subagent file). Several logs merge into one turn.
struct EditLog {
    struct Edit {
        var path: String
        var kind: String            // "edit", "write", "new"
        var added: Int
        var removed: Int
        var hunks: [DiffLine]?      // from structuredPatch, when the tool result is seen; capped
        var truncated = false       // hunks stopped at the cap
        var at: Date?               // the assistant line's timestamp
        var agentId: String?        // set when a subagent made it
    }

    var edits: [String: Edit] = [:]         // by tool_use id
    var editOrder: [String] = []
    var usageByMessage: [String: TokenUsage] = [:]
    var anonymousUsage = TokenUsage()
    var agentToolUses: [String] = []        // Agent / Task tool_use ids, in launch order
    var agentIds: [String: String] = [:]    // tool_use id -> agentId, from the tool result
    var agentId: String?                    // a subagent's own log: its id

    static let snippetLimit = 8     // changed lines; below this the card shows the snippet

    /// Usage, edits and agent launches of one assistant line. Returns the message's
    /// input-side token count (input + cache read + cache write) when it has usage.
    mutating func consumeAssistant(_ message: [String: Any], at date: Date?) -> Int? {
        var context: Int?
        if let usage = message["usage"] as? [String: Any] {
            let u = TokenUsage(
                input: Self.int(usage["input_tokens"]),
                output: Self.int(usage["output_tokens"]),
                cacheRead: Self.int(usage["cache_read_input_tokens"]),
                cacheWrite: Self.int(usage["cache_creation_input_tokens"])
            )
            if let id = message["id"] as? String {
                usageByMessage[id] = u        // repeated lines of one message: keep the last
            } else {
                anonymousUsage = Self.add(anonymousUsage, u)
            }
            let c = u.input + u.cacheRead + u.cacheWrite
            if c > 0 { context = c }
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "tool_use" {
                consumeToolUse(block, at: date)
            }
        }
        return context
    }

    private mutating func consumeToolUse(_ block: [String: Any], at date: Date?) {
        guard let name = block["name"] as? String else { return }
        let toolId = (block["id"] as? String) ?? UUID().uuidString
        if name == "Agent" || name == "Task" {
            if !agentToolUses.contains(toolId) { agentToolUses.append(toolId) }
            return
        }
        guard let input = block["input"] as? [String: Any],
              let path = input["file_path"] as? String, !path.isEmpty
        else { return }

        var edit: Edit
        switch name {
        case "Edit":
            edit = Edit(path: path, kind: "edit",
                        added: Self.lineCount(input["new_string"] as? String),
                        removed: Self.lineCount(input["old_string"] as? String))
        case "MultiEdit":
            var added = 0, removed = 0
            for e in (input["edits"] as? [[String: Any]]) ?? [] {
                added += Self.lineCount(e["new_string"] as? String)
                removed += Self.lineCount(e["old_string"] as? String)
            }
            edit = Edit(path: path, kind: "edit", added: added, removed: removed)
        case "Write":
            edit = Edit(path: path, kind: "write",
                        added: Self.lineCount(input["content"] as? String), removed: 0)
        default:
            return
        }
        if edits[toolId] == nil { editOrder.append(toolId) }
        edit.hunks = edits[toolId]?.hunks
        edit.at = edits[toolId]?.at ?? date
        edits[toolId] = edit
    }

    /// A tool_result line: replace the estimate with exact counts from structuredPatch,
    /// or note the agentId of a started subagent.
    mutating func consumeToolResult(_ line: [String: Any]) {
        guard let result = line["toolUseResult"] as? [String: Any],
              let message = line["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]],
              let toolId = blocks.first(where: { ($0["type"] as? String) == "tool_result" })?["tool_use_id"] as? String
        else { return }

        if let agentId = result["agentId"] as? String, !agentId.isEmpty, agentToolUses.contains(toolId) {
            agentIds[toolId] = agentId
            return
        }
        guard var edit = edits[toolId] else { return }

        if (result["type"] as? String) == "create" { edit.kind = "new" }
        if let patch = result["structuredPatch"] as? [[String: Any]] {
            if !patch.isEmpty {
                let diff = Self.diffLines(fromStructuredPatch: patch)
                edit.added = diff.added
                edit.removed = diff.removed
                edit.hunks = diff.lines
                edit.truncated = diff.truncated
            } else if edit.kind == "new", let content = result["content"] as? String {
                // A new file: Claude Code records no patch, so every written line is an addition.
                let diff = Self.diffLines(newFileContent: content)
                edit.added = diff.added
                edit.removed = 0
                edit.hunks = diff.lines
                edit.truncated = diff.truncated
            } else {
                if edit.kind != "new" { edit.added = 0; edit.removed = 0 }
                edit.hunks = []
            }
        }
        edits[toolId] = edit
    }

    // MARK: Merging into a turn

    /// Builds the turn from its main-thread log, the logs of the subagents it launched (their
    /// usage) and the subagent edits made while it ran (`agentEdits`, in order). Usage is
    /// counted once per message id across all logs; repeated edits of one file merge. A file
    /// only subagents touched carries the first one's id.
    static func turn(_ raw: RawTurn, subagents: [EditLog], agentEdits: [Edit]) -> TranscriptTurn {
        let logs = [raw.log] + subagents

        var tokens = TokenUsage()
        var seen = Set<String>()
        for log in logs {
            tokens = add(tokens, log.anonymousUsage)
            for (id, u) in log.usageByMessage where seen.insert(id).inserted { tokens = add(tokens, u) }
        }

        // Merge repeated edits of one file, in first-touched order; patches concatenate in order.
        var order: [String] = []
        var merged: [String: (change: FileChange, hunks: [DiffLine], exact: Bool, truncated: Bool)] = [:]
        // The main thread's edits and the agents' ones in the order they were made.
        let edits = (raw.log.editOrder.compactMap { raw.log.edits[$0] } + agentEdits)
            .enumerated()
            .sorted { ($0.element.at ?? .distantFuture, $0.offset) < ($1.element.at ?? .distantFuture, $1.offset) }
            .map(\.element)
        for e in edits {
            let path = Paths.relative(e.path, cwd: raw.cwd)
            if var m = merged[path] {
                if e.agentId == nil { m.change.agentId = nil }
                m.change.added += e.added
                m.change.removed += e.removed
                m.change.kind = strongerKind(m.change.kind, e.kind)
                if let h = e.hunks {
                    if m.hunks.count <= Theme.Limits.patchLines { m.hunks += h }
                } else {
                    m.exact = false
                }
                m.truncated = m.truncated || e.truncated
                merged[path] = m
            } else {
                order.append(path)
                merged[path] = (change: FileChange(path: path, added: e.added, removed: e.removed, kind: e.kind, agentId: e.agentId),
                                hunks: e.hunks ?? [], exact: e.hunks != nil, truncated: e.truncated)
            }
        }
        let files: [FileChange] = order.compactMap { path in
            guard var m = merged[path] else { return nil }
            let changed = m.change.added + m.change.removed
            if m.exact, changed > 0, changed < snippetLimit {
                m.change.snippet = m.hunks
            }
            if m.hunks.count > Theme.Limits.patchLines {
                m.change.patch = Array(m.hunks.prefix(Theme.Limits.patchLines))
                m.change.patchTruncated = true
            } else {
                m.change.patch = m.hunks
                m.change.patchTruncated = m.truncated
            }
            return m.change
        }

        return TranscriptTurn(
            id: raw.id,
            prompt: raw.prompt,
            startedAt: raw.startedAt,
            endedAt: raw.endedAt,
            files: files,
            tokens: tokens,
            model: raw.model,
            contextTokens: raw.lastContext
        )
    }

    // MARK: Diff lines

    private struct Diff {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
        var truncated = false

        /// Counts every line, keeps at most `Theme.Limits.patchLines` (one over, so the merge sees the overflow).
        mutating func append(_ line: DiffLine) {
            if lines.count > Theme.Limits.patchLines { truncated = true; return }
            lines.append(line)
        }
    }

    /// Every hunk of a structuredPatch: a `@@ -a,b +c,d @@` header, then context / added /
    /// removed lines numbered from the header.
    private static func diffLines(fromStructuredPatch patch: [[String: Any]]) -> Diff {
        var diff = Diff()
        for hunk in patch {
            let oldStart = int(hunk["oldStart"])
            let newStart = int(hunk["newStart"])
            diff.append(DiffLine(
                kind: .hunk,
                text: "@@ -\(oldStart),\(int(hunk["oldLines"])) +\(newStart),\(int(hunk["newLines"])) @@",
                oldLine: nil, newLine: nil))
            var oldLine = oldStart, newLine = newStart
            for raw in (hunk["lines"] as? [String]) ?? [] {
                let marker: Character = raw.first ?? " "
                let text = raw.isEmpty ? "" : String(raw.dropFirst())
                switch marker {
                case "+":
                    diff.added += 1
                    diff.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newLine))
                    newLine += 1
                case "-":
                    diff.removed += 1
                    diff.append(DiffLine(kind: .removed, text: text, oldLine: oldLine, newLine: nil))
                    oldLine += 1
                case "\\":
                    break   // "\ No newline at end of file"
                default:
                    diff.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        return diff
    }

    /// A new file as one all-added hunk: `@@ -0,0 +1,N @@`.
    private static func diffLines(newFileContent content: String) -> Diff {
        var diff = Diff()
        let lines = content.fileLines
        let count = lines.count
        guard count > 0 else { return diff }
        diff.append(DiffLine(kind: .hunk, text: "@@ -0,0 +1,\(count) @@", oldLine: nil, newLine: nil))
        var n = 1
        for raw in lines {
            if diff.lines.count > Theme.Limits.patchLines { diff.truncated = true; break }
            diff.append(DiffLine(kind: .added, text: String(raw), oldLine: nil, newLine: n))
            n += 1
        }
        diff.added = count
        return diff
    }

    // MARK: Small helpers

    private static func strongerKind(_ a: String, _ b: String) -> String {
        let rank = ["edit": 0, "write": 1, "new": 2]
        return (rank[b] ?? 0) > (rank[a] ?? 0) ? b : a
    }

    private static func add(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double, d.isFinite { return Int(d) }
        return 0
    }

    /// Lines in a string: "" is 0, "a" is 1, "a\nb" is 2, "a\n" is 1; CRLF is one break.
    private static func lineCount(_ s: String?) -> Int {
        s?.fileLines.count ?? 0
    }
}
