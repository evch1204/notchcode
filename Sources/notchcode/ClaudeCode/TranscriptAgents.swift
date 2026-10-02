// TranscriptAgents.swift
// Builds a session's agents from its main transcript: each Agent tool call, its subagent
// id, its description, and when it started and ended (its tool result, or the
// notification a background agent sends when it finishes). TranscriptReader.agents
// runs it through an incremental cache.

import Foundation

// MARK: - Agent building

struct AgentBuilder {
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
        let date = ISODate.parse(line["timestamp"])

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
