// TranscriptReader.swift
// Reads Claude Code's own session files, ~/.claude/projects/<encoded cwd>/<session_id>.jsonl,
// into turns, file changes and token usage. (The git branch and repo name come from
// GitDir, which reads .git without running git.)
//
// Line shapes relied on (checked against real transcripts, 2026-09-27):
//   {"type":"user","uuid","timestamp","cwd","isSidechain","isMeta"?,
//    "message":{"role":"user","content": String | [{type:"text"|"tool_result",...}]},
//    "toolUseResult"?: {"filePath","type":"create"|"update"?,"content"?,"structuredPatch":[hunk]}}
//   {"type":"assistant","timestamp","isSidechain",
//    "message":{"id","model","content":[{type:"text"|"thinking"|"tool_use",...}],"usage":{...}}}
// One API message is split over several assistant lines that share message.id and repeat
// the same usage, so usage is counted once per message id.
// Every other line type (system, attachment, file-history-snapshot, ...) only extends the turn's end.

import Foundation

enum TranscriptReader {

    // MARK: Turns

    /// Cheap to call every couple of seconds: results are cached per path and keyed by
    /// (inode, mtime, size). When the file only grew, just the appended lines are parsed.
    ///
    /// Edits and tokens of subagents (Agent tool) belong to the turn that started them. Their
    /// lines live in `<transcript dir>/<session id>/subagents/agent-<agentId>.jsonl`, not in the
    /// main file; each is parsed incrementally through its own cache, nested agents included.
    /// The merged result is cached against the stamps of the main file and every subagent file.
    static func turns(transcriptPath: String) throws -> [TranscriptTurn] {
        let mainStamp = FileStamp(path: transcriptPath)
        let raw = try turnCache.value(for: transcriptPath)
        recordQuestion(raw.last?.question, for: transcriptPath)
        let dir = subagentsDirectory(forTranscript: transcriptPath)
        let metaIds = subagentToolUseMap(directory: dir)

        // Each turn's subagent logs, depth first in launch order.
        var signature: [FileStamp?] = [mainStamp]
        var perTurn: [[EditLog]] = []
        perTurn.reserveCapacity(raw.count)
        for turn in raw {
            var logs: [EditLog] = []
            var visited = Set<String>()
            func collect(_ log: EditLog, depth: Int) {
                guard depth < 8 else { return }
                for toolId in log.agentToolUses {
                    guard let agentId = log.agentIds[toolId] ?? metaIds[toolId],
                          visited.insert(agentId).inserted else { continue }
                    let path = dir + "/agent-" + agentId + ".jsonl"
                    let stamp = FileStamp(path: path)
                    signature.append(stamp)
                    guard stamp != nil, let sub = try? subagentCache.value(for: path) else { continue }
                    logs.append(sub)
                    collect(sub, depth: depth + 1)
                }
            }
            collect(turn.log, depth: 0)
            perTurn.append(logs)
        }

        mergedLock.lock()
        if let hit = merged[transcriptPath], hit.signature == signature {
            mergedLock.unlock()
            return hit.turns
        }
        mergedLock.unlock()

        let turns = zip(raw, perTurn).map { EditLog.turn($0, subagents: $1) }
        mergedLock.lock()
        merged[transcriptPath] = (signature, turns)
        mergedLock.unlock()
        return turns
    }

    /// Exact context size for a turn: input + cache read + cache write of the LAST assistant
    /// message in that turn, as recorded when the turn was parsed. Nil for turns this reader
    /// has not parsed.
    static func lastMessageContextTokens(turnId: String) -> Int? {
        lastMessageLock.lock(); defer { lastMessageLock.unlock() }
        return lastMessageContext[turnId]
    }

    /// Sets `endedAt` on every agent still running. The UI calls it when a session ends.
    static func closeAgents(_ agents: [Agent], at date: Date) -> [Agent] {
        agents.map { a in
            guard a.endedAt == nil else { return a }
            var a = a
            a.endedAt = max(date, a.startedAt)
            return a
        }
    }

    private static let turnCache = IncrementalCache<TurnBuilder, [RawTurn]>(
        make: { TurnBuilder() },
        consume: { $0.consume($1) },
        finish: { builder in
            var copy = builder
            let turns = copy.finish()
            var contexts: [String: Int] = [:]
            for t in turns { if let c = t.lastContext { contexts[t.id] = c } }
            recordLastMessageContext(contexts)
            return turns
        })

    private static let subagentCache = IncrementalCache<SubagentBuilder, EditLog>(
        make: { SubagentBuilder() },
        consume: { $0.consume($1) },
        finish: { $0.log })

    private static let mergedLock = NSLock()
    private static var merged: [String: (signature: [FileStamp?], turns: [TranscriptTurn])] = [:]

    /// `<dir>/<session id>/subagents` for `<dir>/<session id>.jsonl`.
    private static func subagentsDirectory(forTranscript path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().appendingPathComponent("subagents").path
    }

    private static let metaLock = NSLock()
    private static var metaCache: [String: (mtime: Double, map: [String: String])] = [:]

    /// tool_use id -> agentId from the `agent-<id>.meta.json` files, so a foreground agent's
    /// edits show while it runs, before its tool result (which carries agentId) is written.
    /// Re-read only when the directory's mtime changes (a new agent file appears).
    private static func subagentToolUseMap(directory: String) -> [String: String] {
        guard let stamp = FileStamp(path: directory) else { return [:] }
        metaLock.lock()
        if let hit = metaCache[directory], hit.mtime == stamp.mtime {
            metaLock.unlock()
            return hit.map
        }
        metaLock.unlock()

        var map: [String: String] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
            let agentId = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard let data = FileManager.default.contents(atPath: directory + "/" + name),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let toolId = obj["toolUseId"] as? String, !toolId.isEmpty
            else { continue }
            map[toolId] = agentId
        }
        metaLock.lock()
        metaCache[directory] = (stamp.mtime, map)
        metaLock.unlock()
        return map
    }

    private static let agentCache = IncrementalCache<AgentBuilder, [Agent]>(
        make: { AgentBuilder() },
        consume: { $0.consume($1) },
        finish: { builder in
            var copy = builder
            return copy.finish()
        })

    private static let lastMessageLock = NSLock()
    private static var lastMessageContext: [String: Int] = [:]

    private static let questionLock = NSLock()
    private static var lastQuestions: [String: AskedQuestion] = [:]

    /// The newest turn's last `AskUserQuestion` call, as of the last `turns` read: the
    /// Notification that says Claude waits carries only a message, not the options.
    static func lastQuestion(transcriptPath: String) -> AskedQuestion? {
        questionLock.lock(); defer { questionLock.unlock() }
        return lastQuestions[transcriptPath]
    }

    private static func recordQuestion(_ question: AskedQuestion?, for path: String) {
        questionLock.lock(); defer { questionLock.unlock() }
        lastQuestions[path] = question
    }

    private static func recordLastMessageContext(_ values: [String: Int]) {
        lastMessageLock.lock(); defer { lastMessageLock.unlock() }
        lastMessageContext.merge(values) { _, new in new }
    }

    // MARK: Agents

    /// The subagents Claude started in this session (Agent tool, "Task" in older transcripts),
    /// oldest first. `id` is the subagent's agentId when the transcript has it (the same value
    /// the SubagentStart / SubagentStop hooks send as `agent_id`), else the tool_use id.
    /// Returns [] when the file cannot be read.
    ///
    /// Line shapes relied on (checked against real transcripts and
    /// https://code.claude.com/docs/en/hooks.md, 2026-09-27):
    ///   start   assistant line, content block {type:"tool_use", name:"Agent"|"Task", id,
    ///           input:{description, subagent_type, prompt}}
    ///   result  user line with {type:"tool_result", tool_use_id} and toolUseResult
    ///           {status:"completed"|"async_launched", agentId, ...}. "completed" (foreground) ends
    ///           the agent. "async_launched" (background, the default since v2.1.198) does not.
    ///   end     for background agents: a "<task-notification>" text holding
    ///           <tool-use-id>…</tool-use-id> and <status>completed|failed|…</status>, found in a
    ///           queue-operation line's `content`, an attachment's `prompt`, or a user message;
    ///           or a user line whose origin is {handback:true, from:<agentId>}.
    ///   older   sidechain lines (isSidechain true) in the main file carry `agentId`; the id is
    ///           given to the earliest open agent that has none yet.
    static func agents(transcriptPath: String) -> [Agent] {
        (try? agentCache.value(for: transcriptPath)) ?? []
    }

    // MARK: Paths

    /// Claude Code's project directory name for a cwd: every character that is not
    /// a letter or digit becomes "-" ("/Users/a/my.app" -> "-Users-a-my-app").
    static func encodedProjectName(forCWD cwd: String) -> String {
        String(cwd.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    static func latestTranscriptPath(forCWD cwd: String) -> String? {
        let fm = FileManager.default
        var candidates = [encodedProjectName(forCWD: cwd)]
        let simple = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        if simple != candidates[0] { candidates.append(simple) }

        for name in candidates {
            let dir = NotchcodePaths.claudeProjectsDirectory.appendingPathComponent(name, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            var best: (URL, Date)?
            for url in items where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if best == nil || date > best!.1 { best = (url, date) }
            }
            if let best { return best.0.path }
        }
        return nil
    }
}

// MARK: - Agent building

private struct AgentBuilder {
    private struct Pending {
        var toolUseId: String
        var agentId: String?
        var type: String
        var description: String?
        var startedAt: Date
        var endedAt: Date?
    }

    private var agents: [Pending] = []
    private var byToolUse: [String: Int] = [:]
    private var byAgentId: [String: Int] = [:]
    private var sessionId: String?

    mutating func consume(_ line: [String: Any]) {
        if sessionId == nil, let s = (line["sessionId"] as? String) ?? (line["session_id"] as? String) {
            sessionId = s
        }
        let date = TranscriptDates.parse(line["timestamp"])

        if (line["isSidechain"] as? Bool) == true {
            if let agentId = line["agentId"] as? String, !agentId.isEmpty, byAgentId[agentId] == nil,
               let i = agents.firstIndex(where: { $0.agentId == nil && $0.endedAt == nil }) {
                agents[i].agentId = agentId
                byAgentId[agentId] = i
            }
            return
        }

        switch line["type"] as? String {
        case "assistant":
            consumeAssistant(line, date: date)
        case "user":
            consumeUser(line, date: date)
        case "queue-operation":
            if let text = line["content"] as? String { consumeNotification(text, date: date) }
        case "attachment":
            if let a = line["attachment"] as? [String: Any], let text = a["prompt"] as? String {
                consumeNotification(text, date: date)
            }
        default:
            break
        }
    }

    func finish() -> [Agent] {
        agents.map { p in
            Agent(id: p.agentId ?? p.toolUseId,
                  sessionId: sessionId ?? "unknown",
                  type: p.type,
                  description: p.description,
                  startedAt: p.startedAt,
                  endedAt: p.endedAt)
        }
    }

    private mutating func consumeAssistant(_ line: [String: Any], date: Date?) {
        guard let message = line["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks where (block["type"] as? String) == "tool_use" {
            guard let name = block["name"] as? String, name == "Agent" || name == "Task",
                  let id = block["id"] as? String, byToolUse[id] == nil else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            let type = (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            let description = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            byToolUse[id] = agents.count
            agents.append(Pending(toolUseId: id, agentId: nil, type: type, description: description,
                                  startedAt: date ?? Date(timeIntervalSince1970: 0), endedAt: nil))
        }
    }

    private mutating func consumeUser(_ line: [String: Any], date: Date?) {
        // A background agent handing its report back.
        if let origin = line["origin"] as? [String: Any], (origin["handback"] as? Bool) == true,
           let from = origin["from"] as? String, let i = byAgentId[from] {
            end(i, date)
        }
        guard let message = line["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            consumeNotification(text, date: date)
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let toolId = block["tool_use_id"] as? String, let i = byToolUse[toolId] else { continue }
                let result = line["toolUseResult"] as? [String: Any]
                if let agentId = result?["agentId"] as? String, !agentId.isEmpty {
                    if let old = agents[i].agentId, byAgentId[old] == i { byAgentId[old] = nil }
                    agents[i].agentId = agentId
                    byAgentId[agentId] = i
                }
                // Anything but a background launch (completed, an error, a denial) ends it.
                if (result?["status"] as? String) != "async_launched" { end(i, date) }
            case "text":
                if let text = block["text"] as? String { consumeNotification(text, date: date) }
            default:
                break
            }
        }
    }

    /// `<task-notification>` … `<tool-use-id>X</tool-use-id>` … `<status>completed</status>`.
    private mutating func consumeNotification(_ text: String, date: Date?) {
        guard text.contains("<task-notification>") else { return }
        var rest = Substring(text)
        while let open = rest.range(of: "<task-notification>") {
            let close = rest.range(of: "</task-notification>", range: open.upperBound..<rest.endIndex)
            let body = rest[open.upperBound..<(close?.lowerBound ?? rest.endIndex)]
            rest = rest[(close?.upperBound ?? rest.endIndex)...]

            guard let status = Self.tag(body, "status"), status != "running" else { continue }
            var index: Int?
            if let toolId = Self.tag(body, "tool-use-id") { index = byToolUse[toolId] }
            if index == nil, let taskId = Self.tag(body, "task-id") { index = byAgentId[taskId] }
            if let i = index { end(i, date) }
        }
    }

    private mutating func end(_ i: Int, _ date: Date?) {
        guard agents[i].endedAt == nil else { return }
        agents[i].endedAt = date ?? agents[i].startedAt
    }

    private static func tag(_ text: Substring, _ name: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let body = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

enum TranscriptDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

// MARK: - Turn building

/// One turn as parsed from the main transcript, before its subagents' edits are merged in.
/// An `AskUserQuestion` call's first question: `questions[0]` with its header and option labels.
struct AskedQuestion: Equatable {
    var question: String
    var header: String?
    var options: [String]
}

fileprivate struct RawTurn {
    var id: String
    var prompt: String
    var startedAt: Date
    var endedAt: Date?
    var summary: String?
    var model: String?
    var log: EditLog
    var cwd: String?
    var lastContext: Int?
    var question: AskedQuestion?
}

private struct TurnBuilder {
    private var turns: [RawTurn] = []
    private var current: RawTurn?
    private var cwd: String?

    mutating func consume(_ line: [String: Any]) {
        if (line["isSidechain"] as? Bool) == true { return }
        if let c = line["cwd"] as? String, !c.isEmpty { cwd = c }
        let date = TranscriptDates.parse(line["timestamp"])
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
            if let context = current!.log.consumeAssistant(message) { current!.lastContext = context }
            if let asked = Self.askedQuestion(message) { current!.question = asked }
            if current!.summary == nil, let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = Self.summarize(text)
                    if !trimmed.isEmpty { current!.summary = trimmed; break }
                }
            }
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

    static let summaryLength = 160

    private static func summarize(_ text: String) -> String {
        let flat = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > summaryLength else { return flat }
        return String(flat.prefix(summaryLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A subagent's own transcript (`<session>/subagents/agent-<id>.jsonl`): every line is
/// sidechain, and all of it belongs to the parent turn that started the agent.
fileprivate struct SubagentBuilder {
    var log = EditLog()

    mutating func consume(_ line: [String: Any]) {
        switch line["type"] as? String {
        case "assistant":
            if let message = line["message"] as? [String: Any] { _ = log.consumeAssistant(message) }
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
fileprivate struct EditLog {
    struct Edit {
        var path: String
        var kind: String            // "edit", "write", "new"
        var added: Int
        var removed: Int
        var hunks: [DiffLine]?      // from structuredPatch, when the tool result is seen; capped
        var truncated = false       // hunks stopped at the cap
    }

    var edits: [String: Edit] = [:]         // by tool_use id
    var editOrder: [String] = []
    var usageByMessage: [String: TokenUsage] = [:]
    var anonymousUsage = TokenUsage()
    var agentToolUses: [String] = []        // Agent / Task tool_use ids, in launch order
    var agentIds: [String: String] = [:]    // tool_use id -> agentId, from the tool result

    static let snippetLimit = 8     // changed lines; below this the card shows the snippet
    static let patchLimit = 400     // lines kept in FileChange.patch

    /// Usage, edits and agent launches of one assistant line. Returns the message's
    /// input-side token count (input + cache read + cache write) when it has usage.
    mutating func consumeAssistant(_ message: [String: Any]) -> Int? {
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
                consumeToolUse(block)
            }
        }
        return context
    }

    private mutating func consumeToolUse(_ block: [String: Any]) {
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

    /// Builds the turn from its main-thread log plus the logs of its subagents (in order).
    /// Usage is counted once per message id across all logs; repeated edits of one file merge.
    static func turn(_ raw: RawTurn, subagents: [EditLog]) -> TranscriptTurn {
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
        for log in logs {
            for toolId in log.editOrder {
                guard let e = log.edits[toolId] else { continue }
                let path = relative(e.path, cwd: raw.cwd)
                if var m = merged[path] {
                    m.change.added += e.added
                    m.change.removed += e.removed
                    m.change.kind = strongerKind(m.change.kind, e.kind)
                    if let h = e.hunks {
                        if m.hunks.count <= patchLimit { m.hunks += h }
                    } else {
                        m.exact = false
                    }
                    m.truncated = m.truncated || e.truncated
                    merged[path] = m
                } else {
                    order.append(path)
                    merged[path] = (change: FileChange(path: path, added: e.added, removed: e.removed, kind: e.kind),
                                    hunks: e.hunks ?? [], exact: e.hunks != nil, truncated: e.truncated)
                }
            }
        }
        let files: [FileChange] = order.compactMap { path in
            guard var m = merged[path] else { return nil }
            let changed = m.change.added + m.change.removed
            if m.exact, changed > 0, changed < snippetLimit {
                m.change.snippet = m.hunks
            }
            if m.hunks.count > patchLimit {
                m.change.patch = Array(m.hunks.prefix(patchLimit))
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
            assistantSummary: raw.summary,
            files: files,
            tokens: tokens,
            model: raw.model
        )
    }

    private static func relative(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: Diff lines

    private struct Diff {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
        var truncated = false

        /// Counts every line, keeps at most `patchLimit` (one over, so the merge sees the overflow).
        mutating func append(_ line: DiffLine) {
            if lines.count > EditLog.patchLimit { truncated = true; return }
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
        var body = Substring(content)
        if body.hasSuffix("\n") { body = body.dropLast() }
        let count = content.isEmpty ? 0 : body.split(separator: "\n", omittingEmptySubsequences: false).count
        guard count > 0 else { return diff }
        diff.append(DiffLine(kind: .hunk, text: "@@ -0,0 +1,\(count) @@", oldLine: nil, newLine: nil))
        var n = 1
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if diff.lines.count > patchLimit { diff.truncated = true; break }
            let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            diff.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: n))
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

    /// Lines in a string: "" is 0, "a" is 1, "a\nb" is 2, "a\n" is 1.
    private static func lineCount(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        var n = 1
        for scalar in s.unicodeScalars where scalar == "\n" { n += 1 }
        if s.hasSuffix("\n") { n -= 1 }
        return n
    }
}
