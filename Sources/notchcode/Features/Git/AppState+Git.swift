// AppState+Git.swift
// The Git tool's state on AppState: where it is stored and how every write goes through
// `updateGit`, what the tool shows (the target, its snapshot and phase, the rows, the sync
// pill's words), when it refreshes (card open, tool shown, polling) and its keys. The value
// types are in GitModel.swift.

import SwiftUI

extension AppState {

    // MARK: Storage

    // The state itself is stored on AppState (`gitStore`, `gitPollTask`, `gitHoldTask`);
    // every write goes through `updateGit`, which tells SwiftUI.

    var gitPanel: GitPanelState { gitStore }

    func updateGit(_ change: (inout GitPanelState) -> Void) {
        var next = gitStore
        change(&next)
        guard next != gitStore else { return }
        objectWillChange.send()
        gitStore = next
    }

    // MARK: What the tool shows

    /// The branch picked by hand, else the focused session's folder.
    var gitTarget: GitTarget? {
        if let picked = gitPanel.picked { return picked }
        return focusedGitCwd.map { .folder($0) }
    }

    /// Where the tool's snapshot and push phase live: the target's key.
    var gitCwd: String? { gitTarget?.key }

    /// The focused session's folder, when it has one.
    private var focusedGitCwd: String? {
        guard let cwd = focusedSession?.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// The focused session's worktree top level, when a read or a listing has found it.
    private var focusedGitRoot: String? {
        guard let cwd = focusedGitCwd else { return nil }
        return gitPanel.snapshots[cwd]?.root ?? gitPanel.rootByCwd[cwd]
    }

    /// The target is the focused session's checkout (always, until a hand pick). A branch
    /// checked out nowhere says so in its status instead.
    var gitTargetIsFocused: Bool {
        guard let picked = gitPanel.picked else { return true }
        guard case .folder(let path) = picked else { return true }
        return focusedGitRoot == path
    }

    /// The target pill's parts: "notchcode" dim, then "seadevil" (the worktree folder) or,
    /// for a branch checked out nowhere, "design/toolbar" in mono. No repository part for a
    /// main checkout named like its repository.
    var gitTargetParts: (repo: String?, place: String, placeIsBranch: Bool) {
        if case .branch(let repo, let name) = gitTarget {
            let repoName = gitPanel.repos.first { $0.id == repo }?.name ?? focusedGit?.repoName
            return (repoName, name, true)
        }
        let root = focusedGit?.root ?? gitCwd ?? ""
        let folder = URL(fileURLWithPath: root).lastPathComponent
        let repo = gitPanel.repos.first { $0.branches.contains { $0.path == root } }?.name
            ?? focusedGit?.repoName
        guard let repo, !repo.isEmpty, repo != folder else { return (nil, folder, false) }
        return (repo, folder, false)
    }

    var focusedGit: GitSnapshot? {
        gitCwd.flatMap { gitPanel.snapshots[$0] }
    }

    /// The write phase of the target.
    var gitPhase: GitPhase {
        guard let cwd = gitCwd, gitPanel.phaseCwd == cwd else { return .idle }
        return gitPanel.phase
    }

    /// The uncommitted files (a branch page: its changes) as rows; `rowCursor` indexes them
    /// while the Git tool shows.
    var gitRows: [DiffRowItem] {
        (focusedGit?.files ?? []).map { DiffRowItem(key: "g|" + $0.path, file: $0) }
    }

    var gitCursorRowKey: String? {
        let rows = gitRows
        return rows.indices.contains(rowCursor) ? rows[rowCursor].key : nil
    }

    /// The file whose diff the right pane shows: the cursor's row, the first file by default
    /// (as GitHub Desktop selects). Nil with nothing to show.
    var gitSelectedFile: FileChange? {
        let rows = gitRows
        return rows.indices.contains(rowCursor) ? rows[rowCursor].file : nil
    }

    /// The rail is folded to its checkbox column (⌘B). One preference with the Files tree: the
    /// left column of both tools. Only while there is a file, as Files needs an open file.
    var gitListCollapsed: Bool {
        prefs.filesTreeHidden && gitSelectedFile != nil
    }

    /// ⌘B or the pill. Does nothing with no file to show.
    func toggleGitList() {
        guard gitSelectedFile != nil else { return }
        setFilesTreeHidden(!gitListCollapsed)
    }

    func setGitRowCursor(key: String) {
        if let index = gitRows.firstIndex(where: { $0.key == key }) { rowCursor = index }
    }

    /// What the header's pill offers, first match wins, in GitHub Desktop's order: nothing
    /// without a branch or a remote; Publish without an upstream; Pull when behind (a checkout
    /// only: a branch page never pulls); Push when ahead; else Fetch.
    var gitSyncOp: GitOp? {
        guard let snap = focusedGit, snap.isRepo, snap.branch != nil, snap.remote != nil else { return nil }
        if snap.upstream == nil { return .publish }
        if snap.checkedOut, snap.behind > 0 { return .pull }
        if snap.ahead > 0 { return .push }
        return .fetch
    }

    /// The pill can be pressed: it offers something, and no write runs or holds a sync's
    /// result (`GitPhase.blocksSync`).
    var gitCanSync: Bool {
        !gitPhase.blocksSync && gitSyncOp != nil
    }

    /// "Publish", "Pull", "Push", "Fetch"; "Push" on the disabled pill.
    var gitSyncVerb: String {
        (gitSyncOp ?? .push).verb
    }

    /// The count in the pill: the commits a push or publish would send, or a pull would bring.
    /// Nil for a fetch, when none, and while a write runs or holds a sync's result.
    var gitSyncCount: Int? {
        guard !gitPhase.blocksSync, let op = gitSyncOp, let snap = focusedGit else { return nil }
        let count: Int
        switch op {
        case .push, .publish: count = snap.unpushed
        case .pull: count = snap.behind
        case .fetch, .commit, .undo: return nil
        }
        return count > 0 ? count : nil
    }

    /// "not published yet", "up to date with origin", "2 behind origin", "no remote"; with
    /// commits to push (their count sits in the pill) only "2 behind", or nothing. For a branch
    /// checked out nowhere "not checked out · 4 commits ahead of main".
    var gitStatusText: String {
        guard let snap = focusedGit, snap.isRepo else { return "" }
        if !snap.checkedOut {
            let lead = "not checked out"
            guard let base = snap.base else { return lead }
            let ahead = snap.baseAhead == 0 ? "nothing ahead of " + base : Self.commits(snap.baseAhead) + " ahead of " + base
            return lead + Theme.Glyphs.separator + ahead
        }
        guard snap.branch != nil else { return "detached HEAD" }
        guard let remote = snap.remote else { return "no remote" }
        guard snap.upstream != nil else { return "not published yet" }
        if snap.ahead > 0 {
            // Behind as well: the pill pulls, so the status names what waits to be pushed.
            return snap.behind > 0 && snap.checkedOut ? "\(snap.ahead) ahead" + Theme.Glyphs.separator + "\(snap.behind) behind" : ""
        }
        if snap.behind > 0 { return Self.commits(snap.behind) + " behind " + remote }
        return "up to date with " + remote
    }

    /// "Push 3 commits to origin/seadevil?", "Publish seadevil to origin?" or "Pull 2 commits
    /// from origin/main?". Names exactly the remote and branch `runGitSync` passes to git.
    var gitConfirmText: String {
        guard let snap = focusedGit, let branch = snap.branch, let remote = snap.remote else { return "" }
        switch gitPhase.op ?? gitSyncOp {
        case .publish?: return "Publish " + branch + " to " + remote + "?"
        case .push?: return "Push " + Self.commits(snap.ahead) + " to " + Self.pushDestination(snap) + "?"
        case .pull?: return "Pull " + Self.commits(snap.behind) + " from " + (snap.upstream ?? Self.pushDestination(snap)) + "?"
        case .fetch?, .commit?, .undo?, nil: return ""
        }
    }

    /// The confirm's line while git runs: "Pushing to origin/seadevil…", "Publishing seadevil
    /// to origin…", "Pulling from origin/main…".
    var gitRunningText: String {
        guard let snap = focusedGit, case .running(let op) = gitPhase else { return "" }
        let remote = snap.remote ?? ""
        switch op {
        case .publish: return "Publishing " + (snap.branch ?? "") + " to " + remote + Theme.Glyphs.ellipsis
        case .push: return "Pushing to " + Self.pushDestination(snap) + Theme.Glyphs.ellipsis
        case .pull: return "Pulling from " + (snap.upstream ?? Self.pushDestination(snap)) + Theme.Glyphs.ellipsis
        case .fetch, .commit, .undo: return op.runningTitle + Theme.Glyphs.ellipsis
        }
    }

    /// "origin/seadevil": the remote and its branch a push to the upstream updates.
    nonisolated static func pushDestination(_ snap: GitSnapshot) -> String {
        guard let remote = snap.remote, let branch = snap.upstreamBranch ?? snap.branch else { return snap.upstream ?? "" }
        return remote + "/" + branch
    }

    nonisolated static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    // MARK: Refresh triggers

    /// The card opened: read once whatever tool shows (PLAN: "once when the card opens").
    func gitCardOpened() {
        if selectedTab == .git { gitToolShown() } else { refreshGit() }
    }

    /// The Git tool came on screen: a fresh read, then one every `gitRefreshInterval`.
    func gitToolShown() {
        cancelGitConfirm()
        closeGitPicker()
        refreshGit(thenFetch: true)
        gitAutoFetchIfDue()
        startGitPolling()
    }

    /// Another session is focused: its worktree, and no confirm carried over. A hand pick
    /// stays; the listing is read again so the header knows whether it is still the focused one.
    func gitFocusChanged() {
        if gitPanel.picked != nil {
            if gitPanel.rootByCwd[focusedGitCwd ?? ""] == nil { refreshGitWorktrees() }
            return
        }
        cancelGitConfirm()
        refreshGit()
    }

    /// The card closed: the hand pick and the picker go; next time the tool follows the focus.
    func gitCardClosed() {
        updateGit {
            $0.picked = nil
            $0.resetPicker()
            $0.drafts = [:]
        }
    }

    /// A hook's tree report arrived (a Bash command ran): the worktree may have changed.
    func gitTreeReported(cwd: String) {
        guard isCardOpen, selectedTab == .git, let target = gitCwd else { return }
        guard cwd == target || gitPanel.rootByCwd[cwd] == target else { return }
        refreshGit()
    }

    private func startGitPolling() {
        guard gitPollTask == nil else { return }
        gitPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Theme.Timing.gitRefreshInterval))
                // Stops once the card closes or another tool is picked; a request over the
                // tool only pauses it.
                guard let self, self.isCardOpen, self.selectedTab == .git else { break }
                if self.isShowingTool(.git) { self.refreshGit(poll: true) }
            }
            self?.gitPollTask = nil
        }
    }

    /// Reads the target in the background. A poll keeps a write's error on screen; any other
    /// refresh clears it. `thenFetch`: once read, fetch its remote quietly if it is due.
    func refreshGit(poll: Bool = false, thenFetch: Bool = false) {
        guard readsLocalFiles, let target = gitTarget else { return }
        let key = target.key
        if !poll, gitPanel.phaseCwd == key, case .failed = gitPanel.phase {
            updateGit { $0.phase = .idle }
        }
        guard !gitPanel.loading.contains(key) else { return }
        updateGit { $0.loading.insert(key) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot: GitSnapshot
            switch target {
            case .folder(let cwd): snapshot = await GitRunner.read(cwd: cwd)
            case .branch(let repo, let name): snapshot = await GitRunner.readBranch(repo: repo, name: name, key: key)
            }
            await self?.applyGit(snapshot, thenFetch: thenFetch)
        }
    }

    private func applyGit(_ snapshot: GitSnapshot, thenFetch: Bool) {
        updateGit {
            $0.loading.remove(snapshot.cwd)
            $0.snapshots[snapshot.cwd] = snapshot
        }
        debugLog("git \(snapshot.cwd): repo=\(snapshot.isRepo) checkedOut=\(snapshot.checkedOut) branch=\(snapshot.branch ?? "-") upstream=\(snapshot.upstream ?? "-") base=\(snapshot.base ?? "-") ahead=\(snapshot.ahead) behind=\(snapshot.behind) unpushed=\(snapshot.unpushed) files=\(snapshot.files.count) +\(snapshot.files.reduce(0) { $0 + $1.added }) -\(snapshot.files.reduce(0) { $0 + $1.removed }) commits=\(snapshot.commits.count)")
        guard snapshot.cwd == gitCwd else { return }
        if isShowingTool(.git) {
            let count = snapshot.files.count
            if rowCursor >= count { rowCursor = max(0, count - 1) }
        }
        // The pill offers something else now (pushed from the terminal, or a fetch found
        // commits to pull while a push was asked): drop the confirm.
        if case .confirming(let op) = gitPhase, !gitCanSync || op != gitSyncOp { updateGit { $0.phase = .idle } }
        if thenFetch { gitAutoFetchIfDue() }
    }

    // MARK: Keys

    /// Esc in the Git tool, one layer at a time: the repository dropdown, then the picker's
    /// filter, then the picker, then the commit form, then the confirm. False: nothing left,
    /// the card closes.
    func gitEscape() -> Bool {
        if gitPanel.pickerOpen {
            if gitPanel.repoMenuOpen {
                updateGit { $0.repoMenuOpen = false }
                return true
            }
            if gitPanel.filterFocused || !gitPanel.filter.isEmpty {
                withAnimation(Theme.Motion.filterRows) { setGitFilter("") }
                setGitFilterFocused(false)
                return true
            }
        }
        return closeGitPicker() || cancelGitCommitForm() || cancelGitConfirm()
    }

    /// What esc does next, for the footer: "close" the dropdown, "clear" the filter, "back"
    /// out of the picker or the commit form, "cancel" the confirm; nil when it closes the card.
    var gitEscapeLabel: String? {
        guard gitPanel.pickerOpen else {
            if gitDraft.composing { return "back" }
            if case .confirming = gitPhase { return "cancel" }
            return nil
        }
        if gitPanel.repoMenuOpen { return "close" }
        if gitPanel.filterFocused || !gitPanel.filter.isEmpty { return "clear" }
        return "back"
    }

    /// The Git tool's keys. Nil: not a Git key, let the card handle it.
    func handleGitKey(_ key: NotchKey) -> Bool? {
        if gitPanel.pickerOpen {
            if gitPanel.repoMenuOpen {
                switch key {
                case .up, .down:
                    let count = gitPanel.repos.count
                    guard count > 0 else { return true }
                    let next = max(0, min(count - 1, gitPanel.repoMenuCursor + (key == .up ? -1 : 1)))
                    updateGit { $0.repoMenuCursor = next }
                    return true
                case .primary:
                    let repos = gitPanel.repos
                    if repos.indices.contains(gitPanel.repoMenuCursor) { chooseGitRepo(repos[gitPanel.repoMenuCursor].id) }
                    return true
                case .repository:
                    updateGit { $0.repoMenuOpen = false }
                    return true
                case .worktree:
                    closeGitPicker()
                    return true
                case .nextTab, .previousTab, .number, .settings, .teleport, .escape, .quit:
                    return nil
                default:
                    return true     // the dropdown has the keys; nothing under it reacts
                }
            }
            switch key {
            case .up, .down:
                let count = gitPickerRows.count
                guard count > 0 else { return true }
                let next = max(0, min(count - 1, gitPanel.pickerCursor + (key == .up ? -1 : 1)))
                updateGit { $0.pickerCursor = next }
                return true
            case .primary:
                let rows = gitPickerRows
                if rows.indices.contains(gitPanel.pickerCursor) { pickGitBranch(rows[gitPanel.pickerCursor]) }
                return true
            case .worktree:
                closeGitPicker()
                return true
            case .repository:       // R
                openGitRepoMenu()
                return true
            case .filter:           // /
                if gitPickerShowsFilter { setGitFilterFocused(true) }
                return true
            case .markdownMode, .left, .right, .copy, .diff, .toggleTree:
                return true     // the picker has the keys; nothing under it reacts
            default:
                return nil
            }
        }
        switch key {
        case .worktree:         // W
            openGitPicker()
            return true
        case .markdownMode:     // P
            pressGitSync()
            return true
        case .commit:           // C
            openGitCommitForm()
            return true
        case .undo:             // U: not while composing (the refill would replace the draft)
            guard gitCanUndo, !gitDraft.composing else { return nil }
            runGitUndo()
            return true
        case .toggle:           // space
            guard focusedGit?.checkedOut == true, let file = gitSelectedFile else { return nil }
            toggleGitFile(path: file.path)
            return true
        case .submit:           // ⌘⏎
            if gitDraft.composing { runGitCommit() }
            return true
        case .primary:
            // The selected file's diff already shows; ⏎ confirms a sync, or commits from the
            // form when no field has the keys (the summary's own ⏎ commits through onSubmit).
            if case .confirming = gitPhase {
                runGitSync()
            } else if gitDraft.composing {
                runGitCommit()
            }
            return true
        case .toggleTree:       // ⌘B
            toggleGitList()
            return true
        case .up, .down:
            // Selecting shows that file's diff at once. The list comes back first, as the
            // Files tree does.
            // The rail stays folded: the stage header names the file.
            let count = gitRows.count
            guard count > 0 else { return false }
            // As a click on a row: the stage shows the diff, the draft keeps its text, a
            // confirm is dropped.
            if gitDraft.composing { setGitComposing(false) }
            cancelGitConfirm()
            rowCursor = max(0, min(count - 1, rowCursor + (key == .up ? -1 : 1)))
            return true
        default:
            return nil
        }
    }
}
