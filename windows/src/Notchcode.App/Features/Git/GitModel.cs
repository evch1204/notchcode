// GitModel.cs
// Port of Sources/notchcode/Features/Git/GitModel.swift.
// The Git tool's model: what is uncommitted in the target checkout, how far the branch is
// ahead of and behind its upstream, the newest commit (for undo and the dock's receipt), the
// co-authors its recent commits named, the commit draft (summary, description, co-authors,
// checks, the receipt), and the writes (sync, commit, undo; AppState.GitWrites.cs) with their
// one phase. The target is the focused session's worktree until the owner picks a branch in
// the branch picker (W): one repository at a time (R opens the repository dropdown), every
// local branch in it, each saying where it lives. A branch checked out nowhere gets a
// read-only page: its changes against main (or its upstream), its commits, and Push; never a
// checkout.
//
// The one place the app runs a command itself (PLAN.md, "Git tool"): `git.exe` and nothing
// else, off the UI thread, with GIT_OPTIONAL_LOCKS=0. Read-only commands for the page; on an
// explicit press a push or publish or a fast-forward pull (each confirmed with ⏎), a fetch, a
// commit of the checked files, or a mixed reset of the newest unpushed commit; a quiet fetch
// when the tool opens. Never switches, merges, rebases, stashes or discards.
//
// This file holds the value types. The logic lives in AppState.Git (storage, what the tool
// shows, refresh, keys), AppState.GitPicker (the branch picker), AppState.GitDraft (the
// draft, co-authors and form) and AppState.GitWrites (sync, fetch, commit, undo).

using System.Collections.Immutable;

namespace Notchcode.Features.Git;

/// The target's newest commit: what undo resets and the dock's receipt names.
public sealed record GitCommit
{
    public string Id => Sha;
    public string Sha { get; init; } = "";
    public string Subject { get; init; } = "";
    public DateTime Date { get; init; }
    /// On the remote already. False for commits ahead of the upstream (or, for a branch
    /// with no upstream, on no remote at all).
    public bool Pushed { get; init; }
}

/// What the Git tool shows: a checkout (a session's folder, or a picked checkout's top
/// level), or a branch that is checked out nowhere, read from its repository's main folder.
public abstract record GitTarget
{
    private GitTarget() { }

    public sealed record Folder(string Path) : GitTarget;
    public sealed record Branch(string Repo, string Name) : GitTarget;

    /// Snapshots and the push phase are kept under this.
    public string Key => this switch
    {
        Folder f => f.Path,
        Branch b => b.Repo + "\u001f" + b.Name,
        _ => "",
    };
}

/// The target as the last read left it.
public sealed record GitSnapshot
{
    /// The target's key (`GitTarget.Key`): a folder, or repository and branch.
    public string Cwd { get; init; } = "";
    public bool IsRepo { get; init; }
    /// The work tree's top level (a branch page: the main folder); every git command runs there.
    public string Root { get; init; } = "";
    /// The repository's name: its main checkout's folder (a bare repository without ".git").
    public string? RepoName { get; init; }
    /// Null on a detached HEAD.
    public string? Branch { get; init; }
    /// "origin/seadevil"; null when the branch was never published.
    public string? Upstream { get; init; }
    /// The remote a push goes to: the upstream's, else origin, else the first. Null: no remote.
    public string? Remote { get; init; }
    /// The branch on `Remote` the upstream tracks ("seadevil" for refs/heads/seadevil). Null
    /// without an upstream, or when git's config did not name one.
    public string? UpstreamBranch { get; init; }
    public int Ahead { get; init; }
    public int Behind { get; init; }
    /// Commits a push would send: `Ahead`, or for an unpublished branch the commits on no remote.
    public int Unpushed { get; init; }
    /// False for a branch checked out nowhere: `Files` are its changes against `Base`.
    public bool CheckedOut { get; init; } = true;
    /// What a branch page compares against: its upstream, else the default branch.
    public string? Base { get; init; }
    /// Commits in `Base..branch`.
    public int BaseAhead { get; init; }
    public ImmutableList<FileChange> Files { get; init; } = [];
    public ImmutableList<GitCommit> Commits { get; init; } = [];
    /// Path -> lines in the file as the branch has it, for the diff's minimap.
    public ImmutableDictionary<string, int> LineCounts { get; init; } = ImmutableDictionary<string, int>.Empty;
    /// HEAD has a parent, so undo can reset to it. False on the root commit and on a branch page.
    public bool HeadHasParent { get; init; }
    /// "Name <email>" from the Co-authored-by trailers of the recent commits, newest first,
    /// each once: the co-author suggestions. Empty on a branch page.
    public ImmutableList<string> RecentCoauthors { get; init; } = [];

    public bool Equals(GitSnapshot? o) =>
        o is not null && Cwd == o.Cwd && IsRepo == o.IsRepo && Root == o.Root && RepoName == o.RepoName
        && Branch == o.Branch && Upstream == o.Upstream && Remote == o.Remote && UpstreamBranch == o.UpstreamBranch
        && Ahead == o.Ahead && Behind == o.Behind && Unpushed == o.Unpushed && CheckedOut == o.CheckedOut
        && Base == o.Base && BaseAhead == o.BaseAhead && Files.SequenceEqual(o.Files) && Commits.SequenceEqual(o.Commits)
        && LineCounts.Count == o.LineCounts.Count && LineCounts.All(p => o.LineCounts.TryGetValue(p.Key, out var v) && v == p.Value)
        && HeadHasParent == o.HeadHasParent && RecentCoauthors.SequenceEqual(o.RecentCoauthors);

    public override int GetHashCode() => HashCode.Combine(Cwd, Root, Branch, Files.Count, Ahead, Behind);
}

/// A write git runs for the owner. Two never run at once on a target: they share one phase.
public enum GitOp { Publish, Push, Pull, Fetch, Commit, Undo }

public static class GitOps
{
    extension(GitOp op)
    {
        /// The raw name: "publish", "push", "pull", "fetch", "commit", "undo".
        public string RawValue => op.ToString().ToLowerInvariant();

        /// git's own word, for "git pull failed" and "pull from the terminal".
        public string Command => op switch
        {
            GitOp.Publish => "push",
            GitOp.Undo => "reset",
            _ => op.RawValue,
        };

        /// The sync pill's word: "Publish", "Pull", "Push", "Fetch".
        public string Verb => op.ToString();

        /// The pill while git runs: "Publishing", "Pulling", "Committing", "Undoing".
        public string RunningTitle => op switch
        {
            GitOp.Publish => "Publishing",
            GitOp.Push => "Pushing",
            GitOp.Pull => "Pulling",
            GitOp.Fetch => "Fetching",
            GitOp.Commit => "Committing",
            _ => "Undoing",
        };

        /// The pill while a sync's result holds: "Published", "Pulled".
        public string DoneTitle => op switch
        {
            GitOp.Publish => "Published",
            GitOp.Push => "Pushed",
            GitOp.Pull => "Pulled",
            GitOp.Fetch => "Fetched",
            GitOp.Commit => "Committed",
            _ => "Undone",
        };

        /// Asks first in the right pane: publish, push and pull. A fetch runs at once; a commit
        /// has its form; an undo loses nothing.
        public bool Confirms => op is GitOp.Publish or GitOp.Push or GitOp.Pull;
    }
}

/// Every write, from the press to its result. Each target has its own (`GitPanelState.Phases`).
public abstract record GitPhase
{
    private GitPhase() { }

    public sealed record Idle : GitPhase
    {
        public static readonly Idle Instance = new();
    }
    /// A confirm is up in the right pane (push, publish, pull). ⏎ runs it, esc cancels.
    public sealed record Confirming(GitOp Op) : GitPhase;
    public sealed record Running(GitOp Op) : GitPhase;
    /// "Pushed 3 commits", "Pulled 2 commits", "Committed 3 files", "Undid "…"" in the
    /// header's status; holds `Theme.Timing.GitResultHold`.
    public sealed record Done(GitOp Op, string Message) : GitPhase;
    /// git's first useful line; stays until a refresh other than the poll.
    public sealed record Failed(GitOp Op, string Message) : GitPhase;

    public GitOp? OpValue => this switch
    {
        Confirming c => c.Op,
        Running r => r.Op,
        Done d => d.Op,
        Failed f => f.Op,
        _ => null,
    };

    /// A write runs or its result holds: nothing else may start, and the snapshot may still
    /// count what was just sent or committed.
    public bool IsBusy => this is Running or Done;

    /// The sync pill waits: any write runs, or a sync's result holds (the snapshot may still
    /// count what was just sent). A commit's or an undo's result does not block it: the
    /// refresh ran as it finished, so the counts are fresh and P can push at once.
    public bool BlocksSync => this switch
    {
        Running => true,
        Done d => d.Op is not (GitOp.Commit or GitOp.Undo),
        _ => false,
    };
}

/// Which field of the commit form has the keys.
public enum GitDraftFocus { Summary, Description, Coauthor }

/// "Committed · Fix the Push pill" in the dock: the commit's short sha and subject.
public sealed record GitReceipt(string Sha, string Subject);

/// What the owner is writing for the target, kept until committed or the card closes.
public sealed record GitDraft
{
    public string Summary { get; init; } = "";
    public string Description { get; init; } = "";
    /// Paths left out of the commit; every file is in by default, new files included.
    public ImmutableHashSet<string> Unchecked { get; init; } = [];
    /// The form is up in the stage (the dock's field has travelled there).
    public bool Composing { get; init; }
    /// Which field has the keys: null, summary, description, or the co-author field.
    public GitDraftFocus? Focus { get; init; }
    /// "Name <email>", each a Co-authored-by trailer of the commit.
    public ImmutableList<string> Coauthors { get; init; } = [];
    /// What is typed in the co-author field, not yet a chip.
    public string CoauthorText { get; init; } = "";
    /// The co-author field and its suggestions show (the "@ Co-author" pill).
    public bool CoauthorsShown { get; init; }
    /// Counts the entries the co-author field refused: each one shakes the field.
    public int CoauthorRejects { get; init; }
    /// The commit the card just made, shown in the dock with Undo until it is pushed, another
    /// commit lands, or the form opens again.
    public GitReceipt? Receipt { get; init; }

    public bool Equals(GitDraft? o) =>
        o is not null && Summary == o.Summary && Description == o.Description && Unchecked.SetEquals(o.Unchecked)
        && Composing == o.Composing && Focus == o.Focus && Coauthors.SequenceEqual(o.Coauthors)
        && CoauthorText == o.CoauthorText && CoauthorsShown == o.CoauthorsShown
        && CoauthorRejects == o.CoauthorRejects && Receipt == o.Receipt;

    public override int GetHashCode() => HashCode.Combine(Summary, Description, Unchecked.Count, Composing, Focus, Coauthors.Count, Receipt);
}

/// Where a local branch is checked out (Swift's `GitBranch.Place`).
public abstract record GitPlace
{
    private GitPlace() { }

    /// Checked out in the repository's main folder.
    public sealed record Main(string Path) : GitPlace;
    /// Checked out in a linked worktree.
    public sealed record Worktree(string Path) : GitPlace;
    /// Checked out nowhere.
    public sealed record Nowhere : GitPlace
    {
        public static readonly Nowhere Instance = new();
    }
}

/// One local branch, as the picker lists it.
public sealed record GitBranch
{
    public string Id => Name;
    public string Name { get; init; } = "";
    /// "origin/main"; null when never published.
    public string? Upstream { get; init; }
    public DateTime Date { get; init; }
    public GitPlace Place { get; init; } = GitPlace.Nowhere.Instance;
    /// Uncommitted files of its checkout; null when checked out nowhere or the read failed.
    public int? Uncommitted { get; init; }
    /// Commits ahead of `Upstream`, or of the default branch when it has none. Null: not counted.
    public int? Ahead { get; init; }

    /// The checkout's folder; null when checked out nowhere.
    public string? Path => Place switch
    {
        GitPlace.Main m => m.Path,
        GitPlace.Worktree w => w.Path,
        _ => null,
    };
}

/// One repository in the picker: its local branches, newest commit first.
public sealed record GitRepoGroup
{
    /// The main folder's path.
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    /// "main", else "master"; null when neither exists.
    public string? DefaultBranch { get; init; }
    public ImmutableList<GitBranch> Branches { get; init; } = [];

    public bool Equals(GitRepoGroup? o) =>
        o is not null && Id == o.Id && Name == o.Name && DefaultBranch == o.DefaultBranch && Branches.SequenceEqual(o.Branches);

    public override int GetHashCode() => HashCode.Combine(Id, Name, Branches.Count);
}

/// The Git tool's state. Collections are immutable: change one through `AppState.UpdateGit`
/// with `with`, so every change is published.
public sealed record GitPanelState
{
    /// Target key -> its last read. When the card closes only the next target's stays; a
    /// forgotten session's goes with it unless another session shares its folder.
    public ImmutableDictionary<string, GitSnapshot> Snapshots { get; init; } = ImmutableDictionary<string, GitSnapshot>.Empty;
    /// Keys being read right now.
    public ImmutableHashSet<string> Loading { get; init; } = [];
    /// Target key -> its write phase; a missing key is idle. Each target runs and keeps its own
    /// write, so switching targets mid-write neither frees it for a second one nor loses the
    /// first one's result. Only the target on screen may hold a confirm.
    public ImmutableDictionary<string, GitPhase> Phases { get; init; } = ImmutableDictionary<string, GitPhase>.Empty;
    /// Target key -> the commit being written for it. Cleared when the card closes.
    public ImmutableDictionary<string, GitDraft> Drafts { get; init; } = ImmutableDictionary<string, GitDraft>.Empty;
    /// Work tree root -> when its remote was last fetched (by hand or quietly).
    public ImmutableDictionary<string, DateTime> LastFetch { get; init; } = ImmutableDictionary<string, DateTime>.Empty;
    /// Roots with a quiet fetch in flight; never two at once for one root.
    public ImmutableHashSet<string> Fetching { get; init; } = [];
    /// The branch picked by hand; null follows the focused session. Cleared when the card closes.
    public GitTarget? Picked { get; init; }
    /// The picker replaces the tool's content while this is true.
    public bool PickerOpen { get; init; }
    /// Index into the chosen repository's rows as the filter leaves them.
    public int PickerCursor { get; init; }
    /// The repository whose branches the picker lists (its main folder).
    public string? PickerRepo { get; init; }
    /// The repository dropdown under the picker's pill.
    public bool RepoMenuOpen { get; init; }
    public int RepoMenuCursor { get; init; }
    /// The picker's filter, by branch name; its field has the keys while focused.
    public string Filter { get; init; } = "";
    public bool FilterFocused { get; init; }
    /// The last listing: one group per repository, in the Sessions tab's order.
    public ImmutableList<GitRepoGroup> Repos { get; init; } = [];
    /// Session cwd -> its worktree's top level, from the last listing.
    public ImmutableDictionary<string, string> RootByCwd { get; init; } = ImmutableDictionary<string, string>.Empty;
    /// A listing is running.
    public bool Listing { get; init; }

    /// Shuts the picker (or opens it with `open`) with its dropdown closed and the filter cleared.
    public GitPanelState ResetPicker(bool open = false) =>
        this with { PickerOpen = open, RepoMenuOpen = false, Filter = "", FilterFocused = false };

    /// Sets `key`'s phase; idle removes it.
    public GitPanelState SetPhase(GitPhase phase, string key) =>
        this with { Phases = phase is GitPhase.Idle ? Phases.Remove(key) : Phases.SetItem(key, phase) };

    /// Every armed confirm goes back to idle: the target on screen changed, and a confirm
    /// armed on one target must not run from another. Running and finished writes stay.
    public GitPanelState DropConfirms()
    {
        var kept = Phases.Where(p => p.Value is not GitPhase.Confirming).ToImmutableDictionary();
        return kept.Count == Phases.Count ? this : this with { Phases = kept };
    }
}
