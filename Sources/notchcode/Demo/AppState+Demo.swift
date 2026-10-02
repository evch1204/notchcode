// AppState+Demo.swift
// Hooks DemoScript uses to set up sample state directly.

import AppKit
import SwiftUI

extension AppState {

    // MARK: - Hooks for DemoScript

    /// An envelope as the socket would deliver it. The demo has no socket, so a blocking one
    /// gets the transport's deadline here: past it the request goes the timed-out way.
    func receiveDemo(_ envelope: HookEnvelope) {
        receive(envelope) { _ in true }
        guard envelope.isBlocking else { return }
        let id = envelope.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.permissionDeadline) { [weak self] in
            self?.timedOut(requestId: id)
        }
    }

    func mutateSession(_ id: String, _ change: (inout Session) -> Void) {
        updateSession(id, change)
        refresh()
    }

    func setFiles(_ files: [FileChange], forRequest id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].files = files
    }

    func setTurns(_ turns: [TranscriptTurn], for sessionId: String) {
        turnsBySession[sessionId] = turns
        recomputeUsage()
    }

    func seedTurnFiles(_ paths: [String], for sessionId: String) {
        turnFiles[sessionId] = paths
    }

    func setAgentDescription(_ description: String, agentId: String, sessionId: String) {
        let stored = agentKeys[agentId] ?? agentId
        guard var list = agents[sessionId], let index = list.firstIndex(where: { $0.id == stored }) else { return }
        list[index].description = description
        agents[sessionId] = list
    }

    /// What Claude Code's usage cache and `claude -p /usage` would say, matching the demo's
    /// status line (61% and 34%). The demo never runs the CLI.
    func seedDemoPlanUsage() {
        let now = Date()
        planUsage = PlanUsage(
            fetchedAt: now,
            fiveHourPercent: 61,
            fiveHourResetsAt: now.addingTimeInterval(1 * 3600 + 52 * 60),
            weekPercent: 34,
            weekResetsAt: now.addingTimeInterval(3 * 86400),
            modelWeeks: [ModelWeek(name: "Fable", percent: 41, resetsAt: now.addingTimeInterval(3 * 86400))],
            weekBreakdown: [NamedShare(name: "Claude Code", percent: 92), NamedShare(name: "Chats", percent: 8)]
        )
        usageBehaviors = UsageBehaviors(
            day: .init(title: "Last 24h", requests: 212, sessions: 3, lines: [
                "94% of your usage came from subagent-heavy sessions",
                "82% of your usage was at >150k context",
                "Top subagents: general-purpose 34%, fork 5%",
            ]),
            week: .init(title: "Last 7d", requests: 3077, sessions: 11, lines: [
                "99% of your usage came from subagent-heavy sessions",
                "69% of your usage was at >150k context",
                "Top subagents: general-purpose 29%, fork 8%, claude 6%",
            ])
        )
        recomputeUsage()
    }

    func setQuestion(_ preview: QuestionPreview?) {
        question = preview
        refresh()
    }
}
