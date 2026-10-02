// GitModel.swift
// The Git tool's model: what is uncommitted in the target checkout, how far the branch is
// ahead of and behind its upstream, the newest commit (for undo and the dock's receipt), the
// co-authors its recent commits named, the commit draft (summary, description, co-authors,
// checks, the receipt), and the writes (sync, commit, undo; AppState+GitWrites.swift) with their one
// phase. The target
// is the focused session's worktree until the owner picks a branch in the branch picker (W):
// one repository at a time (R opens the repository dropdown), every local branch in it,
// each saying where it lives. A branch checked out nowhere gets a read-only page: its
// changes against main (or its upstream), its commits, and Push; never a checkout.
//
// The one place the app runs a command itself (PLAN.md, "Git tool"): `/usr/bin/git` and
// nothing else, off the main thread, with GIT_OPTIONAL_LOCKS=0. Read-only commands for the
// page; on an explicit press a push or publish or a fast-forward pull (each confirmed with
// ⏎), a fetch, a commit of the checked files, or a mixed reset of the newest unpushed commit;
// a quiet fetch when the tool opens. Never switches, merges, rebases, stashes or discards.
//
// This file holds the value types. The logic lives in AppState+Git (storage, what the tool
// shows, refresh, keys), AppState+GitPicker (the branch picker), AppState+GitDraft (the
// draft, co-authors and form) and AppState+GitWrites (sync, fetch, commit, undo).

import AppKit
import SwiftUI

/// The target's newest commit: what undo resets and the dock's receipt names.
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
    /// The branch on `remote` the upstream tracks ("seadevil" for refs/heads/seadevil). Nil
    /// without an upstream, or when git's config did not name one.
    var upstreamBranch: String?
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
    /// HEAD has a parent, so undo can reset to it. False on the root commit and on a branch page.
    var headHasParent = false
    /// "Name <email>" from the Co-authored-by trailers of the recent commits, newest first,
    /// each once: the co-author suggestions. Empty on a branch page.
    var recentCoauthors: [String] = []
}

/// A write git runs for the owner. Two never run at once on a target: they share one phase.
enum GitOp: String, Equatable {
    case publish, push, pull, fetch, commit, undo

    /// git's own word, for "git pull failed" and "pull from the terminal".
    var command: String {
        switch self {
        case .publish: return "push"
        case .undo: return "reset"
        case .push, .pull, .fetch, .commit: return rawValue
        }
    }

    /// The sync pill's word: "Publish", "Pull", "Push", "Fetch".
    var verb: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The pill while git runs: "Publishing", "Pulling", "Committing", "Undoing".
    var runningTitle: String {
        switch self {
        case .publish: return "Publishing"
        case .push: return "Pushing"
        case .pull: return "Pulling"
        case .fetch: return "Fetching"
        case .commit: return "Committing"
        case .undo: return "Undoing"
        }
    }

    /// The pill while a sync's result holds: "Published", "Pulled".
    var doneTitle: String {
        switch self {
        case .publish: return "Published"
        case .push: return "Pushed"
        case .pull: return "Pulled"
        case .fetch: return "Fetched"
        case .commit: return "Committed"
        case .undo: return "Undone"
        }
    }

    /// Asks first in the right pane: publish, push and pull. A fetch runs at once; a commit
    /// has its form; an undo loses nothing.
    var confirms: Bool { self == .publish || self == .push || self == .pull }
}

/// Every write, from the press to its result. Each target has its own (`GitPanelState.phases`).
enum GitPhase: Equatable {
    case idle
    /// A confirm is up in the right pane (push, publish, pull). ⏎ runs it, esc cancels.
    case confirming(GitOp)
    case running(GitOp)
    /// "Pushed 3 commits", "Pulled 2 commits", "Committed 3 files", "Undid "…"" in the
    /// header's status; holds `Theme.Timing.gitResultHold`.
    case done(GitOp, String)
    /// git's first useful line; stays until a refresh other than the poll.
    case failed(GitOp, String)

    var op: GitOp? {
        switch self {
        case .idle: return nil
        case .confirming(let op), .running(let op), .done(let op, _), .failed(let op, _): return op
        }
    }

    /// A write runs or its result holds: nothing else may start, and the snapshot may still
    /// count what was just sent or committed.
    var isBusy: Bool {
        switch self {
        case .running, .done: return true
        case .idle, .confirming, .failed: return false
        }
    }

    /// The sync pill waits: any write runs, or a sync's result holds (the snapshot may still
    /// count what was just sent). A commit's or an undo's result does not block it: the
    /// refresh ran as it finished, so the counts are fresh and P can push at once.
    var blocksSync: Bool {
        switch self {
        case .running: return true
        case .done(let op, _): return op != .commit && op != .undo
        case .idle, .confirming, .failed: return false
        }
    }
}

/// What the owner is writing for the target, kept until committed or the card closes.
struct GitDraft: Equatable {
    var summary = ""
    var description = ""
    /// Paths left out of the commit; every file is in by default, new files included.
    var unchecked: Set<String> = []
    /// The form is up in the stage (the dock's field has travelled there).
    var composing = false
    /// Which field has the keys: nil, summary, description, or the co-author field.
    var focus: GitDraftFocus? = nil
    /// "Name <email>", each a Co-authored-by trailer of the commit.
    var coauthors: [String] = []
    /// What is typed in the co-author field, not yet a chip.
    var coauthorText = ""
    /// The co-author field and its suggestions show (the "@ Co-author" pill).
    var coauthorsShown = false
    /// Counts the entries the co-author field refused: each one shakes the field.
    var coauthorRejects = 0
    /// The commit the card just made, shown in the dock with Undo until it is pushed, another
    /// commit lands, or the form opens again.
    var receipt: GitReceipt? = nil
}

enum GitDraftFocus: Hashable { case summary, description, coauthor }

/// "Committed · Fix the Push pill" in the dock: the commit's short sha and subject.
struct GitReceipt: Equatable {
    var sha: String
    var subject: String
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
    /// Target key -> its last read. When the card closes only the next target's stays; a
    /// forgotten session's goes with it unless another session shares its folder.
    var snapshots: [String: GitSnapshot] = [:]
    /// Keys being read right now.
    var loading: Set<String> = []
    /// Target key -> its write phase; a missing key is idle. Each target runs and keeps its own
    /// write, so switching targets mid-write neither frees it for a second one nor loses the
    /// first one's result. Only the target on screen may hold a confirm.
    var phases: [String: GitPhase] = [:]
    /// Target key -> the commit being written for it. Cleared when the card closes.
    var drafts: [String: GitDraft] = [:]
    /// Work tree root -> when its remote was last fetched (by hand or quietly).
    var lastFetch: [String: Date] = [:]
    /// Roots with a quiet fetch in flight; never two at once for one root.
    var fetching: Set<String> = []
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

    /// Shuts the picker (or opens it with `open`) with its dropdown closed and the filter cleared.
    mutating func resetPicker(open: Bool = false) {
        pickerOpen = open
        repoMenuOpen = false
        filter = ""
        filterFocused = false
    }

    /// Sets `key`'s phase; idle removes it.
    mutating func setPhase(_ phase: GitPhase, for key: String) {
        phases[key] = phase == .idle ? nil : phase
    }

    /// Every armed confirm goes back to idle: the target on screen changed, and a confirm
    /// armed on one target must not run from another. Running and finished writes stay.
    mutating func dropConfirms() {
        phases = phases.filter { if case .confirming = $0.value { return false } else { return true } }
    }
}
