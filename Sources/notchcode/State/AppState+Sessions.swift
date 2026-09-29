// AppState+Sessions.swift
// Sessions from hooks and transcripts, the needs-you state, and subagents.

import AppKit
import SwiftUI

extension AppState {

    // MARK: - Sessions

    func touchSession(_ envelope: HookEnvelope) {
        let sid = envelope.resolvedSessionId
        let now = Date()
        if let index = sessions.firstIndex(where: { $0.id == sid }) {
            var s = sessions[index]
            s.lastEventAt = now
            var transcriptChanged = false
            if let path = envelope.resolvedTranscriptPath, path != s.transcriptPath {
                s.transcriptPath = path
                transcriptChanged = true
            }
            if let term = envelope.termProgram { s.termProgram = term }
            if let bundle = envelope.termBundleId { s.termBundleId = bundle }
            if let pid = envelope.pid { s.pid = pid }
            if let mode = envelope.payload["permission_mode"]?.stringValue, !mode.isEmpty { s.permissionMode = mode }
            sessions[index] = s
            if transcriptChanged { reloadAgents(for: sid) }
            return
        }

        let cwd = envelope.resolvedCWD
        let name = cwd.isEmpty ? sid : URL(fileURLWithPath: cwd).lastPathComponent
        var transcript = envelope.resolvedTranscriptPath
        var branch: String?
        var repo: String?
        if readsLocalFiles && !cwd.isEmpty {
            branch = GitDir.gitBranch(cwd: cwd)
            repo = GitDir.repoName(cwd: cwd)
            if transcript == nil { transcript = TranscriptReader.latestTranscriptPath(forCWD: cwd) }
        }
        let session = Session(
            id: sid,
            cwd: cwd,
            worktreeName: name,
            repoName: repo,
            branch: branch,
            state: .idle,
            verb: nil,
            startedAt: now,
            lastEventAt: now,
            transcriptPath: transcript,
            termProgram: envelope.termProgram,
            termBundleId: envelope.termBundleId,
            pid: envelope.pid,
            permissionMode: envelope.payload["permission_mode"]?.stringValue
        )
        sessions.append(session)
        if transcript != nil { reloadAgents(for: sid) }
    }

    /// SessionEnd: the session stays listed (idle) until it ages out, with its agents closed.
    /// It no longer counts as hook-driven, so the transcript watcher may revive it on new activity.
    func endSession(_ sid: String) {
        for req in pending where req.sessionId == sid {
            resolve(req.id, with: HookReply(id: req.id, decision: .none))
        }
        hookSeenAt[sid] = nil
        endedAt[sid] = Date()
        turnStarts[sid] = nil
        turnFiles[sid] = nil
        turnLineCounts[sid] = nil
        turnShellCounts[sid] = nil
        treeSnapshots[sid] = nil
        clearNeedsYou(sid)
        openTurns.remove(sid)
        updateSession(sid) {
            $0.state = .idle
            $0.verb = nil
        }
        if let list = agents[sid], list.contains(where: { $0.isRunning }) {
            agents[sid] = TranscriptReader.closeAgents(list, at: Date())
        }
        if question?.sessionId == sid { question = nil }
        if !readsLocalFiles { forgetSession(sid) }
    }

    /// Drops a session and everything kept for it.
    private func forgetSession(_ sid: String) {
        sessions.removeAll { $0.id == sid }
        turnsBySession[sid] = nil
        turnStarts[sid] = nil
        turnTitles[sid] = nil
        turnFiles[sid] = nil
        turnLineCounts[sid] = nil
        turnShellCounts[sid] = nil
        treeSnapshots[sid] = nil
        shellFiles[sid] = nil
        statusline[sid] = nil
        clearNeedsYou(sid)
        openTurns.remove(sid)
        if let ended = agents.removeValue(forKey: sid) {
            let ids = Set(ended.map { $0.id })
            agentKeys = agentKeys.filter { !ids.contains($0.value) }
            unmatchedHookAgents.subtract(ids)
        }
        if question?.sessionId == sid { question = nil }
        if focusedSessionId == sid { focusedSessionId = nil }
        sessionCursor = min(sessionCursor, max(0, sessions.count - 1))
    }

    func updateSession(_ id: String, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[index]
        change(&s)
        if s != sessions[index] { sessions[index] = s }
    }

    // MARK: - Needs you

    /// Claude says it waits on the owner, with no request of ours to answer. Lasts at most
    /// `needsYouLifetime`, and less if the session does anything in the meantime.
    func markNeedsYou(_ sid: String) {
        let now = Date()
        needsYouSince[sid] = now
        updateSession(sid) { $0.state = .needsYou }
        needsYouTasks[sid]?.cancel()
        needsYouTasks[sid] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Timing.needsYouLifetime))
            if Task.isCancelled { return }
            guard let self, self.needsYouSince[sid] == now else { return }
            self.settle(sid)
            self.refresh()
        }
    }

    func clearNeedsYou(_ sid: String) {
        needsYouSince[sid] = nil
        needsYouTasks.removeValue(forKey: sid)?.cancel()
    }

    private func needsYouIsFresh(_ sid: String, now: Date = Date()) -> Bool {
        guard let since = needsYouSince[sid] else { return false }
        return now.timeIntervalSince(since) < Theme.Timing.needsYouLifetime
    }

    /// Makes `.needsYou` true or gone. A pending request always means needs you; otherwise it
    /// stays only while a fresh notification backs it, then falls back to working (turn still
    /// open) or done.
    func settle(_ sid: String) {
        guard let s = session(id: sid) else { return }
        if pending.contains(where: { $0.sessionId == sid }) {
            if s.state != .needsYou { updateSession(sid) { $0.state = .needsYou } }
            return
        }
        guard s.state == .needsYou, !needsYouIsFresh(sid) else { return }
        clearNeedsYou(sid)
        if question?.sessionId == sid { question = nil }
        let working = openTurns.contains(sid)
        updateSession(sid) {
            $0.state = working ? .working : .done
            if !working { $0.verb = nil } else if $0.verb == nil { $0.verb = "Working" }
        }
    }

    // MARK: - TranscriptWatcherSink

    func isHookDriven(_ sid: String, now: Date = Date()) -> Bool {
        guard let seen = hookSeenAt[sid] else { return false }
        return now.timeIntervalSince(seen) < Theme.Timing.hookDrivenWindow
    }

    /// Merges sessions found on disk by id. Hooks win on state for sessions they drive.
    func transcriptsChanged(_ discovered: [DiscoveredSession]) {
        guard readsLocalFiles else { return }
        let now = Date()
        var changed: [String] = []

        // Claude Code's own helper runs fire hooks like any session, so one may already be listed.
        let headless = Set(discovered.filter(\.isHeadless).map(\.id))
        if !headless.isEmpty, sessions.contains(where: { headless.contains($0.id) }) {
            sessions.removeAll { headless.contains($0.id) }
        }
        let discovered = discovered.filter { !$0.isHeadless }

        // The newest transcript per folder tells the owner which of two same-folder sessions is theirs.
        var newest: [String: DiscoveredSession] = [:]
        for found in discovered where !found.cwd.isEmpty {
            if let best = newest[found.cwd], best.lastActivityAt >= found.lastActivityAt { continue }
            newest[found.cwd] = found
        }
        let newestIds = newest.mapValues { $0.id }
        if newestIds != newestSessionByCWD { newestSessionByCWD = newestIds }

        for found in discovered {
            // The transcript moved on after Claude said it needed the owner: it no longer does.
            if let since = needsYouSince[found.id],
               found.lastActivityAt > since.addingTimeInterval(Theme.Timing.needsYouActivityGrace) {
                clearNeedsYou(found.id)
                settle(found.id)
            }
            if let index = sessions.firstIndex(where: { $0.id == found.id }) {
                var s = sessions[index]
                if s.transcriptPath == nil { s.transcriptPath = found.transcriptPath }
                if let mode = found.permissionMode { s.permissionMode = mode }   // the transcript wins over hooks
                if !isHookDriven(found.id, now: now) {
                    let endedBefore = endedAt[found.id].map { found.lastActivityAt <= $0 } ?? false
                    if !endedBefore {
                        endedAt[found.id] = nil
                        s.state = found.state
                        s.verb = found.verb
                        if let prompt = found.lastPrompt, !prompt.isEmpty { turnTitles[found.id] = prompt }
                    }
                    if found.lastActivityAt > s.lastEventAt { s.lastEventAt = found.lastActivityAt }
                }
                if s != sessions[index] { sessions[index] = s }
            } else {
                guard now.timeIntervalSince(found.lastActivityAt) < Theme.Timing.sessionIdleCutoff else { continue }
                if let ended = endedAt[found.id], found.lastActivityAt <= ended { continue }
                let cwd = found.cwd
                sessions.append(Session(
                    id: found.id,
                    cwd: cwd,
                    worktreeName: cwd.isEmpty ? found.id : URL(fileURLWithPath: cwd).lastPathComponent,
                    repoName: cwd.isEmpty ? nil : GitDir.repoName(cwd: cwd),
                    branch: cwd.isEmpty ? nil : GitDir.gitBranch(cwd: cwd),
                    state: found.state,
                    verb: found.verb,
                    startedAt: found.startedAt,
                    lastEventAt: found.lastActivityAt,
                    transcriptPath: found.transcriptPath,
                    termProgram: nil,
                    termBundleId: nil,
                    pid: nil,
                    permissionMode: found.permissionMode
                ))
                if let prompt = found.lastPrompt, !prompt.isEmpty { turnTitles[found.id] = prompt }
            }
            if lastSeenActivity[found.id] != found.lastActivityAt {
                lastSeenActivity[found.id] = found.lastActivityAt
                changed.append(found.id)
            }
        }

        // Sessions idle past the cutoff leave the list, unless hooks still drive them or they wait on the owner.
        let pendingIds = Set(pending.map { $0.sessionId })
        let stale = sessions.filter {
            !isHookDriven($0.id, now: now) && !pendingIds.contains($0.id)
                && now.timeIntervalSince($0.lastEventAt) > Theme.Timing.sessionIdleCutoff
        }
        for s in stale {
            forgetSession(s.id)
            lastSeenActivity[s.id] = nil
            endedAt[s.id] = nil
        }

        for sid in changed where session(id: sid) != nil {
            reloadTurns(for: sid)
            reloadAgents(for: sid)
        }
        // A background subagent can keep editing while the main transcript stays quiet:
        // re-read turns for every session with a running agent (cheap when nothing changed).
        let changedSet = Set(changed)
        for s in sessions where !changedSet.contains(s.id) && !runningAgents(for: s.id).isEmpty {
            reloadTurns(for: s.id)
        }
        if focusedSessionId == nil, isCardOpen { focusedSessionId = primarySession?.id }
        refresh()
    }

    // MARK: - Subagents

    func reloadAgents(for sid: String) {
        guard readsLocalFiles, let path = session(id: sid)?.transcriptPath else { return }
        Task.detached(priority: .utility) { [weak self] in
            let found = TranscriptReader.agents(transcriptPath: path)
            await self?.mergeTranscriptAgents(found, for: sid)
        }
    }

    func agentStarted(id: String, type: String, description: String?, sessionId sid: String, at date: Date) {
        if agentKeys[id] != nil { return }
        var list = agents[sid] ?? []
        if list.contains(where: { $0.id == id }) { agentKeys[id] = id; return }

        // The transcript may have seen this agent first under its tool_use id.
        if let index = list.firstIndex(where: { candidate in
            candidate.isRunning && candidate.type == type && !unmatchedHookAgents.contains(candidate.id)
                && !agentKeys.contains(where: { key in key.value == candidate.id && key.key != candidate.id })
                && abs(candidate.startedAt.timeIntervalSince(date)) < Theme.Timing.agentMatchWindow
        }) {
            agentKeys[id] = list[index].id
            if list[index].description == nil { list[index].description = description }
            agents[sid] = list
            return
        }

        list.append(Agent(id: id, sessionId: sid, type: type, description: description, startedAt: date, endedAt: nil))
        agentKeys[id] = id
        unmatchedHookAgents.insert(id)
        agents[sid] = list
    }

    /// Ends the matching running agent and returns it, or nil when none matched.
    @discardableResult
    func agentStopped(id: String, type: String?, sessionId sid: String, at date: Date) -> Agent? {
        guard var list = agents[sid] else { return nil }
        let stored = agentKeys[id] ?? id
        var index = list.firstIndex(where: { $0.id == stored && $0.isRunning })
        if index == nil, let type {
            // Unknown id: end the oldest running agent of that type.
            index = list.firstIndex(where: { $0.isRunning && $0.type == type })
        }
        guard let index else { return nil }
        list[index].endedAt = date
        agents[sid] = list
        return list[index]
    }

    private func mergeTranscriptAgents(_ found: [Agent], for sid: String) {
        guard session(id: sid) != nil else { return }
        var list = agents[sid] ?? []
        for incoming in found {
            if let stored = agentKeys[incoming.id], let index = list.firstIndex(where: { $0.id == stored }) {
                apply(incoming, to: &list[index])
                continue
            }
            if let index = list.firstIndex(where: { $0.id == incoming.id }) {
                agentKeys[incoming.id] = incoming.id
                apply(incoming, to: &list[index])
                continue
            }
            // Same agent seen by the hook under its agent_id.
            if let index = list.firstIndex(where: {
                unmatchedHookAgents.contains($0.id) && $0.type == incoming.type
                    && abs($0.startedAt.timeIntervalSince(incoming.startedAt)) < Theme.Timing.agentMatchWindow
            }) {
                unmatchedHookAgents.remove(list[index].id)
                agentKeys[incoming.id] = list[index].id
                apply(incoming, to: &list[index])
                continue
            }
            var copy = incoming
            copy.sessionId = sid
            list.append(copy)
            agentKeys[incoming.id] = incoming.id
        }
        list.sort { $0.startedAt < $1.startedAt }
        if list != (agents[sid] ?? []) { agents[sid] = list }
        refresh()
    }

    /// Fills what the transcript knows. A stop seen by the hook is never undone by an older transcript.
    private func apply(_ incoming: Agent, to agent: inout Agent) {
        if agent.description == nil { agent.description = incoming.description }
        if agent.isRunning, let ended = incoming.endedAt { agent.endedAt = ended }
    }
}
