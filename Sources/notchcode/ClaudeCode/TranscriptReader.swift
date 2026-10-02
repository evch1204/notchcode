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
    /// Subagents (Agent tool) keep their lines in
    /// `<transcript dir>/<session id>/subagents/agent-<agentId>.jsonl`, not in the main file;
    /// each is parsed incrementally through its own cache, nested agents included. Their tokens
    /// belong to the turn that started them. Their edits belong to the turn running when the
    /// edit was made (a background agent outlives its turn, and SendMessage continues it in a
    /// later one), and are marked with the agent's id. The merged result is cached against the
    /// stamps of the main file and every subagent file.
    static func turns(transcriptPath: String) throws -> [TranscriptTurn] {
        let mainStamp = FileStamp(path: transcriptPath)
        let raw = try turnCache.value(for: transcriptPath)
        recordQuestion(raw.last?.question, for: transcriptPath)
        let dir = subagentsDirectory(forTranscript: transcriptPath)
        let metaIds = subagentToolUseMap(directory: dir)

        // Each turn's subagent logs, depth first in launch order. An agent is read once, for
        // the turn that launched it, even when a later turn's SendMessage continues it.
        var signature: [FileStamp?] = [mainStamp]
        var perTurn: [[EditLog]] = []
        perTurn.reserveCapacity(raw.count)
        var visited = Set<String>()
        for turn in raw {
            var logs: [EditLog] = []
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

        // Every subagent edit goes to the turn whose window (its prompt until the next
        // prompt) holds the edit's timestamp; never to a turn before the one that launched it.
        var agentEdits = Array(repeating: [EditLog.Edit](), count: raw.count)
        for (launch, logs) in perTurn.enumerated() {
            for log in logs {
                for toolId in log.editOrder {
                    guard var edit = log.edits[toolId] else { continue }
                    edit.agentId = log.agentId
                    let target = edit.at.map { max(launch, turnIndex(at: $0, in: raw)) } ?? launch
                    agentEdits[target].append(edit)
                }
            }
        }

        let turns = raw.indices.map { EditLog.turn(raw[$0], subagents: perTurn[$0], agentEdits: agentEdits[$0]) }
        mergedLock.lock()
        merged[transcriptPath] = (signature, turns)
        mergedLock.unlock()
        return turns
    }

    /// The last turn that started at or before `date` (turns are in transcript order).
    private static func turnIndex(at date: Date, in raw: [RawTurn]) -> Int {
        var low = 0, high = raw.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if raw[mid].startedAt <= date { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// Drops everything cached for this transcript and its subagent files, so a session that
    /// left the list does not keep its parsed turns in memory for the life of the app.
    static func forget(transcriptPath: String) {
        let dir = subagentsDirectory(forTranscript: transcriptPath)
        turnCache.forget(transcriptPath)
        agentCache.forget(transcriptPath)
        subagentCache.forget(under: dir + "/")
        mergedLock.lock(); merged[transcriptPath] = nil; mergedLock.unlock()
        metaLock.lock(); metaCache[dir] = nil; metaLock.unlock()
        questionLock.lock(); lastQuestions[transcriptPath] = nil; questionLock.unlock()
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
            return copy.finish()
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
