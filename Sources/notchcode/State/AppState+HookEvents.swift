// AppState+HookEvents.swift
// HookEventSink: every hook envelope lands here and is handed to its handler.

import AppKit
import SwiftUI

extension AppState {

    // MARK: - HookEventSink

    func receive(_ envelope: HookEnvelope, reply: @escaping ReplyHandler) {
        let sid = envelope.resolvedSessionId

        // The status line refreshes on its own schedule: it carries numbers, not activity,
        // so it neither creates sessions nor moves "most recently active".
        if envelope.kind == .statusline {
            handleStatusline(envelope.payload, sessionId: sid)
            return
        }

        hookSeenAt[sid] = Date()
        endedAt[sid] = nil

        if envelope.kind == .sessionEnd {
            endSession(sid)
            if envelope.isBlocking { reply(HookReply(id: envelope.id, decision: .none)) }
            refresh()
            return
        }

        touchSession(envelope)
        let payload = envelope.payload

        // Any sign that Claude moved on ends a notification's "needs you".
        switch envelope.kind {
        case .userPrompt, .preTool, .postTool, .stop, .subagentStart:
            clearNeedsYou(sid)
        default:
            break
        }
        switch envelope.kind {
        case .userPrompt, .preTool, .postTool, .subagentStart, .permission:
            openTurns.insert(sid)
        case .stop:
            openTurns.remove(sid)
        default:
            break
        }

        switch envelope.kind {
        case .permission:
            handlePermission(envelope, sessionId: sid, reply: reply)

        case .preTool:
            handlePreTool(envelope, sessionId: sid, reply: reply)

        case .postTool:
            handlePostTool(payload, sessionId: sid)
            if payload["tool_name"]?.stringValue == "Bash" {
                handleShellTree(envelope.tree, sessionId: sid, cwd: envelope.resolvedCWD)
                gitTreeReported(cwd: envelope.resolvedCWD)
            }
            // Turns include subagent edits; the transcript may be the only record of them.
            reloadTurns(for: sid)

        case .notification:
            handleNotification(payload, sessionId: sid)

        case .stop:
            updateSession(sid) {
                $0.state = .done
                $0.verb = nil
            }
            if question?.sessionId == sid { question = nil }
            showPeek(donePeek(for: sid))
            turnFiles[sid] = []
            turnLineCounts[sid] = nil
            turnShellCounts[sid] = nil
            reloadTurns(for: sid)

        case .userPrompt:
            let prompt = payload["prompt"]?.stringValue ?? ""
            updateSession(sid) {
                $0.state = .working
                $0.verb = "Thinking"
            }
            // Shell changes still waiting for the previous turn: attach them now or never.
            if let held = shellFiles[sid]?[Self.pendingTurnKey] {
                shellFiles[sid]?[Self.pendingTurnKey] = nil
                if let turnId = shellTurnId(for: sid, in: turnsBySession[sid] ?? []) {
                    attachShellFiles(held, sessionId: sid, turnId: turnId)
                }
            }
            turnStarts[sid] = Date()
            turnTitles[sid] = prompt
            turnFiles[sid] = []
            turnLineCounts[sid] = nil
            turnShellCounts[sid] = nil
            // The turn's baseline: what a Bash call's report is compared against. No report
            // (not a git work tree) means nothing to compare.
            treeSnapshots[sid] = envelope.tree.map(UnifiedDiff.snapshot)
            if question?.sessionId == sid { question = nil }
            reloadTurns(for: sid)

        case .sessionStart:
            reloadTurns(for: sid)
            reloadAgents(for: sid)

        case .subagentStart:
            let agentId = payload["agent_id"]?.stringValue ?? envelope.id
            let type = payload["agent_type"]?.stringValue ?? "agent"
            let description = payload["description"]?.stringValue
            agentStarted(id: agentId, type: type, description: description, sessionId: sid, at: Date())
            // The Agent tool call that started it is already in the transcript: pick up its description.
            reloadAgents(for: sid)

        case .subagentStop:
            let agentId = payload["agent_id"]?.stringValue ?? ""
            if let agent = agentStopped(id: agentId, type: payload["agent_type"]?.stringValue, sessionId: sid, at: Date()) {
                showPeek(Peek(
                    kind: .agent,
                    sessionId: sid,
                    title: agent.type + " finished",
                    colorIndex: agentColorIndex(agent)
                ))
            }
            // The agent's edits are in the turns now.
            reloadTurns(for: sid)

        case .sessionEnd, .statusline:
            break
        }
        settle(sid)
        refresh()
    }

    /// The hook went away before a reply: the owner answered in the terminal, or Claude Code
    /// gave up on the hook. Forget the request without replying, then recompute the state.
    func cancel(requestId: String) {
        guard let sid = dropPending(requestId) else { return }
        afterPendingChange(sessionId: sid)
    }

    func timedOut(requestId: String) {
        guard let sid = dropPending(requestId) else { return }
        if !pending.contains(where: { $0.sessionId == sid }) { markNeedsYou(sid) }
        afterPendingChange(sessionId: sid)
    }

    // MARK: - Envelope handling

    private func handlePermission(_ envelope: HookEnvelope, sessionId: String, reply: @escaping ReplyHandler) {
        let payload = envelope.payload
        let tool = payload["tool_name"]?.stringValue ?? "Tool"
        let input = payload["tool_input"]
        let now = Date()
        var request = PendingRequest(
            id: envelope.id,
            kind: .permission,
            sessionId: sessionId,
            tool: tool,
            title: HookText.permissionTitle(tool: tool),
            detail: HookText.permissionDetail(tool: tool, input: input),
            reason: HookText.permissionReason(payload: payload),
            receivedAt: now,
            deadline: now.addingTimeInterval(Theme.Timing.permissionDeadline)
        )
        // A file change: show what it would do, and name the file in the title.
        if let proposed = HookText.proposedChange(tool: tool, input: input, cwd: envelope.resolvedCWD, readsDisk: readsLocalFiles) {
            request.files = [proposed.file]
            request.title = proposed.title
            request.detail = proposed.file.path
        }
        enqueue(request, reply: reply)
        updateSession(sessionId) { $0.state = .needsYou }
    }

    private func handlePreTool(_ envelope: HookEnvelope, sessionId: String, reply: @escaping ReplyHandler) {
        let payload = envelope.payload
        let tool = payload["tool_name"]?.stringValue ?? ""
        let command = payload["tool_input"]?["command"]?.stringValue ?? ""
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if tool == "Bash" && trimmed.hasPrefix("git commit") {
            let now = Date()
            // A file with no recorded patch still opens to its snippet.
            let latestFiles = (turns(for: sessionId).first?.files ?? []).map { file -> FileChange in
                var file = file
                if file.patch.isEmpty { file.patch = file.snippet }
                return file
            }
            let request = PendingRequest(
                id: envelope.id,
                kind: .commit,
                sessionId: sessionId,
                tool: tool,
                title: HookText.commitSubject(from: trimmed) ?? "git commit",
                detail: trimmed,
                reason: payload["tool_input"]?["description"]?.stringValue,
                files: latestFiles,
                receivedAt: now,
                deadline: now.addingTimeInterval(Theme.Timing.permissionDeadline)
            )
            enqueue(request, reply: reply)
            updateSession(sessionId) { $0.state = .needsYou }
            return
        }

        reply(HookReply(id: envelope.id, decision: .none))
        updateSession(sessionId) {
            $0.state = .working
            $0.verb = HookText.verb(forTool: tool)
        }
    }

    private func handlePostTool(_ payload: JSONValue, sessionId: String) {
        let tool = payload["tool_name"]?.stringValue ?? ""
        guard ["Edit", "Write", "MultiEdit"].contains(tool) else { return }

        let response = payload["tool_response"]
        let input = payload["tool_input"]
        guard let path = response?["filePath"]?.stringValue ?? input?["file_path"]?.stringValue else { return }

        var added: Int?
        var removed: Int?
        if let counts = HookText.patchCounts(response?["structuredPatch"]) {
            added = counts.added
            removed = counts.removed
        } else if tool == "Write", let content = input?["content"]?.stringValue {
            added = content.split(separator: "\n", omittingEmptySubsequences: false).count
            removed = 0
        }

        var files = turnFiles[sessionId] ?? []
        if !files.contains(path) { files.append(path) }
        turnFiles[sessionId] = files
        let position = (files.firstIndex(of: path) ?? 0) + 1
        let detail: String? = files.count > 1 ? "\(position) of \(files.count)" : nil
        let counts = turnLineCounts[sessionId] ?? (0, 0)
        turnLineCounts[sessionId] = (counts.added + (added ?? 0), counts.removed + (removed ?? 0))

        updateSession(sessionId) {
            $0.state = .working
            $0.verb = "Thinking"
        }
        if extraPrefs.peekEdits {
            showPeek(Peek(
                kind: .edit,
                sessionId: sessionId,
                title: Format.fileName(path),
                added: added,
                removed: removed,
                detail: detail
            ))
        }
        reloadTurns(for: sessionId)
    }

    private func handleNotification(_ payload: JSONValue, sessionId: String) {
        let type = payload["notification_type"]?.stringValue ?? ""
        let message = payload["message"]?.stringValue ?? ""
        switch type {
        case "idle_prompt":
            // Claude finished and waits for the owner to type: that is done, not blocked.
            clearNeedsYou(sessionId)
            openTurns.remove(sessionId)
            updateSession(sessionId) {
                $0.state = .done
                $0.verb = nil
            }
        case _ where type == "permission_prompt" || type == "agent_needs_input" || type.hasPrefix("elicitation"):
            openTurns.insert(sessionId)
            markNeedsYou(sessionId)
            if type == "agent_needs_input" && !message.isEmpty {
                question = QuestionPreview(sessionId: sessionId, question: message, options: [])
            }
        case "agent_completed":
            clearNeedsYou(sessionId)
            openTurns.remove(sessionId)
            updateSession(sessionId) {
                $0.state = .done
                $0.verb = nil
            }
        default:
            break
        }
    }
}
