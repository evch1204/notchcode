// AppState+Changes.swift
// The Changes tool, Direction G (Timeline): the session's turns, newest first, as blocks (a
// turn with files is an entry, a run of turns without files one quiet group, the live turn
// always first), the cursor's stops through them in reading order (chips, group rows,
// unfolded quiet rows, the live turn with no edits yet), the chip whose diff the pane shows,
// the With edits filter, and the changes shell commands made.

import AppKit
import SwiftUI

/// One expandable file row in the Git tool's rail. `key` is stable across reloads.
struct DiffRowItem: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var file: FileChange
}

/// A file chip: the file `path` as the turn `turnId` changed it.
struct ChangesChipKey: Hashable {
    var turnId: String
    var path: String
}

/// One block of the timeline, newest first.
enum ChangesBlock: Identifiable, Equatable {
    /// A turn with files, or the live turn. `number` counts from the session's first turn.
    case entry(TranscriptTurn, number: Int, live: Bool)
    /// A run of turns without files, newest first; keyed by its newest turn's id.
    case quiet(id: String, turns: [TranscriptTurn])

    var id: String {
        switch self {
        case .entry(let turn, _, _): return "e|" + turn.id
        case .quiet(let id, _): return "g|" + id
        }
    }
}

/// A stop of the Changes cursor (`rowCursor` indexes `changesCursorItems`).
enum ChangesItem: Identifiable, Equatable {
    /// The live turn while it has no edits: the cursor rests on it.
    case live(turnId: String)
    case chip(ChangesChipKey)
    /// A quiet group's row.
    case group(id: String)
    /// One turn of an unfolded quiet group.
    case quiet(turnId: String)

    var id: String {
        switch self {
        case .live(let id): return "l|" + id
        case .chip(let key): return AppState.changesChipID(key)
        case .group(let id): return "g|" + id
        case .quiet(let id): return "q|" + id
        }
    }
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

    // MARK: The timeline

    nonisolated static func changesChipID(_ key: ChangesChipKey) -> String { "c|\(key.turnId)|\(key.path)" }

    /// The turn still running: the newest one while the session works (or waits on the
    /// owner, or its background agents still run), or one the transcript left open. Nil when
    /// every turn is finished.
    func changesLiveTurnId(_ turns: [TranscriptTurn]) -> String? {
        guard let newest = turns.first, let session = focusedSession else { return nil }
        if newest.endedAt == nil || !runningAgents(for: session.id).isEmpty { return newest.id }
        switch session.state {
        case .working, .needsYou: return newest.id
        default: return nil
        }
    }

    /// The timeline's blocks for the focused session, newest first. With edits on, the
    /// quiet groups are left out; the live turn always shows.
    var changesBlocks: [ChangesBlock] {
        let turns = turns(for: focusedSession?.id)
        let live = changesLiveTurnId(turns)
        var blocks: [ChangesBlock] = []
        var run: [TranscriptTurn] = []
        func flush() {
            if let first = run.first, !changesEditsOnly { blocks.append(.quiet(id: first.id, turns: run)) }
            run = []
        }
        for (index, turn) in turns.enumerated() {
            let isLive = turn.id == live
            if isLive || !turn.files.isEmpty {
                flush()
                blocks.append(.entry(turn, number: turns.count - index, live: isLive))
            } else {
                run.append(turn)
            }
        }
        flush()
        return blocks
    }

    /// The cursor's stops in reading order: each entry's chips (the live turn itself while
    /// it has none), each quiet group's row, and an unfolded group's turns under it.
    var changesCursorItems: [ChangesItem] {
        var items: [ChangesItem] = []
        for block in changesBlocks {
            switch block {
            case .entry(let turn, _, _):
                if turn.files.isEmpty {
                    items.append(.live(turnId: turn.id))
                } else {
                    items += turn.files.map { .chip(ChangesChipKey(turnId: turn.id, path: $0.path)) }
                }
            case .quiet(let id, let turns):
                items.append(.group(id: id))
                if changesUnfoldedGroups.contains(id) {
                    items += turns.map { .quiet(turnId: $0.id) }
                }
            }
        }
        return items
    }

    /// The key of the stop under the keyboard cursor in the Changes tool.
    var cursorRowKey: String? {
        guard selectedTab == .changes else { return nil }
        let items = changesCursorItems
        return items.indices.contains(rowCursor) ? items[rowCursor].id : nil
    }

    /// The chip under the cursor, if the cursor is on one.
    var changesCursorChip: ChangesChipKey? {
        let items = changesCursorItems
        guard items.indices.contains(rowCursor), case .chip(let key) = items[rowCursor] else { return nil }
        return key
    }

    /// The diff pane shows: a chip is selected and the pane is open.
    var changesPaneShown: Bool {
        changesPaneOpen && changesSelectedFile != nil
    }

    /// The selected chip's turn, file and the turn's number, when both still exist.
    var changesSelectedFile: (turn: TranscriptTurn, file: FileChange, number: Int)? {
        guard let key = changesSelection else { return nil }
        let turns = turns(for: focusedSession?.id)
        guard let index = turns.firstIndex(where: { $0.id == key.turnId }),
              let file = turns[index].files.first(where: { $0.path == key.path }) else { return nil }
        return (turns[index], file, turns.count - index)
    }

    /// Every view choice goes back to its default: a new session, or the app's start.
    func resetChangesView() {
        changesSelection = nil
        changesPaneOpen = false
        changesEditsOnly = false
        changesUnfoldedGroups = []
        changesColumnHidden = false
    }

    /// Runs `change` with the cursor kept on the same stop when it still exists; otherwise
    /// the cursor stays where it was, clamped to the new list.
    private func keepingChangesCursor(_ change: () -> Void) {
        let before = cursorRowKey
        change()
        let items = changesCursorItems
        if let before, let index = items.firstIndex(where: { $0.id == before }) {
            rowCursor = index
        } else {
            rowCursor = max(0, min(items.count - 1, rowCursor))
        }
    }

    /// A click on a chip: the cursor lands on it and the pane shows its diff.
    func selectChangesChip(_ key: ChangesChipKey) {
        withAnimation(Theme.Motion.changesLayout) {
            if let index = changesCursorItems.firstIndex(of: .chip(key)) { rowCursor = index }
            changesSelection = key
            changesPaneOpen = true
        }
    }

    /// A click or ⏎ on a quiet group's row: its turns unfold under it, or fold away.
    func toggleChangesGroup(_ id: String) {
        withAnimation(Theme.Motion.changesLayout) {
            keepingChangesCursor {
                if changesUnfoldedGroups.contains(id) { changesUnfoldedGroups.remove(id) } else { changesUnfoldedGroups.insert(id) }
            }
            if let index = changesCursorItems.firstIndex(of: .group(id: id)) { rowCursor = index }
        }
    }

    /// `/`: With edits on or off. The cursor stays on its chip; from a quiet row it moves on.
    func toggleChangesEditsOnly() {
        withAnimation(Theme.Motion.changesLayout) {
            keepingChangesCursor { changesEditsOnly.toggle() }
        }
    }

    /// ⌘B while the pane shows: the timeline column goes, the pane takes the width; again brings it back.
    func toggleChangesColumn() {
        guard changesPaneShown else { return }
        withAnimation(Theme.Motion.changesLayout) { changesColumnHidden.toggle() }
    }

    /// Esc in the Changes tool: a hidden column comes back, then the pane closes (the chip
    /// stays the cursor). False when there is nothing to back out of, so esc closes the card.
    func changesEscape() -> Bool {
        guard changesPaneShown else { return false }
        withAnimation(Theme.Motion.changesLayout) {
            if changesColumnHidden {
                changesColumnHidden = false
            } else {
                changesPaneOpen = false
            }
        }
        return true
    }

    /// The Changes tool's own keys; nil for the keys every tool shares (numbers, ⇥).
    func handleChangesKey(_ key: NotchKey) -> Bool? {
        switch key {
        case .up, .down:
            let items = changesCursorItems
            guard !items.isEmpty else { return false }
            let next = max(0, min(items.count - 1, rowCursor + (key == .up ? -1 : 1)))
            withAnimation(Theme.Motion.changesLayout) {
                rowCursor = next
                // The pane follows the cursor from chip to chip.
                if changesPaneOpen, case .chip(let chip) = items[next] { changesSelection = chip }
            }
            return true
        case .primary:
            let items = changesCursorItems
            guard items.indices.contains(rowCursor) else { return false }
            switch items[rowCursor] {
            case .chip(let chip):
                if changesPaneShown, changesSelection == chip {
                    // The diff is already up: ⏎ again goes to the terminal, as ⌥⏎ does.
                    teleport(session: focusedSession)
                } else {
                    selectChangesChip(chip)
                }
            case .group(let id):
                toggleChangesGroup(id)
            case .live, .quiet:
                break
            }
            return true
        case .copy:
            return copyCursorLocation()
        case .filter:
            toggleChangesEditsOnly()
            return true
        case .toggleTree:
            toggleChangesColumn()
            return true
        default:
            return nil
        }
    }

    /// "y" in Changes: copies `path:line` of the first changed line of the chip under the cursor.
    func copyCursorLocation() -> Bool {
        guard let key = changesCursorChip,
              let file = turns(for: focusedSession?.id).first(where: { $0.id == key.turnId })?.files.first(where: { $0.path == key.path })
        else { return false }
        copyLocation(path: file.path, line: Self.firstChangedLine(file))
        return true
    }

    /// The lines a diff shows: the whole patch, or the snippet when no patch was recorded.
    static func diffLines(_ file: FileChange) -> [DiffLine] {
        file.patch.isEmpty ? file.snippet : file.patch
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
    /// `agentId`: the subagent whose Bash call it was (the hook's `agent_id`), marked on the files.
    func handleShellTree(_ report: TreeReport?, sessionId sid: String, cwd: String, agentId: String? = nil) {
        guard let report else { return }
        let now = UnifiedDiff.snapshot(report)
        defer { treeSnapshots[sid] = now }
        guard let baseline = treeSnapshots[sid], baseline.root == now.root else { return }
        var changed = UnifiedDiff.changes(from: baseline, to: now, cwd: cwd)
        guard !changed.isEmpty else { return }
        if let agentId, !agentId.isEmpty {
            for index in changed.indices { changed[index].agentId = agentId }
        }

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
        loadShellFiles(sid)
        var list = shellFiles[sid]?[turnId] ?? []
        for file in changed {
            if let index = list.firstIndex(where: { $0.path == file.path }) {
                list[index] = file
            } else {
                list.append(file)
            }
        }
        shellFiles[sid, default: [:]][turnId] = list
        ShellChangesStore.save(shellFiles[sid] ?? [:], sessionId: sid)
    }

    /// Brings back the session's shell changes saved before a relaunch, once per session;
    /// what is already in memory wins on the same turn.
    func loadShellFiles(_ sid: String) {
        guard readsLocalFiles, !shellFilesLoaded.contains(sid) else { return }
        shellFilesLoaded.insert(sid)
        let saved = ShellChangesStore.load(sessionId: sid)
        guard !saved.isEmpty else { return }
        shellFiles[sid] = saved.merging(shellFiles[sid] ?? [:]) { _, current in current }
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
        loadShellFiles(sid)
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
