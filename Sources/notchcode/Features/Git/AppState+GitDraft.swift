// AppState+GitDraft.swift
// The Git tool's commit draft, one per target: its summary and description, the
// co-authors (those the target's recent commits named, plus any typed), the checked files,
// and the form built from them (the summary prefill, the Commit button). The commit itself
// runs in AppState+GitWrites.swift.

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

    // MARK: Co-authors

    func setGitCoauthorText(_ text: String) {
        updateGitDraft { $0.coauthorText = text }
    }

    /// The "@ Co-author" pill: the field and its suggestions show (the field focused) or go.
    func toggleGitCoauthors() {
        let shown = !gitDraft.coauthorsShown
        updateGitDraft {
            $0.coauthorsShown = shown
            if shown { $0.focus = .coauthor } else if $0.focus == .coauthor { $0.focus = nil }
        }
    }

    /// The "recent" row: co-authors from the recent commits' trailers matching what is typed
    /// (name or email, case-insensitive), minus the ones already added, at most
    /// `gitCoauthorSuggestions`. The first is the one ⏎ adds with the field empty.
    var gitCoauthorSuggestions: [String] {
        let draft = gitDraft
        let added = Set(draft.coauthors.map { $0.lowercased() })
        let query = draft.coauthorText.trimmingCharacters(in: .whitespaces)
        return (focusedGit?.recentCoauthors ?? [])
            .filter { !added.contains($0.lowercased()) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
            .prefix(Theme.Limits.gitCoauthorSuggestions)
            .map { $0 }
    }

    /// ⏎ in the co-author field: the typed entry as a chip, or with nothing typed the first
    /// suggestion. An entry git could not use as a trailer shakes the field and stays typed.
    func addGitCoauthor() {
        let typed = gitDraft.coauthorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            if let first = gitCoauthorSuggestions.first { addGitCoauthor(first) }
            return
        }
        guard let entry = Self.gitCoauthorEntry(typed) else {
            updateGitDraft { $0.coauthorRejects += 1 }
            return
        }
        addGitCoauthor(entry)
        setGitCoauthorText("")
    }

    /// A suggestion's click, or a checked entry: added once.
    func addGitCoauthor(_ entry: String) {
        updateGitDraft {
            if !$0.coauthors.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) {
                $0.coauthors.append(entry)
            }
        }
    }

    func removeGitCoauthor(_ entry: String) {
        updateGitDraft { $0.coauthors.removeAll { $0 == entry } }
    }

    /// ⌫ in the empty co-author field takes the last chip.
    func removeLastGitCoauthor() {
        updateGitDraft { if !$0.coauthors.isEmpty { $0.coauthors.removeLast() } }
    }

    /// "Name <email>" from "Name <email>", "<email>" or "email"; with no name, the email's local
    /// part. Nil when there is no email git would accept in a trailer.
    nonisolated static func gitCoauthorEntry(_ text: String) -> String? {
        let email = "([^<>@\\s]+@[^<>@\\s]+)"
        let patterns = ["^\\s*([^<>]*?)\\s*<" + email + ">\\s*$", "^\\s*()" + email + "\\s*$"]
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let emailRange = Range(match.range(at: 2), in: text) else { continue }
            let address = String(text[emailRange])
            var name = text[nameRange].trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = String(address.prefix { $0 != "@" }) }
            return name + " <" + address + ">"
        }
        return nil
    }

    // MARK: Form

    /// C, a click on the dock, or undo's refill: the dock's field travels into the stage and
    /// becomes the form, the summary focused. Only for a checkout with changed files; C again
    /// while it shows does nothing. A folded rail comes back first (the dock lives in it);
    /// the receipt gives way to the fresh field.
    func openGitCommitForm() {
        guard let snap = focusedGit, snap.isRepo, snap.checkedOut, !snap.files.isEmpty,
              !gitDraft.composing else { return }
        cancelGitConfirm()
        if gitListCollapsed { setFilesTreeHidden(false) }
        updateGitDraft {
            $0.composing = true
            $0.focus = .summary
            $0.receipt = nil
        }
        debugLog("git commit form opened for \(snap.root): \(gitCheckedFiles.count) of \(snap.files.count) files checked")
    }

    /// Esc or Cancel: the diff comes back; the text and the checks stay for next time.
    /// False when the form was not up.
    @discardableResult
    func cancelGitCommitForm() -> Bool {
        guard gitDraft.composing else { return false }
        setGitComposing(false)
        debugLog("git commit form closed")
        return true
    }

    /// A click on a file row: its diff shows at once, over the form or the confirm if one was up.
    func selectGitRow(key: String) {
        setGitRowCursor(key: key)
        if gitDraft.composing { setGitComposing(false) }
        cancelGitConfirm()
    }

    /// With one file checked, GitHub Desktop's prefill: "Create x", "Rename w to x", "Delete x",
    /// "Update x".
    private var gitSummaryPrefill: String? {
        let checked = gitCheckedFiles
        guard checked.count == 1, let file = checked.first else { return nil }
        let name = Format.fileName(file.path)
        switch file.kind {
        case "new": return "Create " + name
        case "renamed": return "Rename " + Format.fileName(file.renamedFrom ?? file.path) + " to " + name
        case "deleted": return "Delete " + name
        default: return "Update " + name
        }
    }

    /// The summary field's prompt: the one-file prefill, else "Summary (required)".
    var gitSummaryPlaceholder: String {
        gitSummaryPrefill ?? "Summary (required)"
    }

    /// The summary a commit uses: what was typed, else the one-file prefill.
    var gitCommitSummary: String {
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
}
