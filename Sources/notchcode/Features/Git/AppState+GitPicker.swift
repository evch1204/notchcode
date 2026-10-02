// AppState+GitPicker.swift
// The Git tool's branch picker (W): the repository it lists, its filtered rows, opening
// and closing it, moving its cursor, picking a branch as the target, and the branch
// listing that fills it.

import SwiftUI

extension AppState {

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
        if gitDraft.focus != nil { setGitDraftFocus(nil) }
        updateGit { $0.resetPicker(open: true) }
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
        updateGit { $0.resetPicker() }
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
        updateGit {
            $0.picked = target
            $0.resetPicker()
            $0.dropConfirms()
        }
        rowCursor = 0
        debugLog("git target picked: \(target.key)")
        refreshGit(thenFetch: true)
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
            let listing = await GitRunner.listBranches(cwds: cwds)
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
}
