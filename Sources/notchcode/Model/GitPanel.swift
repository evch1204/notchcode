// GitPanel.swift
// The Git tool's model: what is uncommitted in the target checkout, how far the branch is
// ahead of its upstream, the last five commits, and the push with its confirm. The target
// is the focused session's worktree until the owner picks a branch in the branch picker (W):
// one repository at a time (R opens the repository dropdown), every local branch in it,
// each saying where it lives. A branch checked out nowhere gets a read-only page: its
// changes against main (or its upstream), its commits, and Push; never a checkout.
//
// The one place the app runs a command itself (PLAN.md, "Git tool"): `/usr/bin/git` and
// nothing else, off the main thread, with GIT_OPTIONAL_LOCKS=0. Read-only commands for the
// page; `git push` only after the owner pressed Push (or P) and then confirmed with ⏎.
// Never commits, stages, fetches or switches branches.

import AppKit
import SwiftUI

/// One line of "Recent commits".
struct GitCommit: Identifiable, Equatable {
    var id: String { sha }
    var sha: String
    var subject: String
    var date: Date
    /// On the remote already. False for commits ahead of the upstream (or, for a branch
    /// with no upstream, on no remote at all).
    var pushed: Bool
}

/// What the Git tool shows: a checkout (a session's folder, or a picked checkout's top
/// level), or a branch that is checked out nowhere, read from its repository's main folder.
enum GitTarget: Equatable {
    case folder(String)
    case branch(repo: String, name: String)

    /// Snapshots and the push phase are kept under this.
    var key: String {
        switch self {
        case .folder(let path): return path
        case .branch(let repo, let name): return repo + "\u{1f}" + name
        }
    }
}

/// The target as the last read left it.
struct GitSnapshot: Equatable {
    /// The target's key (`GitTarget.key`): a folder, or repository and branch.
    var cwd: String
    var isRepo: Bool
    /// The work tree's top level (a branch page: the main folder); every git command runs there.
    var root = ""
    /// The repository's name: its main checkout's folder (a bare repository without ".git").
    var repoName: String?
    /// Nil on a detached HEAD.
    var branch: String?
    /// "origin/seadevil"; nil when the branch was never published.
    var upstream: String?
    /// The remote a push goes to: the upstream's, else origin, else the first. Nil: no remote.
    var remote: String?
    var ahead = 0
    var behind = 0
    /// Commits a push would send: `ahead`, or for an unpublished branch the commits on no remote.
    var unpushed = 0
    /// False for a branch checked out nowhere: `files` are its changes against `base`.
    var checkedOut = true
    /// What a branch page compares against: its upstream, else the default branch.
    var base: String?
    /// Commits in `base..branch`.
    var baseAhead = 0
    var files: [FileChange] = []
    var commits: [GitCommit] = []
    /// Path -> lines in the file as the branch has it, for the diff's minimap.
    var lineCounts: [String: Int] = [:]
}

/// The push, from the press to its result. Belongs to one target (`GitPanelState.phaseCwd`).
enum GitPushPhase: Equatable {
    case idle
    /// "Push 3 commits to origin/seadevil?": ⏎ pushes, esc cancels.
    case confirming
    case pushing
    /// "Pushed 3 commits", for `Theme.Timing.gitPushedHold`.
    case pushed(String)
    /// The first useful line of git's error output; stays until a refresh other than the poll.
    case failed(String)
}

/// One local branch, as the picker lists it.
struct GitBranch: Identifiable, Equatable {
    enum Place: Equatable {
        /// Checked out in the repository's main folder.
        case main(String)
        /// Checked out in a linked worktree.
        case worktree(String)
        /// Checked out nowhere.
        case nowhere
    }

    var id: String { name }
    var name: String
    /// "origin/main"; nil when never published.
    var upstream: String?
    var date: Date
    var place: Place
    /// Uncommitted files of its checkout; nil when checked out nowhere or the read failed.
    var uncommitted: Int?
    /// Commits ahead of `upstream`, or of the default branch when it has none. Nil: not counted.
    var ahead: Int?

    /// The checkout's folder; nil when checked out nowhere.
    var path: String? {
        switch place {
        case .main(let path), .worktree(let path): return path
        case .nowhere: return nil
        }
    }
}

/// One repository in the picker: its local branches, newest commit first.
struct GitRepoGroup: Identifiable, Equatable {
    /// The main folder's path.
    var id: String
    var name: String
    /// "main", else "master"; nil when neither exists.
    var defaultBranch: String?
    var branches: [GitBranch]
}

struct GitPanelState: Equatable {
    /// Target key -> its last read.
    var snapshots: [String: GitSnapshot] = [:]
    /// Keys being read right now.
    var loading: Set<String> = []
    var phase: GitPushPhase = .idle
    var phaseCwd: String?
    /// The branch picked by hand; nil follows the focused session. Cleared when the card closes.
    var picked: GitTarget?
    /// The picker replaces the tool's content while this is true.
    var pickerOpen = false
    /// Index into the chosen repository's rows as the filter leaves them.
    var pickerCursor = 0
    /// The repository whose branches the picker lists (its main folder).
    var pickerRepo: String?
    /// The repository dropdown under the picker's pill.
    var repoMenuOpen = false
    var repoMenuCursor = 0
    /// The picker's filter, by branch name; its field has the keys while focused.
    var filter = ""
    var filterFocused = false
    /// The last listing: one group per repository, in the Sessions tab's order.
    var repos: [GitRepoGroup] = []
    /// Session cwd -> its worktree's top level, from the last listing.
    var rootByCwd: [String: String] = [:]
    /// A listing is running.
    var listing = false
}

extension AppState {

    // MARK: Storage

    /// Kept outside AppState's stored properties (as FilesBrowser keeps the Markdown switch);
    /// every write goes through `updateGit`, which tells SwiftUI.
    private static var gitStore = GitPanelState()
    private static var gitPollTask: Task<Void, Never>?
    private static var gitHoldTask: Task<Void, Never>?

    var gitPanel: GitPanelState { Self.gitStore }

    private func updateGit(_ change: (inout GitPanelState) -> Void) {
        var next = Self.gitStore
        change(&next)
        guard next != Self.gitStore else { return }
        objectWillChange.send()
        Self.gitStore = next
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

    /// The push phase of the target.
    var gitPhase: GitPushPhase {
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

    /// The file list is hidden (⌘B). One preference with the Files tree: the left column of
    /// both tools. Only while a diff shows, as Files needs an open file.
    var gitListCollapsed: Bool {
        extraPrefs.filesTreeHidden && gitSelectedFile != nil
    }

    /// ⌘B or the pill. Does nothing with no file to show.
    func toggleGitList() {
        guard gitSelectedFile != nil else { return }
        setFilesTreeHidden(!gitListCollapsed)
    }

    func setGitRowCursor(key: String) {
        if let index = gitRows.firstIndex(where: { $0.key == key }) { rowCursor = index }
    }

    /// Push or Publish is possible: a branch, a remote, and something to send (a branch
    /// with no upstream can always be published).
    var gitCanPush: Bool {
        guard let snap = focusedGit, snap.isRepo, snap.branch != nil, snap.remote != nil else { return false }
        return snap.upstream == nil || snap.ahead > 0
    }

    /// "Publish" for a branch with no upstream, else "Push".
    var gitPushVerb: String {
        guard let snap = focusedGit, snap.remote != nil, snap.branch != nil else { return "Push" }
        return snap.upstream == nil ? "Publish" : "Push"
    }

    /// "3 commits to push", "not published yet", "up to date with origin", "no remote"; for a
    /// branch checked out nowhere "not checked out · 4 commits ahead of main".
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
            let push = Self.commits(snap.ahead) + " to push"
            return snap.behind > 0 ? push + Theme.Glyphs.separator + "\(snap.behind) behind" : push
        }
        if snap.behind > 0 { return Self.commits(snap.behind) + " behind " + remote }
        return "up to date with " + remote
    }

    /// "Push 3 commits to origin/seadevil?" or "Publish seadevil to origin?".
    var gitConfirmText: String {
        guard let snap = focusedGit, let branch = snap.branch, let remote = snap.remote else { return "" }
        if let upstream = snap.upstream {
            return "Push " + Self.commits(snap.ahead) + " to " + upstream + "?"
        }
        return "Publish " + branch + " to " + remote + "?"
    }

    /// Where a running push goes, for "Pushing to origin/seadevil…".
    var gitPushTarget: String {
        guard let snap = focusedGit else { return "" }
        return snap.upstream ?? snap.remote ?? ""
    }

    nonisolated static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    /// "now", "12m ago", "2h ago", "3d ago".
    static func gitAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 86_400 { return Format.ago(date, now: now) }
        return "\(Int(seconds / 86_400))d ago"
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
        refreshGit()
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
            $0.pickerOpen = false
            $0.repoMenuOpen = false
            $0.filter = ""
            $0.filterFocused = false
        }
    }

    /// A hook's tree report arrived (a Bash command ran): the worktree may have changed.
    func gitTreeReported(cwd: String) {
        guard isCardOpen, selectedTab == .git, let target = gitCwd else { return }
        guard cwd == target || gitPanel.rootByCwd[cwd] == target else { return }
        refreshGit()
    }

    private func startGitPolling() {
        guard Self.gitPollTask == nil else { return }
        Self.gitPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Theme.Timing.gitRefreshInterval))
                // Stops once the card closes or another tool is picked; a request over the
                // tool only pauses it.
                guard let self, self.isCardOpen, self.selectedTab == .git else { break }
                if self.isShowingTool(.git) { self.refreshGit(poll: true) }
            }
            AppState.gitPollTask = nil
        }
    }

    /// Reads the target in the background. A poll keeps a push error on screen; any other
    /// refresh clears it.
    func refreshGit(poll: Bool = false) {
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
            case .folder(let cwd): snapshot = GitRunner.read(cwd: cwd)
            case .branch(let repo, let name): snapshot = GitRunner.readBranch(repo: repo, name: name, key: key)
            }
            await self?.applyGit(snapshot)
        }
    }

    private func applyGit(_ snapshot: GitSnapshot) {
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
        // Nothing left to push while the confirm was up (pushed from the terminal): drop it.
        if gitPhase == .confirming, !gitCanPush { updateGit { $0.phase = .idle } }
    }

    // MARK: Keys

    /// Esc in the Git tool, one layer at a time: the repository dropdown, then the picker's
    /// filter, then the picker, then the push confirm. False: nothing left, the card closes.
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
        return closeGitPicker() || cancelGitConfirm()
    }

    /// What esc does next, for the footer: "close" the dropdown, "clear" the filter, "back"
    /// out of the picker; nil when it closes the card.
    var gitEscapeLabel: String? {
        guard gitPanel.pickerOpen else { return nil }
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
            pressGitPush()
            return true
        case .primary:
            // The selected file's diff already shows; ⏎ only confirms a push.
            if gitPhase == .confirming { runGitPush() }
            return true
        case .toggleTree:       // ⌘B
            toggleGitList()
            return true
        case .up, .down:
            // Selecting shows that file's diff at once. The list comes back first, as the
            // Files tree does.
            let count = gitRows.count
            guard count > 0 else { return false }
            if gitListCollapsed { setFilesTreeHidden(false) }
            rowCursor = max(0, min(count - 1, rowCursor + (key == .up ? -1 : 1)))
            return true
        default:
            return nil
        }
    }

    // MARK: Branch picker

    /// The repository the picker lists: the one chosen in the dropdown, else the first.
    var gitPickerGroup: GitRepoGroup? {
        let repos = gitPanel.repos
        return repos.first { $0.id == gitPanel.pickerRepo } ?? repos.first
    }

    /// Past `gitPickerFilterMin` branches the filter field shows above the rows.
    var gitPickerShowsFilter: Bool {
        (gitPickerGroup?.branches.count ?? 0) > Theme.Limits.gitPickerFilterMin
    }

    /// The chosen repository's branches the filter lets through; `pickerCursor` indexes them.
    var gitPickerRows: [GitBranch] {
        let branches = gitPickerGroup?.branches ?? []
        let query = gitPanel.filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The branch the tool shows is this row: its checkout is the target, or it is the
    /// branch page's branch.
    func gitBranchIsCurrent(_ branch: GitBranch, repo: String) -> Bool {
        switch gitTarget {
        case .branch(let targetRepo, let name):
            return targetRepo == repo && name == branch.name
        case .folder:
            guard let path = branch.path else { return false }
            return path == (focusedGit?.root ?? gitCwd)
        case nil:
            return false
        }
    }

    /// The live sessions whose folder is inside `path`'s worktree.
    func gitSessions(inWorktree path: String) -> [Session] {
        sessions.filter { !$0.cwd.isEmpty && (gitPanel.rootByCwd[$0.cwd] ?? $0.cwd) == path }
    }

    /// W or the pill: the picker replaces the tool's content, on the target's repository,
    /// the cursor on the target's row.
    func openGitPicker() {
        guard readsLocalFiles else { return }
        cancelGitConfirm()
        updateGit {
            $0.pickerOpen = true
            $0.repoMenuOpen = false
            $0.filter = ""
            $0.filterFocused = false
        }
        placeGitPickerOnTarget()
        refreshGitWorktrees()
    }

    /// The picker's repository and cursor follow the target.
    private func placeGitPickerOnTarget() {
        let repos = gitPanel.repos
        var repoId: String?
        switch gitTarget {
        case .branch(let repo, _): repoId = repo
        case .folder:
            let root = focusedGit?.root ?? gitCwd
            repoId = repos.first { $0.branches.contains { $0.path == root } }?.id
        case nil: break
        }
        updateGit { $0.pickerRepo = repoId ?? $0.pickerRepo ?? repos.first?.id }
        let repo = gitPickerGroup?.id ?? ""
        let index = gitPickerRows.firstIndex { gitBranchIsCurrent($0, repo: repo) } ?? 0
        updateGit { $0.pickerCursor = index }
    }

    /// Esc, W again, or the pill while the picker shows. False when it was not open.
    @discardableResult
    func closeGitPicker() -> Bool {
        guard gitPanel.pickerOpen else { return false }
        updateGit {
            $0.pickerOpen = false
            $0.repoMenuOpen = false
            $0.filter = ""
            $0.filterFocused = false
        }
        return true
    }

    func toggleGitPicker() {
        if !closeGitPicker() { openGitPicker() }
    }

    /// R or the pill: the repository dropdown, the cursor on the chosen one. Only with more
    /// than one repository; with one the pill is static.
    func openGitRepoMenu() {
        let repos = gitPanel.repos
        guard repos.count > 1 else { return }
        let current = repos.firstIndex { $0.id == gitPickerGroup?.id } ?? 0
        updateGit {
            $0.repoMenuOpen.toggle()
            $0.repoMenuCursor = current
            $0.filterFocused = false
        }
    }

    func closeGitRepoMenu() {
        updateGit { $0.repoMenuOpen = false }
    }

    /// ⏎ or a click in the dropdown: that repository's branches, the filter cleared.
    func chooseGitRepo(_ id: String) {
        updateGit {
            $0.pickerRepo = id
            $0.repoMenuOpen = false
            $0.filter = ""
            $0.pickerCursor = 0
        }
        let rows = gitPickerRows
        if let index = rows.firstIndex(where: { gitBranchIsCurrent($0, repo: id) }) {
            updateGit { $0.pickerCursor = index }
        }
    }

    /// Typing in the filter field: the rows narrow and the cursor goes to the first match.
    func setGitFilter(_ text: String) {
        updateGit {
            $0.filter = text
            $0.pickerCursor = 0
        }
    }

    func setGitFilterFocused(_ focused: Bool) {
        updateGit { $0.filterFocused = focused }
    }

    /// A click on a row: the cursor goes there first, then it is picked.
    func pickGitBranch(_ branch: GitBranch) {
        guard let repo = gitPickerGroup else { return }
        let target: GitTarget = branch.path.map { .folder($0) } ?? .branch(repo: repo.id, name: branch.name)
        if gitPanel.picked != target { cancelGitConfirm() }
        updateGit {
            $0.picked = target
            $0.pickerOpen = false
            $0.repoMenuOpen = false
            $0.filter = ""
            $0.filterFocused = false
        }
        rowCursor = 0
        debugLog("git target picked: \(target.key)")
        refreshGit()
    }

    /// Lists every repository a session runs in, with its local branches, in the background.
    func refreshGitWorktrees() {
        guard readsLocalFiles, !gitPanel.listing else { return }
        var cwds: [String] = []
        for session in orderedSessions where !session.cwd.isEmpty && !cwds.contains(session.cwd) {
            cwds.append(session.cwd)
        }
        switch gitPanel.picked {
        case .folder(let path)?: if !cwds.contains(path) { cwds.append(path) }
        case .branch(let repo, _)?: if !cwds.contains(repo) { cwds.append(repo) }
        case nil: break
        }
        updateGit { $0.listing = true }
        Task.detached(priority: .userInitiated) { [weak self] in
            let listing = GitRunner.listBranches(cwds: cwds)
            await self?.applyGitWorktrees(listing.repos, rootByCwd: listing.rootByCwd)
        }
    }

    private func applyGitWorktrees(_ repos: [GitRepoGroup], rootByCwd: [String: String]) {
        let before = gitPickerRows
        let cursorName = before.indices.contains(gitPanel.pickerCursor) ? before[gitPanel.pickerCursor].name : nil
        let hadRepo = gitPanel.pickerRepo.map { id in gitPanel.repos.contains { $0.id == id } } ?? false
        updateGit {
            $0.listing = false
            $0.repos = repos
            $0.rootByCwd.merge(rootByCwd) { _, new in new }
        }
        if hadRepo, let id = gitPanel.pickerRepo, repos.contains(where: { $0.id == id }) {
            // A refresh while the picker shows: the cursor stays on its branch.
            let rows = gitPickerRows
            if let cursorName, let index = rows.firstIndex(where: { $0.name == cursorName }) {
                updateGit { $0.pickerCursor = index }
            } else {
                updateGit { $0.pickerCursor = min($0.pickerCursor, max(0, rows.count - 1)) }
            }
        } else {
            placeGitPickerOnTarget()
        }
        debugLog("git branches: " + repos.map { repo in
            "\(repo.name)[" + repo.branches.map { branch in
                let place: String
                switch branch.place {
                case .main: place = "main"
                case .worktree(let path): place = URL(fileURLWithPath: path).lastPathComponent
                case .nowhere: place = "-"
                }
                return "\(branch.name)@\(place) u=\(branch.uncommitted.map(String.init) ?? "-") a=\(branch.ahead.map(String.init) ?? "-")"
            }.joined(separator: ", ") + "]"
        }.joined(separator: " "))
    }

    // MARK: Push

    /// P or the pill: show the confirm line. Never pushes by itself.
    func pressGitPush() {
        guard let cwd = gitCwd, gitCanPush else { return }
        switch gitPhase {
        case .confirming, .pushing:
            return
        case .idle, .pushed, .failed:
            Self.gitHoldTask?.cancel()
            updateGit {
                $0.phase = .confirming
                $0.phaseCwd = cwd
            }
        }
    }

    /// The pill while the confirm shows: the same as ⏎.
    func pressGitPill() {
        if gitPhase == .confirming { runGitPush() } else { pressGitPush() }
    }

    /// Esc while the confirm shows. False when there was nothing to cancel.
    @discardableResult
    func cancelGitConfirm() -> Bool {
        guard gitPhase == .confirming else { return false }
        updateGit { $0.phase = .idle }
        return true
    }

    /// ⏎ on the confirm: `git push`, or `git push -u <remote> <branch>` for an unpublished
    /// branch. A branch checked out nowhere names itself: `git push <remote> <branch>`.
    func runGitPush() {
        guard gitPhase == .confirming, gitCanPush, let cwd = gitCwd, let snap = focusedGit,
              let branch = snap.branch, let remote = snap.remote else { return }
        let publishing = snap.upstream == nil
        let args: [String]
        if publishing {
            args = ["push", "-u", remote, branch]
        } else {
            args = snap.checkedOut ? ["push"] : ["push", remote, branch]
        }
        let count = snap.unpushed
        updateGit { $0.phase = .pushing }
        debugLog("git push in \(snap.root): \(args.joined(separator: " "))")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = GitRunner.run(args, cwd: snap.root, timeout: Theme.Timing.gitPushTimeout)
            let message: String
            if result.status == 0 {
                message = publishing
                    ? "Published " + branch + " to " + remote
                    : "Pushed " + AppState.commits(count)
            } else {
                message = GitRunner.errorLine(result, remote: remote)
            }
            await self?.finishGitPush(ok: result.status == 0, message: message, cwd: cwd)
        }
    }

    private func finishGitPush(ok: Bool, message: String, cwd: String) {
        debugLog("git push \(ok ? "ok" : "failed"): \(message)")
        updateGit {
            $0.phase = ok ? .pushed(message) : .failed(message)
            $0.phaseCwd = cwd
        }
        guard ok else {
            // The counts may have moved (a partial push); the error stays.
            refreshGit(poll: true)
            return
        }
        Self.gitHoldTask?.cancel()
        Self.gitHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Timing.gitPushedHold))
            guard let self, !Task.isCancelled else { return }
            if self.gitPanel.phaseCwd == cwd, case .pushed = self.gitPanel.phase {
                self.updateGit { $0.phase = .idle }
            }
            self.refreshGit()
        }
    }
}

// MARK: - Running git

/// `/usr/bin/git -C <dir>`, synchronously; call it off the main thread. Output goes to
/// temporary files rather than pipes, so a large diff never fills a pipe and an ssh helper
/// that outlives git (ControlPersist) never holds the read open.
enum GitRunner {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var timedOut = false
    }

    static func run(_ args: [String], cwd: String, timeout: Double = Theme.Timing.gitReadTimeout) -> Result {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("notchcode-git-" + UUID().uuidString)
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return Result(status: -1, out: "", err: "could not run git")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "-c", "core.quotePath=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // No prompt can be answered from a notch: fail instead of waiting on one.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return Result(status: -1, out: "", err: "could not run git")
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        try? outHandle.close()
        try? errHandle.close()

        func text(_ url: URL) -> String {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: timedOut ? -1 : status, out: text(outURL), err: text(errURL), timedOut: timedOut)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Everything the tool shows about `cwd`'s worktree.
    static func read(cwd: String) -> GitSnapshot {
        let top = run(["rev-parse", "--show-toplevel"], cwd: cwd)
        let root = trimmed(top.out)
        guard top.status == 0, !root.isEmpty else { return GitSnapshot(cwd: cwd, isRepo: false) }
        var snap = GitSnapshot(cwd: cwd, isRepo: true, root: root)
        let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: root)
        if common.status == 0 { snap.repoName = repoName(commonDir: trimmed(common.out)) }

        let head = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: root)
        if head.status == 0 {
            let name = trimmed(head.out)
            snap.branch = name == "HEAD" || name.isEmpty ? nil : name
        } else {
            // No commit yet: the branch still has a name.
            let unborn = run(["symbolic-ref", "--short", "HEAD"], cwd: root)
            if unborn.status == 0, !trimmed(unborn.out).isEmpty { snap.branch = trimmed(unborn.out) }
        }

        let remotes = lines(run(["remote"], cwd: root).out)
        let upstream = run(["rev-parse", "--abbrev-ref", "@{u}"], cwd: root)
        if upstream.status == 0, !trimmed(upstream.out).isEmpty {
            snap.upstream = trimmed(upstream.out)
        }
        if let up = snap.upstream, let owner = remotes.first(where: { up.hasPrefix($0 + "/") }) {
            snap.remote = owner
        } else {
            snap.remote = remotes.contains("origin") ? "origin" : remotes.first
        }

        if snap.upstream != nil {
            // "<behind>\t<ahead>": left is the upstream, right is HEAD.
            let counts = trimmed(run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], cwd: root).out)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if counts.count == 2 {
                snap.behind = Int(counts[0]) ?? 0
                snap.ahead = Int(counts[1]) ?? 0
            }
            snap.unpushed = snap.ahead
        } else if snap.branch != nil {
            let args = remotes.isEmpty
                ? ["rev-list", "--count", "HEAD"]
                : ["rev-list", "--count", "HEAD", "--not", "--remotes"]
            snap.unpushed = Int(trimmed(run(args, cwd: root).out)) ?? 0
        }

        // Uncommitted files: the same commands the hook's tree report runs.
        let status = run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: root)
        let entries = UnifiedDiff.status(status.out.split(separator: "\n").map(String.init))
        var diffText = run(["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-renames",
                            "--src-prefix=a/", "--dst-prefix=b/"], cwd: root).out
        for entry in entries.filter({ $0.code == "??" }).prefix(Theme.Limits.gitUntrackedDiffs) {
            // Exit 1 means "they differ", which is the point.
            let new = run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
                           "--", "/dev/null", entry.path], cwd: root)
            if !diffText.isEmpty, !diffText.hasSuffix("\n") { diffText += "\n" }
            diffText += new.out
        }
        var byPath: [String: FileDiff] = [:]
        for diff in UnifiedDiff.parse(diffText) where byPath[diff.path] == nil { byPath[diff.path] = diff }
        var seen = Set<String>()
        for entry in entries where !seen.contains(entry.path) {
            seen.insert(entry.path)
            let diff = byPath[entry.path]
            var file = FileChange(path: entry.path, added: diff?.added ?? 0, removed: diff?.removed ?? 0,
                                  kind: kind(statusCode: entry.code))
            file.patch = diff?.lines ?? []
            file.patchTruncated = diff?.truncated ?? false
            file.snippet = Array(file.patch.prefix(DiffBuilder.snippetLimit))
            snap.files.append(file)
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            try? handle.close()
            if let data { snap.lineCounts[file.path] = lineCount(data) }
        }

        let log = run(["log", "-\(Theme.Limits.gitRecentCommits)", "--format=%h%x1f%s%x1f%ct"], cwd: root)
        if log.status == 0 {
            for (index, line) in lines(log.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                snap.commits.append(GitCommit(
                    sha: parts[0],
                    subject: parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    pushed: index >= snap.unpushed
                ))
            }
        }
        return snap
    }

    /// "notchcode" for "/…/notchcode/.git", "tools" for a bare "/…/tools.git".
    private static func repoName(commonDir: String) -> String? {
        guard !commonDir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: commonDir)
        let last = url.lastPathComponent
        if last == ".git" { return url.deletingLastPathComponent().lastPathComponent }
        if last.hasSuffix(".git") { return String(last.dropLast(4)) }
        return last
    }

    /// "new" for an untracked or added file, "deleted", else "edit"; the diff pane's badge
    /// reads A, D or M from it.
    private static func kind(statusCode code: String) -> String {
        if code == "??" || code.contains("A") { return "new" }
        if code.contains("D") { return "deleted" }
        return "edit"
    }

    /// Lines in a file's bytes: its newlines, plus one for a last line without one.
    private static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    /// "main" when the repository has it, else "master", else nil.
    private static func defaultBranch(root: String) -> String? {
        for name in ["main", "master"] where run(["show-ref", "--verify", "--quiet", "refs/heads/" + name], cwd: root).status == 0 {
            return name
        }
        return nil
    }

    /// A branch checked out nowhere, read from the repository's main folder: its changes
    /// against its upstream (else the default branch) with `git diff base...branch`, the
    /// commits `base..branch`, and what a push would send. Nothing is checked out.
    static func readBranch(repo: String, name: String, key: String) -> GitSnapshot {
        let ref = "refs/heads/" + name
        guard run(["show-ref", "--verify", "--quiet", ref], cwd: repo).status == 0 else {
            return GitSnapshot(cwd: key, isRepo: false)
        }
        var snap = GitSnapshot(cwd: key, isRepo: true, root: repo)
        snap.checkedOut = false
        snap.branch = name
        let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repo)
        if common.status == 0 { snap.repoName = repoName(commonDir: trimmed(common.out)) }

        let remotes = lines(run(["remote"], cwd: repo).out)
        let upstream = run(["rev-parse", "--abbrev-ref", name + "@{u}"], cwd: repo)
        if upstream.status == 0, !trimmed(upstream.out).isEmpty { snap.upstream = trimmed(upstream.out) }
        if let up = snap.upstream, let owner = remotes.first(where: { up.hasPrefix($0 + "/") }) {
            snap.remote = owner
        } else {
            snap.remote = remotes.contains("origin") ? "origin" : remotes.first
        }

        if let up = snap.upstream {
            let counts = trimmed(run(["rev-list", "--left-right", "--count", up + "..." + ref], cwd: repo).out)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if counts.count == 2 {
                snap.behind = Int(counts[0]) ?? 0
                snap.ahead = Int(counts[1]) ?? 0
            }
            snap.unpushed = snap.ahead
            snap.base = up
        } else {
            let args = remotes.isEmpty
                ? ["rev-list", "--count", ref]
                : ["rev-list", "--count", ref, "--not", "--remotes"]
            snap.unpushed = Int(trimmed(run(args, cwd: repo).out)) ?? 0
            if let main = defaultBranch(root: repo), main != name { snap.base = main }
        }

        guard let base = snap.base else { return snap }
        snap.baseAhead = Int(trimmed(run(["rev-list", "--count", base + ".." + ref], cwd: repo).out)) ?? 0

        // Changes vs the base: the list and counts from --numstat, the kinds from
        // --name-status, the lines from -p (the hook's flags, so one parser reads them).
        let range = base + "..." + ref
        let numstat = run(["diff", "--numstat", "--no-renames", range], cwd: repo)
        let names = run(["diff", "--name-status", "--no-renames", range], cwd: repo)
        let patch = run(["diff", "-p", "--no-color", "--no-ext-diff", "--no-renames",
                         "--src-prefix=a/", "--dst-prefix=b/", range], cwd: repo)
        var kinds: [String: String] = [:]
        for line in lines(names.out) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            kinds[parts[1]] = kind(statusCode: parts[0])
        }
        var byPath: [String: FileDiff] = [:]
        for diff in UnifiedDiff.parse(patch.out) where byPath[diff.path] == nil { byPath[diff.path] = diff }
        for line in lines(numstat.out) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let path = parts[2]
            let diff = byPath[path]
            var file = FileChange(path: path, added: Int(parts[0]) ?? diff?.added ?? 0,
                                  removed: Int(parts[1]) ?? diff?.removed ?? 0, kind: kinds[path] ?? "edit")
            file.patch = diff?.lines ?? []
            file.patchTruncated = diff?.truncated ?? false
            file.snippet = Array(file.patch.prefix(DiffBuilder.snippetLimit))
            snap.files.append(file)
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            let blob = run(["cat-file", "blob", ref + ":" + file.path], cwd: repo)
            if blob.status == 0 { snap.lineCounts[file.path] = lineCount(Data(blob.out.utf8)) }
        }

        let log = run(["log", "-\(Theme.Limits.gitRecentCommits)", "--format=%h%x1f%s%x1f%ct", base + ".." + ref], cwd: repo)
        if log.status == 0 {
            for (index, line) in lines(log.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                snap.commits.append(GitCommit(
                    sha: parts[0],
                    subject: parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    pushed: index >= snap.unpushed
                ))
            }
        }
        return snap
    }

    /// Every repository the folders belong to, with its local branches: the newest
    /// `gitPickerBranches` by last commit (`for-each-ref --sort=-committerdate refs/heads`)
    /// and every checked-out one besides, each placed by `git worktree list --porcelain`
    /// (main checkout, a worktree, or nowhere), with its uncommitted files (checkouts only)
    /// and the commits it is ahead of its upstream, or of the default branch without one.
    /// Repositories in the order the folders come, each listed once.
    static func listBranches(cwds: [String]) -> (repos: [GitRepoGroup], rootByCwd: [String: String]) {
        var repos: [GitRepoGroup] = []
        var rootByCwd: [String: String] = [:]
        var seenRoots = Set<String>()
        for cwd in cwds {
            let top = run(["rev-parse", "--show-toplevel"], cwd: cwd)
            let root = trimmed(top.out)
            guard top.status == 0, !root.isEmpty else { continue }
            rootByCwd[cwd] = root
            if seenRoots.contains(root) { continue }
            let list = run(["worktree", "list", "--porcelain"], cwd: root)
            guard list.status == 0 else { continue }
            let entries = worktreeEntries(list.out)
            guard let main = entries.first else { continue }
            for entry in entries { seenRoots.insert(entry.path) }
            if repos.contains(where: { $0.id == main.path }) { continue }
            let name: String
            if main.bare {
                let last = URL(fileURLWithPath: main.path).lastPathComponent
                name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
            } else {
                name = URL(fileURLWithPath: main.path).lastPathComponent
            }

            // Branch -> the folder it is checked out in; the first entry is the main one.
            var checkouts: [String: GitBranch.Place] = [:]
            for (index, entry) in entries.enumerated() where !entry.bare {
                guard let branch = entry.branch, FileManager.default.fileExists(atPath: entry.path) else { continue }
                checkouts[branch] = index == 0 ? .main(entry.path) : .worktree(entry.path)
            }
            let defaultName = defaultBranch(root: root)

            let refs = run(["for-each-ref", "--sort=-committerdate",
                            "--format=%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)", "refs/heads"], cwd: root)
            var branches: [GitBranch] = []
            for (index, line) in lines(refs.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                let place = checkouts[parts[0]] ?? .nowhere
                if index >= Theme.Limits.gitPickerBranches, place == .nowhere { continue }
                var branch = GitBranch(
                    name: parts[0],
                    upstream: parts[1].isEmpty ? nil : parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    place: place
                )
                if let path = branch.path {
                    let status = run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: path)
                    branch.uncommitted = status.status == 0 ? lines(status.out).count : nil
                }
                let ref = "refs/heads/" + branch.name
                let base: String?
                if let upstream = branch.upstream {
                    base = upstream
                } else if let defaultName, defaultName != branch.name {
                    base = "refs/heads/" + defaultName
                } else {
                    base = nil
                }
                if let base {
                    let count = run(["rev-list", "--count", base + ".." + ref], cwd: root)
                    branch.ahead = count.status == 0 ? Int(trimmed(count.out)) : nil
                }
                branches.append(branch)
            }
            if !branches.isEmpty {
                repos.append(GitRepoGroup(id: main.path, name: name, defaultBranch: defaultName, branches: branches))
            }
        }
        return (repos, rootByCwd)
    }

    /// The blocks of `git worktree list --porcelain`: "worktree <path>", then "branch
    /// refs/heads/<name>", "detached" or "bare", separated by a blank line.
    private static func worktreeEntries(_ text: String) -> [(path: String, branch: String?, bare: Bool)] {
        var entries: [(path: String, branch: String?, bare: Bool)] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var bare = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                }
                if line == "bare" { bare = true }
            }
            if let path { entries.append((path, branch, bare)) }
        }
        return entries
    }

    /// The first useful line of a failed push, for the header. Credential failures say so
    /// and point at the terminal, where a prompt can be answered.
    static func errorLine(_ result: Result, remote: String) -> String {
        if result.timedOut { return "git push took too long" + Theme.Glyphs.separator + "push from the terminal" }
        let all = lines(result.err).map(trimmed)
        let credentials = ["could not read Username", "terminal prompts disabled", "Permission denied",
                           "Authentication failed", "Host key verification failed", "could not read Password"]
        if all.contains(where: { line in credentials.contains { line.contains($0) } }) {
            return "No credentials for " + remote + " here" + Theme.Glyphs.separator + "push from the terminal"
        }
        let marked = all.first { line in
            ["fatal:", "error:", "! [rejected]", "! [remote rejected]", "remote: error"].contains { line.contains($0) }
        }
        let line = marked ?? all.first { !$0.hasPrefix("hint:") && !$0.hasPrefix("To ") } ?? ""
        var text = line
        for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        return text.isEmpty ? "git push failed" : text
    }
}
