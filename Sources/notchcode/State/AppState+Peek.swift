// AppState+Peek.swift
// Peeks: the short notices for a finished turn, an edit or a finished subagent.

import AppKit
import SwiftUI

extension AppState {

    // MARK: - Peek

    /// "Done · ponyfish" with the turn's file count and line totals. Falls back to the newest
    /// transcript turn when no PostToolUse was seen (the app started mid-turn).
    func donePeek(for sid: String) -> Peek {
        let name = session(id: sid)?.displayFull ?? ""
        var fileCount = turnFiles[sid]?.count ?? 0
        let shell = turnShellCounts[sid]?.values
        var added = (turnLineCounts[sid]?.added ?? 0) + (shell?.reduce(0) { $0 + $1.added } ?? 0)
        var removed = (turnLineCounts[sid]?.removed ?? 0) + (shell?.reduce(0) { $0 + $1.removed } ?? 0)
        if fileCount == 0, let last = turns(for: sid).first,
           turnStarts[sid].map({ last.startedAt >= $0.addingTimeInterval(-Theme.Timing.turnMatchSlack) }) ?? true {
            fileCount = last.files.count
            added = last.files.reduce(0) { $0 + $1.added }
            removed = last.files.reduce(0) { $0 + $1.removed }
        }
        let title = name.isEmpty ? "Done" : "Done" + Theme.Glyphs.separator + name
        guard fileCount > 0 else { return Peek(kind: .done, sessionId: sid, title: title) }
        return Peek(kind: .done, sessionId: sid, title: title, added: added, removed: removed, detail: Format.files(fileCount))
    }

    /// A click on a peek: a finished turn opens that session's Changes, a finished subagent its
    /// Sessions lane. A pending request still takes the card first.
    func tapPeek(_ tapped: Peek) {
        guard currentPending == nil, session(id: tapped.sessionId) != nil else {
            toggleFromNotchTap()
            return
        }
        peekTask?.cancel()
        peek = nil
        focusedSessionId = tapped.sessionId
        switch tapped.kind {
        case .done, .edit: openCard(tab: .changes)
        case .agent: openCard(tab: .sessions)
        }
    }

    func showPeek(_ newPeek: Peek) {
        guard prefs.showPeeks else { return }
        peek = newPeek
        peekTask?.cancel()
        let peekId = newPeek.id
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.prefs.peekSeconds ?? Theme.Timing.peekLifetime))
            if Task.isCancelled { return }
            guard let self, self.peek?.id == peekId else { return }
            self.peek = nil
            self.refresh()
        }
        refresh()
    }
}
