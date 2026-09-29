// AppState+Demo.swift
// Hooks DemoScript uses to set up sample state directly.

import AppKit
import SwiftUI

extension AppState {

    // MARK: - Hooks for DemoScript

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

    func setQuestion(_ preview: QuestionPreview?) {
        question = preview
        refresh()
    }
}
