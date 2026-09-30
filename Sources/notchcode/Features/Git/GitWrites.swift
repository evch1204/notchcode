// GitWrites.swift
// Everything the Git tool writes, all through one phase per target so two writes never run
// at once: the sync pill (publish, pull, push, fetch), the quiet fetch when the tool opens,
// the commit of the checked files from the form, and the undo of the newest unpushed commit.
// Each runs `/usr/bin/git` off the main thread and only from an explicit press, except the
// quiet fetch, which touches no phase and no pill.

import SwiftUI

extension AppState {

    // MARK: Draft

    /// The target's commit draft, or a fresh one.
    var gitDraft: GitDraft {
        gitCwd.flatMap { gitPanel.drafts[$0] } ?? GitDraft()
    }

    func updateGitDraft(_ change: (inout GitDraft) -> Void) {
        guard let key = gitCwd else { return }
        updateGit {
            var draft = $0.drafts[key] ?? GitDraft()
            change(&draft)
            $0.drafts[key] = draft
        }
    }

    /// The files going into the commit, in list order: every file but the unchecked ones.
    var gitCheckedFiles: [FileChange] {
        let unchecked = gitDraft.unchecked
        return (focusedGit?.files ?? []).filter { !unchecked.contains($0.path) }
    }

    var gitAllChecked: Bool {
        gitCheckedFiles.count == (focusedGit?.files.count ?? 0)
    }

    var gitNoneChecked: Bool {
        gitCheckedFiles.isEmpty
    }

    func toggleGitFile(path: String) {
        updateGitDraft {
            if $0.unchecked.contains(path) { $0.unchecked.remove(path) } else { $0.unchecked.insert(path) }
        }
    }

    /// The header's box: all checked → none, else all.
    func toggleAllGitFiles() {
        let paths = Set((focusedGit?.files ?? []).map(\.path))
        let all = gitAllChecked
        updateGitDraft { $0.unchecked = all ? paths : [] }
    }

    func setGitComposing(_ composing: Bool) {
        updateGitDraft {
            $0.composing = composing
            if !composing { $0.focus = nil }
        }
    }

    func setGitDraftFocus(_ focus: GitDraftFocus?) {
        updateGitDraft { $0.focus = focus }
    }

    func setGitSummary(_ text: String) {
        updateGitDraft { $0.summary = text }
    }

    func setGitDescription(_ text: String) {
        updateGitDraft { $0.description = text }
    }

    /// C or the Commit pill: the form in the right pane, the summary focused. Only for a
    /// checkout with changed files; C again while it shows does nothing.
    func openGitCommitForm() {
        guard let snap = focusedGit, snap.isRepo, snap.checkedOut, !snap.files.isEmpty,
              !gitDraft.composing else { return }
        cancelGitConfirm()
        updateGitDraft {
            $0.composing = true
            $0.focus = .summary
        }
    }

    /// Esc or Cancel: the diff comes back; the text and the checks stay for next time.
    /// False when the form was not up.
    @discardableResult
    func cancelGitCommitForm() -> Bool {
        guard gitDraft.composing else { return false }
        setGitComposing(false)
        return true
    }

    /// A click on a file row: its diff shows at once, over the form if it was up.
    func selectGitRow(key: String) {
        setGitRowCursor(key: key)
        if gitDraft.composing { setGitComposing(false) }
    }

    /// With one file checked, GitHub Desktop's prefill: "Create x", "Delete x", "Update x".
    private var gitSummaryPrefill: String? {
        let checked = gitCheckedFiles
        guard checked.count == 1, let file = checked.first else { return nil }
        let name = Format.fileName(file.path)
        switch file.kind {
        case "new": return "Create " + name
        case "deleted": return "Delete " + name
        default: return "Update " + name
        }
    }

    /// The summary field's prompt: the one-file prefill, else "Summary (required)".
    var gitSummaryPlaceholder: String {
        gitSummaryPrefill ?? "Summary (required)"
    }

    /// The summary a commit uses: what was typed, else the one-file prefill.
    private var gitCommitSummary: String {
        let typed = gitDraft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? gitSummaryPrefill ?? "" : typed
    }

    /// A checkout, at least one checked file, a summary, and no write running or holding.
    var gitCanCommit: Bool {
        guard let snap = focusedGit, snap.isRepo, snap.checkedOut else { return false }
        switch gitPhase {
        case .idle, .failed: break
        case .confirming, .running, .done: return false
        }
        return !gitCheckedFiles.isEmpty && !gitCommitSummary.isEmpty
    }

    /// "Commit 3 files to main".
    var gitCommitButtonTitle: String {
        let files = "Commit " + Format.files(gitCheckedFiles.count)
        guard let branch = focusedGit?.branch else { return files }
        return files + " to " + branch
    }

    // MARK: Sync

    /// P or the pill: a fetch runs at once; publish, push and pull ask first in the right
    /// pane. Nothing while a write runs or a sync's result holds: re-arming then would ask
    /// again for the commits just sent. A fetch or pull does nothing while the quiet fetch runs
    /// on the same root (two fetches can fail on git's ref locks); the pill stays enabled and
    /// works again once it lands. The quiet fetch, in turn, waits for an idle phase.
    func pressGitSync() {
        guard let cwd = gitCwd, gitCanSync, let op = gitSyncOp, let snap = focusedGit else { return }
        if case .confirming = gitPhase { return }
        if op == .fetch || op == .pull, gitPanel.fetching.contains(snap.root) { return }
        if op == .fetch {
            runGitFetch()
            return
        }
        // The confirm takes the pane; the form's text stays for later.
        if gitDraft.composing { setGitComposing(false) }
        updateGit {
            $0.phase = .confirming(op)
            $0.phaseCwd = cwd
        }
    }

    /// The pill while the confirm shows: the same as ⏎.
    func pressGitPill() {
        if case .confirming = gitPhase { runGitSync() } else { pressGitSync() }
    }

    /// Esc while the confirm shows. False when there was nothing to cancel.
    @discardableResult
    func cancelGitConfirm() -> Bool {
        guard case .confirming = gitPhase else { return false }
        updateGit { $0.phase = .idle }
        return true
    }

    /// ⏎ on the confirm. Push: `git push -- <remote> <src>:refs/heads/<upstream branch>`;
    /// publish: `git push -u -- <remote> refs/heads/<b>:refs/heads/<b>`. Full refs on both
    /// sides: a plain `git push` follows push.default and pushRemote (it can go elsewhere, or
    /// push several branches), and a bare name is ambiguous with a tag. Pull: `git pull
    /// --ff-only --no-rebase -- <remote> <upstream branch>`, a checkout only: it never merges
    /// or rebases, so a diverged branch is sent to the terminal.
    func runGitSync() {
        guard case .confirming(let op) = gitPhase, gitCanSync, op == gitSyncOp, let cwd = gitCwd,
              let snap = focusedGit, let branch = snap.branch, let remote = snap.remote else { return }
        let local = "refs/heads/" + branch
        let upstreamBranch = snap.upstreamBranch
            ?? snap.upstream.map { String($0.dropFirst(remote.count + 1)) }
            ?? branch
        let args: [String]
        let message: String
        switch op {
        case .publish:
            args = ["push", "-u", "--", remote, local + ":" + local]
            message = "Published " + branch + " to " + remote
        case .push:
            let source = snap.checkedOut ? "HEAD" : local
            args = ["push", "--", remote, source + ":refs/heads/" + upstreamBranch]
            message = "Pushed " + AppState.commits(snap.unpushed)
        case .pull:
            guard snap.checkedOut else { return }
            args = ["pull", "--ff-only", "--no-rebase", "--", remote, upstreamBranch]
            message = "Pulled " + AppState.commits(snap.behind)
        case .fetch, .commit, .undo:
            return
        }
        updateGit { $0.phase = .running(op) }
        debugLog("git \(op.command) in \(snap.root): \(args.joined(separator: " "))")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await GitRunner.run(args, cwd: snap.root, timeout: Theme.Timing.gitSyncTimeout)
            let ok = result.status == 0
            await self?.finishGitOp(op: op, ok: ok, message: ok ? message : GitRunner.errorLine(result, remote: remote, op: op), cwd: cwd)
        }
    }

    /// P or the pill offering Fetch: `git fetch --prune -- <remote>` at once, no confirm. The
    /// pill pulses "Fetching"; when nothing came, "Fetched · up to date" holds, else the
    /// fresh read's status and pill say what came.
    private func runGitFetch() {
        guard let cwd = gitCwd, let snap = focusedGit, let remote = snap.remote else { return }
        let root = snap.root
        updateGit {
            $0.phase = .running(.fetch)
            $0.phaseCwd = cwd
        }
        debugLog("git fetch in \(root): fetch --prune -- \(remote)")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await GitRunner.run(["fetch", "--prune", "--", remote], cwd: root, timeout: Theme.Timing.gitSyncTimeout)
            let ok = result.status == 0
            // git fetch reports each ref it moved; nothing on stderr means nothing came.
            let unchanged = result.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let message: String? = ok
                ? (unchanged ? "Fetched" + Theme.Glyphs.separator + "up to date" : nil)
                : GitRunner.errorLine(result, remote: remote, op: .fetch)
            await self?.finishGitFetch(root: root, ok: ok, message: message, cwd: cwd)
        }
    }

    private func finishGitFetch(root: String, ok: Bool, message: String?, cwd: String) {
        updateGit { $0.lastFetch[root] = Date() }
        finishGitOp(op: .fetch, ok: ok, message: message, cwd: cwd)
    }

    // MARK: Quiet fetch

    /// When the tool opens or a branch is picked: the target's remote is fetched in the
    /// background if it was not in the last `gitAutoFetchInterval`, touching neither the phase
    /// nor the pill; the fresh counts then arrive through a poll's read. One at a time per root;
    /// failures are only logged. Only from an idle phase, so it never overlaps a manual fetch
    /// or pull (or a confirm that would become one); `pressGitSync` checks the other way.
    func gitAutoFetchIfDue() {
        guard readsLocalFiles, isCardOpen, let snap = focusedGit, snap.isRepo, !snap.root.isEmpty,
              let remote = snap.remote, gitPhase == .idle else { return }
        let root = snap.root
        guard !gitPanel.fetching.contains(root) else { return }
        if let last = gitPanel.lastFetch[root], Date().timeIntervalSince(last) < Theme.Timing.gitAutoFetchInterval { return }
        updateGit { $0.fetching.insert(root) }
        debugLog("git quiet fetch in \(root): fetch --prune -- \(remote)")
        Task.detached(priority: .utility) { [weak self] in
            let result = await GitRunner.run(["fetch", "--prune", "--", remote], cwd: root, timeout: Theme.Timing.gitFetchTimeout)
            let error = result.status == 0 ? nil : GitRunner.errorLine(result, remote: remote, op: .fetch)
            await self?.finishGitAutoFetch(root: root, error: error)
        }
    }

    private func finishGitAutoFetch(root: String, error: String?) {
        updateGit {
            $0.fetching.remove(root)
            $0.lastFetch[root] = Date()
        }
        debugLog("git quiet fetch \(error == nil ? "ok" : "failed: " + (error ?? "")) in \(root)")
        refreshGit(poll: true)
    }

    // MARK: Commit

    /// ⏎ in the summary, ⌘⏎ anywhere in the form, or the Commit pill. `git add -- <paths>`
    /// (stages new files and the removal of deleted ones), then `git commit --only --quiet
    /// -m <summary> [-m <description>] -- <paths>`: `--only` commits exactly these paths'
    /// working-tree state and leaves the rest of the index as it was. Unchecked files are
    /// never touched; the index is never reset.
    func runGitCommit() {
        guard gitCanCommit, let cwd = gitCwd, let snap = focusedGit, snap.checkedOut else { return }
        let summary = gitCommitSummary
        let description = gitDraft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = gitCheckedFiles.map(\.path)
        let remote = snap.remote ?? ""
        updateGit {
            $0.phase = .running(.commit)
            $0.phaseCwd = cwd
        }
        var args = ["commit", "--only", "--quiet", "-m", summary]
        if !description.isEmpty { args += ["-m", description] }
        args += ["--"] + paths
        debugLog("git commit in \(snap.root): \(paths.count) files, summary \"\(summary)\"")
        Task.detached(priority: .userInitiated) { [weak self] in
            let add = await GitRunner.run(["add", "--"] + paths, cwd: snap.root, timeout: Theme.Timing.gitCommitTimeout)
            guard add.status == 0 else {
                await self?.finishGitCommit(ok: false, message: GitRunner.errorLine(add, remote: remote, op: .commit), cwd: cwd)
                return
            }
            let result = await GitRunner.run(args, cwd: snap.root, timeout: Theme.Timing.gitCommitTimeout)
            let ok = result.status == 0
            let message = ok ? "Committed " + Format.files(paths.count) : GitRunner.errorLine(result, remote: remote, op: .commit)
            await self?.finishGitCommit(ok: ok, message: message, cwd: cwd)
        }
    }

    /// A commit's end: on success the draft goes (text, checks, form) and the cursor goes to
    /// the top; on failure the form stays with its text and says why.
    private func finishGitCommit(ok: Bool, message: String, cwd: String) {
        if ok {
            updateGit { $0.drafts[cwd] = nil }
            if gitCwd == cwd { rowCursor = 0 }
        }
        finishGitOp(op: .commit, ok: ok, message: message, cwd: cwd)
    }

    // MARK: Undo

    /// U or the newest commit's Undo pill: a checkout whose newest commit is not on the remote
    /// and has a parent, with no write running or holding.
    var gitCanUndo: Bool {
        guard let snap = focusedGit, snap.isRepo, snap.checkedOut, snap.headHasParent,
              let newest = snap.commits.first, !newest.pushed else { return false }
        switch gitPhase {
        case .idle, .failed: return true
        case .confirming, .running, .done: return false
        }
    }

    /// No confirm: `git log -1 --format=%B`, then `git reset --quiet HEAD~1` (mixed), which
    /// loses nothing: the commit's changes come back to the list and its message refills the
    /// form, as GitHub Desktop does.
    func runGitUndo() {
        guard gitCanUndo, let cwd = gitCwd, let snap = focusedGit else { return }
        let remote = snap.remote ?? ""
        updateGit {
            $0.phase = .running(.undo)
            $0.phaseCwd = cwd
        }
        debugLog("git reset in \(snap.root): reset --quiet HEAD~1 (undo \(snap.commits.first?.sha ?? "-"))")
        Task.detached(priority: .userInitiated) { [weak self] in
            let log = await GitRunner.run(["log", "-1", "--format=%B"], cwd: snap.root)
            guard log.status == 0 else {
                await self?.finishGitUndo(ok: false, text: GitRunner.errorLine(log, remote: remote, op: .undo), cwd: cwd)
                return
            }
            let reset = await GitRunner.run(["reset", "--quiet", "HEAD~1"], cwd: snap.root)
            let ok = reset.status == 0
            await self?.finishGitUndo(ok: ok, text: ok ? log.out : GitRunner.errorLine(reset, remote: remote, op: .undo), cwd: cwd)
        }
    }

    /// `text`: the undone commit's message on success, else the error line.
    private func finishGitUndo(ok: Bool, text: String, cwd: String) {
        guard ok else {
            finishGitOp(op: .undo, ok: false, message: text, cwd: cwd)
            return
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = lines.first.map(String.init) ?? ""
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        updateGit {
            $0.drafts[cwd] = GitDraft(summary: subject, description: body, unchecked: [], composing: true, focus: .summary)
        }
        if gitCwd == cwd { rowCursor = 0 }
        let short = subject.count > Theme.Limits.gitUndoSubject
            ? String(subject.prefix(Theme.Limits.gitUndoSubject)) + Theme.Glyphs.ellipsis
            : subject
        finishGitOp(op: .undo, ok: true, message: "Undid \"" + short + "\"", cwd: cwd)
    }

    // MARK: Result

    /// Every write's end. `message` nil (a fetch that brought something): straight back to
    /// idle, the fresh read speaks. Else the result holds `gitResultHold`, an error until a
    /// refresh other than the poll.
    func finishGitOp(op: GitOp, ok: Bool, message: String?, cwd: String) {
        debugLog("git \(op.command) \(ok ? "ok" : "failed"): \(message ?? "-")")
        // Another target armed its own confirm while this write ran: leave that one alone.
        if gitPanel.phaseCwd != cwd {
            refreshGit(poll: true)
            return
        }
        guard let message else {
            updateGit { $0.phase = .idle }
            refreshGit()
            return
        }
        updateGit {
            $0.phase = ok ? .done(op, message) : .failed(op, message)
            $0.phaseCwd = cwd
        }
        guard ok else {
            // The counts may have moved (a partial push); the error stays.
            refreshGit(poll: true)
            return
        }
        // Read at once so the pill and the counts stop offering what was just sent.
        refreshGit()
        // After the hold, the result gives way to the status; the second read is a safety net
        // for when the first was skipped because a poll's read was in flight.
        gitHoldTask?.cancel()
        gitHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Timing.gitResultHold))
            guard let self, !Task.isCancelled else { return }
            if self.gitPanel.phaseCwd == cwd, case .done = self.gitPanel.phase {
                self.updateGit { $0.phase = .idle }
            }
            self.refreshGit()
        }
    }
}
