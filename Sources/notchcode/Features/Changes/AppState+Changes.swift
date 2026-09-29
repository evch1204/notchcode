// AppState+Changes.swift
// The Changes tool: turns, their file rows and cursors, and changes made by shell commands.

import AppKit
import SwiftUI

/// One row of the Changes tab: a turn's one-line header, or one of its files.
enum ChangesRow: Identifiable, Equatable {
    case turn(TranscriptTurn)
    case file(DiffRowItem)

    var id: String {
        switch self {
        case .turn(let turn): return AppState.turnRowKey(turn)
        case .file(let item): return item.key
        }
    }
}

/// One expandable file row in the Changes or Files tab. `key` is stable across reloads.
struct DiffRowItem: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var file: FileChange
}

extension AppState {

    /// The prompt of the session's current (or last) turn.
    func currentPrompt(for sessionId: String) -> String? {
        if let title = turnTitles[sessionId], !title.isEmpty { return title }
        return turns(for: sessionId).first?.prompt
    }

    /// When the current turn started, for the working clock in the Sessions tab. Nil when unknown.
    func turnStart(for session: Session) -> Date? {
        turnStarts[session.id]
    }

    func turns(for sessionId: String?) -> [TranscriptTurn] {
        guard let sessionId else { return [] }
        let shell = shellFiles[sessionId] ?? [:]
        return (turnsBySession[sessionId] ?? []).map { turn in
            guard let extra = shell[turn.id], !extra.isEmpty else { return turn }
            // Transcript files win on the same path; shell files follow them.
            var turn = turn
            let known = Set(turn.files.map(\.path))
            turn.files += extra.filter { !known.contains($0.path) }
            return turn
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// The Changes tab's rows in display order: each turn's header, then its file rows when
    /// the turn is open. The keyboard cursor (`rowCursor`) indexes this list.
    var changesRows: [ChangesRow] {
        var rows: [ChangesRow] = []
        for (index, turn) in turns(for: focusedSession?.id).enumerated() {
            rows.append(.turn(turn))
            guard isTurnOpen(turn, newest: index == 0) else { continue }
            rows += turn.files.map { .file(DiffRowItem(key: Self.changesRowKey(turn: turn, file: $0), file: $0)) }
        }
        return rows
    }

    nonisolated static func changesRowKey(turn: TranscriptTurn, file: FileChange) -> String { "c|\(turn.id)|\(file.path)" }
    nonisolated static func turnRowKey(_ turn: TranscriptTurn) -> String { "t|\(turn.id)" }

    /// The newest turn's files show by default; older turns start folded. A turn without files never opens.
    func isTurnOpen(_ turn: TranscriptTurn, newest: Bool) -> Bool {
        guard !turn.files.isEmpty else { return false }
        return newest != turnToggled.contains(turn.id)
    }

    func toggleTurn(_ id: String) {
        if turnToggled.contains(id) { turnToggled.remove(id) } else { turnToggled.insert(id) }
    }

    /// The key of the row under the keyboard cursor in the Changes tab.
    var cursorRowKey: String? {
        if selectedTab == .git { return gitCursorRowKey }
        guard selectedTab == .changes else { return nil }
        let rows = changesRows
        return rows.indices.contains(rowCursor) ? rows[rowCursor].id : nil
    }

    /// The lines a diff row shows: the whole patch, or the snippet when no patch was recorded.
    static func diffLines(_ file: FileChange) -> [DiffLine] {
        file.patch.isEmpty ? file.snippet : file.patch
    }

    /// Short diffs open by default; a click or ⏎ flips a row.
    func isDiffOpen(_ item: DiffRowItem) -> Bool {
        let count = Self.diffLines(item.file).count
        let openByDefault = count > 0 && count < Theme.Limits.inlineSnippetMaxLines
        return openByDefault != diffToggled.contains(item.key)
    }

    func toggleDiff(_ key: String) {
        if diffToggled.contains(key) { diffToggled.remove(key) } else { diffToggled.insert(key) }
    }

    /// Moves the keyboard cursor to a row the owner clicked.
    func setRowCursor(key: String) {
        if selectedTab == .git { setGitRowCursor(key: key); return }
        if let index = changesRows.firstIndex(where: { $0.id == key }) {
            rowCursor = index
        }
    }

    /// "y" in Changes: copies `path:line` of the first changed line of the file row under the cursor.
    func copyCursorLocation() -> Bool {
        let rows = changesRows
        guard rows.indices.contains(rowCursor), case .file(let item) = rows[rowCursor] else { return false }
        copyLocation(path: item.file.path, line: Self.firstChangedLine(item.file))
        return true
    }

    /// Puts `/abs/path:line` on the pasteboard and says so in the footer.
    func copyLocation(path relative: String, line: Int) {
        var path = relative
        if !path.hasPrefix("/"), let cwd = focusedSession?.cwd, !cwd.isEmpty {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(path):\(line)", forType: .string)
        flash("Copied " + Format.fileName(relative) + ":\(line)")
    }

    /// The new-file line number of the first added line, else the old one of the first removed line.
    static func firstChangedLine(_ file: FileChange) -> Int {
        for line in diffLines(file) {
            if line.kind == .added, let n = line.newLine { return n }
            if line.kind == .removed, let n = line.oldLine ?? line.newLine { return n }
        }
        return 1
    }

    // MARK: Shell changes

    /// Where shell changes wait while their turn is not in the transcript yet.
    static let pendingTurnKey = "~pending"

    /// A Bash call's working-tree report: every file that differs from the baseline is
    /// attributed to the session's current turn as a "shell" change, then the report becomes
    /// the new baseline. Silent: no peek. With no baseline yet (the app started mid-turn),
    /// the report only becomes the baseline.
    func handleShellTree(_ report: TreeReport?, sessionId sid: String, cwd: String) {
        guard let report else { return }
        let now = UnifiedDiff.snapshot(report)
        defer { treeSnapshots[sid] = now }
        guard let baseline = treeSnapshots[sid], baseline.root == now.root else { return }
        let changed = UnifiedDiff.changes(from: baseline, to: now, cwd: cwd)
        guard !changed.isEmpty else { return }

        var files = turnFiles[sid] ?? []
        var counts = turnShellCounts[sid] ?? [:]
        for file in changed {
            let absolute = Paths.absolute(file.path, cwd: cwd)
            if !files.contains(absolute) {
                files.append(absolute)
                counts[absolute] = (file.added, file.removed)
            } else if counts[absolute] != nil {
                counts[absolute] = (file.added, file.removed)
            }
        }
        turnFiles[sid] = files
        turnShellCounts[sid] = counts

        attachShellFiles(changed, sessionId: sid,
                         turnId: shellTurnId(for: sid, in: turnsBySession[sid] ?? []) ?? Self.pendingTurnKey)
    }

    /// The turn shell changes belong to: the newest turn, if it started with the current turn
    /// (the transcript can lag the UserPromptSubmit hook). Nil while it has not arrived.
    func shellTurnId(for sid: String, in turns: [TranscriptTurn]) -> String? {
        guard let newest = turns.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        if let start = turnStarts[sid], newest.startedAt < start.addingTimeInterval(-Theme.Timing.turnMatchSlack) {
            return nil
        }
        return newest.id
    }

    /// Adds `changed` to a turn's shell files: a path seen before is replaced in place, a new one appended.
    func attachShellFiles(_ changed: [FileChange], sessionId sid: String, turnId: String) {
        var list = shellFiles[sid]?[turnId] ?? []
        for file in changed {
            if let index = list.firstIndex(where: { $0.path == file.path }) {
                list[index] = file
            } else {
                list.append(file)
            }
        }
        shellFiles[sid, default: [:]][turnId] = list
    }

    /// The open question's options, from the transcript's last `AskUserQuestion` call (the
    /// one asking the same thing when the texts match, else the latest). The transcript may
    /// lag the Notification; `applyTurns` tries again.
    func fillQuestionOptions(_ sid: String) {
        guard var current = question, current.sessionId == sid, current.options.isEmpty,
              let path = session(id: sid)?.transcriptPath,
              let asked = TranscriptReader.lastQuestion(transcriptPath: path), !asked.options.isEmpty else { return }
        if asked.question == current.question || current.question.contains(asked.question) {
            current.question = asked.question
        }
        current.options = asked.options
        question = current
    }

    func reloadTurns(for sid: String) {
        guard readsLocalFiles, let path = session(id: sid)?.transcriptPath else { return }
        Task.detached(priority: .utility) { [weak self] in
            let turns = (try? TranscriptReader.turns(transcriptPath: path)) ?? []
            await self?.applyTurns(turns, for: sid)
        }
    }

    private func applyTurns(_ turns: [TranscriptTurn], for sid: String) {
        guard session(id: sid) != nil else { return }
        // Shell changes seen before their turn reached the transcript: attach them now.
        if let held = shellFiles[sid]?[Self.pendingTurnKey], let turnId = shellTurnId(for: sid, in: turns) {
            shellFiles[sid]?[Self.pendingTurnKey] = nil
            attachShellFiles(held, sessionId: sid, turnId: turnId)
        }
        if question?.sessionId == sid, question?.options.isEmpty == true { fillQuestionOptions(sid) }
        if turnsBySession[sid] != turns {
            turnsBySession[sid] = turns
            // New edits: the open preview's text and tints may have moved.
            if isCardOpen, selectedTab == .files, sid == focusedSession?.id { reloadOpenedPreview() }
        }
        // Sessions hooks never announced: the elapsed clock runs from the open turn.
        if !isHookDriven(sid), let open = turns.max(by: { $0.startedAt < $1.startedAt }), open.endedAt == nil {
            turnStarts[sid] = open.startedAt
        }
        recomputeUsage()
    }
}
