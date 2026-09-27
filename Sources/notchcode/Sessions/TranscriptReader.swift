// TranscriptReader.swift
// Reads Claude Code's own session files, ~/.claude/projects/<encoded cwd>/<session_id>.jsonl,
// into turns, file changes and token usage. Also reads the git branch and repo name
// straight from .git, without running git.
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
    static func turns(transcriptPath: String) throws -> [TranscriptTurn] {
        try turnCache.value(for: transcriptPath)
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

    private static let turnCache = IncrementalCache<TurnBuilder, [TranscriptTurn]>(
        make: { TurnBuilder() },
        consume: { $0.consume($1) },
        finish: { builder in
            var copy = builder
            let turns = copy.finish()
            recordLastMessageContext(copy.lastMessageContext)
            return turns
        })

    private static let agentCache = IncrementalCache<AgentBuilder, [Agent]>(
        make: { AgentBuilder() },
        consume: { $0.consume($1) },
        finish: { builder in
            var copy = builder
            return copy.finish()
        })

    private static let lastMessageLock = NSLock()
    private static var lastMessageContext: [String: Int] = [:]

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

    // MARK: Git

    static func gitBranch(cwd: String) -> String? {
        guard let git = locateGit(from: cwd),
              let head = try? String(contentsOfFile: git.gitDir + "/HEAD", encoding: .utf8)
        else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        if line.hasPrefix("ref: ") { return String(line.dropFirst(5)) }
        guard !line.isEmpty else { return nil }
        return String(line.prefix(7))   // detached HEAD: short SHA
    }

    /// For a linked worktree, the name of the main repo folder. Nil for a plain checkout.
    static func repoName(cwd: String) -> String? {
        guard let git = locateGit(from: cwd), git.isWorktree else { return nil }
        // gitdir looks like <repo>/.git/worktrees/<name>
        let parts = URL(fileURLWithPath: git.gitDir).standardizedFileURL.pathComponents
        guard let idx = parts.lastIndex(of: "worktrees"), idx >= 1 else { return nil }
        let gitFolder = parts[idx - 1]
        if gitFolder == ".git" {
            guard idx >= 2, parts[idx - 2] != "/" else { return nil }
            return parts[idx - 2]
        }
        if gitFolder.hasSuffix(".git") { return String(gitFolder.dropLast(4)) }   // bare repo "name.git"
        return nil
    }

    private struct GitLocation {
        var gitDir: String
        var isWorktree: Bool
    }

    /// Walks up from cwd to the first `.git`. A directory is a plain checkout; a file
    /// (`gitdir: <path>`) is a linked worktree or a submodule.
    private static func locateGit(from cwd: String) -> GitLocation? {
        guard !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return GitLocation(gitDir: dotGit.path, isWorktree: false) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("gitdir:") else { continue }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let resolved = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : dir.appendingPathComponent(path)
                    let gitDir = resolved.standardizedFileURL.path
                    return GitLocation(gitDir: gitDir, isWorktree: gitDir.contains("/worktrees/"))
                }
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
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

private struct TurnBuilder {
    private struct Edit {
        var path: String
        var kind: String            // "edit", "write", "new"
        var added: Int
        var removed: Int
        var hunks: [DiffLine]?      // from structuredPatch, when the tool result is seen; capped
        var truncated = false       // hunks stopped at the cap
    }

    private struct Pending {
        var id: String
        var prompt: String
        var startedAt: Date
        var endedAt: Date?
        var summary: String?
        var model: String?
        var usageByMessage: [String: TokenUsage] = [:]
        var anonymousUsage = TokenUsage()
        var edits: [String: Edit] = [:]     // by tool_use id
        var editOrder: [String] = []
        var lastContext: Int?               // input-side tokens of the latest assistant message
    }

    private var turns: [TranscriptTurn] = []
    private var current: Pending?
    private var cwd: String?
    /// Turn id -> input + cache read + cache write of the turn's last assistant message.
    private(set) var lastMessageContext: [String: Int] = [:]

    static let summaryLength = 160
    static let snippetLimit = 8     // changed lines; below this the card shows the snippet
    static let patchLimit = 400     // lines kept in FileChange.patch

    mutating func consume(_ line: [String: Any]) {
        if (line["isSidechain"] as? Bool) == true { return }
        if let c = line["cwd"] as? String, !c.isEmpty { cwd = c }
        let date = Self.date(line["timestamp"])
        let type = line["type"] as? String

        if type == "user", let prompt = JSONLines.promptText(line) {
            closeCurrent()
            current = Pending(
                id: (line["uuid"] as? String) ?? UUID().uuidString,
                prompt: prompt,
                startedAt: date ?? Date(timeIntervalSince1970: 0),
                endedAt: date
            )
            return
        }

        guard current != nil else { return }
        if let date { current!.endedAt = max(current!.endedAt ?? date, date) }

        switch type {
        case "assistant":
            consumeAssistant(line)
        case "user":
            consumeToolResult(line)
        default:
            break
        }
    }

    mutating func finish() -> [TranscriptTurn] {
        closeCurrent()
        return turns
    }

    // MARK: Line kinds

    private mutating func consumeAssistant(_ line: [String: Any]) {
        guard let message = line["message"] as? [String: Any] else { return }
        if let model = message["model"] as? String, !model.hasPrefix("<") { current!.model = model }

        if let usage = message["usage"] as? [String: Any] {
            let u = TokenUsage(
                input: Self.int(usage["input_tokens"]),
                output: Self.int(usage["output_tokens"]),
                cacheRead: Self.int(usage["cache_read_input_tokens"]),
                cacheWrite: Self.int(usage["cache_creation_input_tokens"])
            )
            if let id = message["id"] as? String {
                current!.usageByMessage[id] = u        // repeated lines of one message: keep the last
            } else {
                current!.anonymousUsage = Self.add(current!.anonymousUsage, u)
            }
            let context = u.input + u.cacheRead + u.cacheWrite
            if context > 0 { current!.lastContext = context }
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if current!.summary == nil, let text = block["text"] as? String {
                    let trimmed = Self.summarize(text)
                    if !trimmed.isEmpty { current!.summary = trimmed }
                }
            case "tool_use":
                consumeToolUse(block)
            default:
                break
            }
        }
    }

    private mutating func consumeToolUse(_ block: [String: Any]) {
        guard let name = block["name"] as? String,
              let input = block["input"] as? [String: Any],
              let path = input["file_path"] as? String, !path.isEmpty
        else { return }
        let toolId = (block["id"] as? String) ?? UUID().uuidString

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
        if current!.edits[toolId] == nil { current!.editOrder.append(toolId) }
        edit.hunks = current!.edits[toolId]?.hunks
        current!.edits[toolId] = edit
    }

    /// A tool_result line: replace the estimate with exact counts from structuredPatch.
    private mutating func consumeToolResult(_ line: [String: Any]) {
        guard let result = line["toolUseResult"] as? [String: Any],
              let message = line["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]],
              let toolId = blocks.first(where: { ($0["type"] as? String) == "tool_result" })?["tool_use_id"] as? String,
              var edit = current!.edits[toolId]
        else { return }

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
        current!.edits[toolId] = edit
    }

    // MARK: Diff lines

    private struct Diff {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
        var truncated = false

        /// Counts every line, keeps at most `patchLimit` (one over, so the merge sees the overflow).
        mutating func append(_ line: DiffLine) {
            if lines.count > TurnBuilder.patchLimit { truncated = true; return }
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

    // MARK: Closing a turn

    private mutating func closeCurrent() {
        guard let p = current else { return }
        current = nil

        var tokens = p.anonymousUsage
        for u in p.usageByMessage.values { tokens = Self.add(tokens, u) }

        // Merge repeated edits of one file, in first-touched order; patches concatenate in order.
        var order: [String] = []
        var merged: [String: (change: FileChange, hunks: [DiffLine], exact: Bool, truncated: Bool)] = [:]
        for toolId in p.editOrder {
            guard let e = p.edits[toolId] else { continue }
            let path = relative(e.path)
            if var m = merged[path] {
                m.change.added += e.added
                m.change.removed += e.removed
                m.change.kind = Self.strongerKind(m.change.kind, e.kind)
                if let h = e.hunks {
                    if m.hunks.count <= Self.patchLimit { m.hunks += h }
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
        let files: [FileChange] = order.compactMap { path in
            guard var m = merged[path] else { return nil }
            let changed = m.change.added + m.change.removed
            if m.exact, changed > 0, changed < Self.snippetLimit {
                m.change.snippet = m.hunks
            }
            if m.hunks.count > Self.patchLimit {
                m.change.patch = Array(m.hunks.prefix(Self.patchLimit))
                m.change.patchTruncated = true
            } else {
                m.change.patch = m.hunks
                m.change.patchTruncated = m.truncated
            }
            return m.change
        }
        if let context = p.lastContext { lastMessageContext[p.id] = context }

        turns.append(TranscriptTurn(
            id: p.id,
            prompt: p.prompt,
            startedAt: p.startedAt,
            endedAt: p.endedAt,
            assistantSummary: p.summary,
            files: files,
            tokens: tokens,
            model: p.model
        ))
    }

    private func relative(_ path: String) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
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

    private static func date(_ any: Any?) -> Date? { TranscriptDates.parse(any) }

    /// Lines in a string: "" is 0, "a" is 1, "a\nb" is 2, "a\n" is 1.
    private static func lineCount(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        var n = 1
        for scalar in s.unicodeScalars where scalar == "\n" { n += 1 }
        if s.hasSuffix("\n") { n -= 1 }
        return n
    }

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
