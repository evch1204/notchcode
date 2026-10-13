// AppState.Git.cs
// Port of Sources/notchcode/Features/Git/AppState+Git.swift.
// The Git tool's state on AppState: where it is stored and how every write goes through
// `UpdateGit`, what the tool shows (the target, its snapshot and phase, the rows, the sync
// pill's words), when it refreshes (card open, tool shown, polling) and its keys. The value
// types are in Features/Git/GitModel.cs.

using System.IO;
using System.Windows.Threading;
using Notchcode.App;
using Notchcode.Features.Git;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: Storage

    // The state itself is stored in AppState.cs (`GitStore`, `GitPollTask`, `GitHoldTasks`, one
    // result hold per target as each target keeps its own phase); every write goes through
    // `UpdateGit`, which raises PropertyChanged("GitPanel").

    public GitPanelState GitPanel => GitStore;

    public void UpdateGit(Func<GitPanelState, GitPanelState> change)
    {
        var next = change(GitStore);
        if (next == GitStore) return;
        GitStore = next;
        OnPropertyChanged(nameof(GitPanel));
    }

    /// Runs `work` off the UI thread and hands its result to `apply` back on it.
    private static void OffUi<T>(Func<Task<T>> work, Action<T> apply)
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        _ = Task.Run(work).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully) dispatcher.InvokeAsync(() => apply(t.Result));
            else DebugLog.Write("git task failed: " + t.Exception?.GetBaseException().Message);
        }, TaskScheduler.Default);
    }

    // MARK: What the tool shows

    /// The branch picked by hand, else the focused session's folder.
    public GitTarget? GitTarget
    {
        get
        {
            if (GitPanel.Picked is { } picked) return picked;
            return FocusedGitCwd is { } cwd ? new GitTarget.Folder(cwd) : null;
        }
    }

    /// Where the tool's snapshot and push phase live: the target's key.
    public string? GitCwd => GitTarget?.Key;

    /// The focused session's folder, when it has one.
    private string? FocusedGitCwd => FocusedSession?.Cwd is { Length: > 0 } cwd ? cwd : null;

    /// The focused session's worktree top level, when a read or a listing has found it.
    private string? FocusedGitRoot
    {
        get
        {
            if (FocusedGitCwd is not { } cwd) return null;
            return GitPanel.Snapshots.GetValueOrDefault(cwd)?.Root ?? GitPanel.RootByCwd.GetValueOrDefault(cwd);
        }
    }

    /// Two folders git and Windows spell differently ("C:/x" and "C:\x", any case) are one.
    internal static bool SamePath(string? a, string? b)
    {
        if (a is null || b is null) return a == b;
        static string Norm(string p) => p.Replace('\\', '/').TrimEnd('/');
        return string.Equals(Norm(a), Norm(b), StringComparison.OrdinalIgnoreCase);
    }

    /// The target is the focused session's checkout (always, until a hand pick). A branch
    /// checked out nowhere says so in its status instead.
    public bool GitTargetIsFocused
    {
        get
        {
            if (GitPanel.Picked is not { } picked) return true;
            if (picked is not GitTarget.Folder folder) return true;
            return SamePath(FocusedGitRoot, folder.Path);
        }
    }

    /// The target pill's parts: "notchcode" dim, then "seadevil" (the worktree folder) or,
    /// for a branch checked out nowhere, "design/toolbar" in mono. No repository part for a
    /// main checkout named like its repository.
    public (string? Repo, string Place, bool PlaceIsBranch) GitTargetParts
    {
        get
        {
            if (GitTarget is GitTarget.Branch branch)
            {
                var repoName = GitPanel.Repos.FirstOrDefault(r => r.Id == branch.Repo)?.Name ?? FocusedGit?.RepoName;
                return (repoName, branch.Name, true);
            }
            var root = FocusedGit?.Root ?? GitCwd ?? "";
            var folder = Path.GetFileName(root.TrimEnd('/', '\\'));
            var repo = GitPanel.Repos.FirstOrDefault(r => r.Branches.Any(b => SamePath(b.Path, root)))?.Name ?? FocusedGit?.RepoName;
            if (string.IsNullOrEmpty(repo) || repo == folder) return (null, folder, false);
            return (repo, folder, false);
        }
    }

    public GitSnapshot? FocusedGit => GitCwd is { } key ? GitPanel.Snapshots.GetValueOrDefault(key) : null;

    /// The write phase of the target.
    public GitPhase GitPhase => GitCwd is { } key ? GitPanel.Phases.GetValueOrDefault(key) ?? GitPhase.Idle.Instance : GitPhase.Idle.Instance;

    /// The uncommitted files (a branch page: its changes) as rows; `RowCursor` indexes them
    /// while the Git tool shows.
    public List<DiffRowItem> GitRows => (FocusedGit?.Files ?? []).Select(f => new DiffRowItem("g|" + f.Path, f)).ToList();

    public string? GitCursorRowKey
    {
        get
        {
            var rows = GitRows;
            return RowCursor >= 0 && RowCursor < rows.Count ? rows[RowCursor].Key : null;
        }
    }

    /// The file whose diff the right pane shows: the cursor's row, the first file by default
    /// (as GitHub Desktop selects). Null with nothing to show.
    public FileChange? GitSelectedFile
    {
        get
        {
            var rows = GitRows;
            return RowCursor >= 0 && RowCursor < rows.Count ? rows[RowCursor].File : null;
        }
    }

    /// The rail is folded to its checkbox column (Ctrl B). One preference with the Files tree:
    /// the left column of both tools. Only while there is a file, as Files needs an open file.
    public bool GitListCollapsed => Prefs.FilesTreeHidden && GitSelectedFile is not null;

    /// Ctrl B or the pill. Does nothing with no file to show.
    public void ToggleGitList()
    {
        if (GitSelectedFile is null) return;
        SetGitRailHidden(!GitListCollapsed);
    }

    /// The Files tool's `SetFilesTreeHidden` (AppState.Files, wave 1c): the one preference both
    /// tools' left columns follow. Kept here so the Git tool does not wait on the Files port;
    /// at integration this may call `SetFilesTreeHidden` instead.
    private void SetGitRailHidden(bool hidden)
    {
        if (Prefs.FilesTreeHidden == hidden) return;
        if (hidden) FilesTool = FilesTool with { FilterFocused = false };
        Prefs = Prefs with { FilesTreeHidden = hidden };
    }

    public void SetGitRowCursor(string key)
    {
        int index = GitRows.FindIndex(r => r.Key == key);
        if (index >= 0) RowCursor = index;
    }

    /// What the header's pill offers, first match wins, in GitHub Desktop's order: nothing
    /// without a branch or a remote; Publish without an upstream; Pull when behind (a checkout
    /// only: a branch page never pulls); Push when ahead; else Fetch.
    public GitOp? GitSyncOp
    {
        get
        {
            if (FocusedGit is not { IsRepo: true, Branch: not null, Remote: not null } snap) return null;
            if (snap.Upstream is null) return GitOp.Publish;
            if (snap.CheckedOut && snap.Behind > 0) return GitOp.Pull;
            if (snap.Ahead > 0) return GitOp.Push;
            return GitOp.Fetch;
        }
    }

    /// The pill can be pressed: it offers something, and no write runs or holds a sync's
    /// result (`GitPhase.BlocksSync`).
    public bool GitCanSync => !GitPhase.BlocksSync && GitSyncOp is not null;

    /// "Publish", "Pull", "Push", "Fetch"; "Push" on the disabled pill.
    public string GitSyncVerb => (GitSyncOp ?? GitOp.Push).Verb;

    /// The count in the pill: the commits a push or publish would send, or a pull would bring.
    /// Null for a fetch, when none, and while a write runs or holds a sync's result.
    public int? GitSyncCount
    {
        get
        {
            if (GitPhase.BlocksSync || GitSyncOp is not { } op || FocusedGit is not { } snap) return null;
            int count;
            switch (op)
            {
                case GitOp.Push or GitOp.Publish: count = snap.Unpushed; break;
                case GitOp.Pull: count = snap.Behind; break;
                default: return null;
            }
            return count > 0 ? count : null;
        }
    }

    /// "not published yet", "up to date with origin", "2 behind origin", "no remote"; with
    /// commits to push (their count sits in the pill) only "2 behind", or nothing. For a branch
    /// checked out nowhere "not checked out · 4 commits ahead of main".
    public string GitStatusText
    {
        get
        {
            if (FocusedGit is not { IsRepo: true } snap) return "";
            if (!snap.CheckedOut)
            {
                const string lead = "not checked out";
                if (snap.Base is not { } baseRef) return lead;
                var ahead = snap.BaseAhead == 0 ? "nothing ahead of " + baseRef : Commits(snap.BaseAhead) + " ahead of " + baseRef;
                return lead + Theme.Glyphs.Separator + ahead;
            }
            if (snap.Branch is null) return "detached HEAD";
            if (snap.Remote is not { } remote) return "no remote";
            if (snap.Upstream is null) return "not published yet";
            if (snap.Ahead > 0)
            {
                // Behind as well: the pill pulls, so the status names what waits to be pushed.
                return snap.Behind > 0 && snap.CheckedOut ? $"{snap.Ahead} ahead" + Theme.Glyphs.Separator + $"{snap.Behind} behind" : "";
            }
            if (snap.Behind > 0) return Commits(snap.Behind) + " behind " + remote;
            return "up to date with " + remote;
        }
    }

    /// "Push 3 commits to origin/seadevil?", "Publish seadevil to origin?" or "Pull 2 commits
    /// from origin/main?". Names exactly the remote and branch `RunGitSync` passes to git.
    public string GitConfirmText
    {
        get
        {
            if (FocusedGit is not { Branch: { } branch, Remote: { } remote } snap) return "";
            return (GitPhase.OpValue ?? GitSyncOp) switch
            {
                GitOp.Publish => "Publish " + branch + " to " + remote + "?",
                GitOp.Push => "Push " + Commits(snap.Ahead) + " to " + PushDestination(snap) + "?",
                GitOp.Pull => "Pull " + Commits(snap.Behind) + " from " + (snap.Upstream ?? PushDestination(snap)) + "?",
                _ => "",
            };
        }
    }

    /// The confirm's line while git runs: "Pushing to origin/seadevil…", "Publishing seadevil
    /// to origin…", "Pulling from origin/main…".
    public string GitRunningText
    {
        get
        {
            if (FocusedGit is not { } snap || GitPhase is not GitPhase.Running running) return "";
            var remote = snap.Remote ?? "";
            return running.Op switch
            {
                GitOp.Publish => "Publishing " + (snap.Branch ?? "") + " to " + remote + Theme.Glyphs.Ellipsis,
                GitOp.Push => "Pushing to " + PushDestination(snap) + Theme.Glyphs.Ellipsis,
                GitOp.Pull => "Pulling from " + (snap.Upstream ?? PushDestination(snap)) + Theme.Glyphs.Ellipsis,
                var op => op.RunningTitle + Theme.Glyphs.Ellipsis,
            };
        }
    }

    /// "origin/seadevil": the remote and its branch a push to the upstream updates.
    public static string PushDestination(GitSnapshot snap)
    {
        if (snap.Remote is not { } remote || (snap.UpstreamBranch ?? snap.Branch) is not { } branch) return snap.Upstream ?? "";
        return remote + "/" + branch;
    }

    public static string Commits(int count) => count == 1 ? "1 commit" : $"{count} commits";

    // MARK: Refresh triggers

    /// The card opened: read once whatever tool shows (PLAN: "once when the card opens").
    public void GitCardOpened()
    {
        if (SelectedTab == CardTab.Git) GitToolShown(); else RefreshGit();
    }

    /// The Git tool came on screen: no confirm (the focus may have moved while it was away), a
    /// fresh read, then one every `gitRefreshInterval`.
    public void GitToolShown()
    {
        UpdateGit(s => s.DropConfirms());
        CloseGitPicker();
        RefreshGit(thenFetch: true);
        GitAutoFetchIfDue();
        StartGitPolling();
    }

    /// Another session is focused: its worktree, and no confirm carried over. A hand pick
    /// stays; the listing is read again so the header knows whether it is still the focused one.
    public void GitFocusChanged()
    {
        if (GitPanel.Picked is not null)
        {
            if (!GitPanel.RootByCwd.ContainsKey(FocusedGitCwd ?? "")) RefreshGitWorktrees();
            return;
        }
        UpdateGit(s => s.DropConfirms());
        RefreshGit();
    }

    /// The card closed: the hand pick, the picker and any confirm go; next time the tool follows
    /// the focus. Only the snapshot of that next target stays, and the fetch times of roots no
    /// kept snapshot uses go too, so a reopen reads them fresh. A quiet fetch in flight keeps
    /// its mark (it clears itself as it lands), so it is never run twice at once.
    public void GitCardClosed()
    {
        var next = FocusedGitCwd is { } cwd ? new GitTarget.Folder(cwd).Key : null;
        UpdateGit(s =>
        {
            s = s.ResetPicker() with { Picked = null, Drafts = s.Drafts.Clear() };
            s = s.DropConfirms();
            var snapshots = s.Snapshots.Where(p => p.Key == next).ToDictionary();
            var roots = snapshots.Values.Select(v => v.Root).ToHashSet();
            return s with
            {
                Snapshots = System.Collections.Immutable.ImmutableDictionary.CreateRange(snapshots),
                LastFetch = System.Collections.Immutable.ImmutableDictionary.CreateRange(s.LastFetch.Where(p => roots.Contains(p.Key))),
            };
        });
    }

    /// A hook's tree report arrived (a Bash command ran): the worktree may have changed.
    public void GitTreeReported(string cwd)
    {
        if (!IsCardOpen || SelectedTab != CardTab.Git || GitCwd is not { } target) return;
        if (cwd != target && GitPanel.RootByCwd.GetValueOrDefault(cwd) != target) return;
        RefreshGit();
    }

    private void StartGitPolling()
    {
        if (GitPollTask is not null) return;
        var cts = new CancellationTokenSource();
        GitPollTask = cts;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.GitRefreshInterval) };
        timer.Tick += (_, _) =>
        {
            // Stops once the card closes or another tool is picked; a request over the
            // tool only pauses it.
            if (cts.IsCancellationRequested || !IsCardOpen || SelectedTab != CardTab.Git)
            {
                timer.Stop();
                if (GitPollTask == cts) GitPollTask = null;
                return;
            }
            if (IsShowingTool(CardTab.Git)) RefreshGit(poll: true);
        };
        timer.Start();
    }

    /// Reads the target in the background. A poll keeps a write's error on screen; any other
    /// refresh clears it. `thenFetch`: once read, fetch its remote quietly if it is due.
    public void RefreshGit(bool poll = false, bool thenFetch = false)
    {
        if (!ReadsLocalFiles || GitTarget is not { } target) return;
        var key = target.Key;
        if (!poll && GitPanel.Phases.GetValueOrDefault(key) is GitPhase.Failed)
            UpdateGit(s => s.SetPhase(GitPhase.Idle.Instance, key));
        if (GitPanel.Loading.Contains(key)) return;
        UpdateGit(s => s with { Loading = s.Loading.Add(key) });
        OffUi(() => target switch
        {
            GitTarget.Branch b => GitRunner.ReadBranch(b.Repo, b.Name, key),
            GitTarget.Folder f => GitRunner.Read(f.Path),
            _ => Task.FromResult(new GitSnapshot { Cwd = key }),
        }, snapshot => ApplyGit(snapshot, thenFetch));
    }

    private void ApplyGit(GitSnapshot snapshot, bool thenFetch)
    {
        UpdateGit(s => s with { Loading = s.Loading.Remove(snapshot.Cwd), Snapshots = s.Snapshots.SetItem(snapshot.Cwd, snapshot) });
        DebugLog.Write($"git {snapshot.Cwd}: repo={snapshot.IsRepo} checkedOut={snapshot.CheckedOut} branch={snapshot.Branch ?? "-"} upstream={snapshot.Upstream ?? "-"} base={snapshot.Base ?? "-"} ahead={snapshot.Ahead} behind={snapshot.Behind} unpushed={snapshot.Unpushed} files={snapshot.Files.Count} +{snapshot.Files.Sum(f => f.Added)} -{snapshot.Files.Sum(f => f.Removed)} commits={snapshot.Commits.Count}");
        if (snapshot.Cwd != GitCwd) return;
        if (IsShowingTool(CardTab.Git))
        {
            int count = snapshot.Files.Count;
            if (RowCursor >= count) RowCursor = Math.Max(0, count - 1);
        }
        // The pill offers something else now (pushed from the terminal, or a fetch found
        // commits to pull while a push was asked): drop the confirm.
        if (GitPhase is GitPhase.Confirming confirming && (!GitCanSync || confirming.Op != GitSyncOp)) CancelGitConfirm();
        if (thenFetch) GitAutoFetchIfDue();
    }

    // MARK: Keys

    /// Esc in the Git tool, one layer at a time: the repository dropdown, then the picker's
    /// filter, then the picker, then the commit form, then the confirm. False: nothing left,
    /// the card closes.
    public bool GitEscape()
    {
        if (GitPanel.PickerOpen)
        {
            if (GitPanel.RepoMenuOpen)
            {
                UpdateGit(s => s with { RepoMenuOpen = false });
                return true;
            }
            if (GitPanel.FilterFocused || GitPanel.Filter.Length > 0)
            {
                SetGitFilter("");
                SetGitFilterFocused(false);
                return true;
            }
        }
        return CloseGitPicker() || CancelGitCommitForm() || CancelGitConfirm();
    }

    /// What esc does next, for the footer: "close" the dropdown, "clear" the filter, "back"
    /// out of the picker or the commit form, "cancel" the confirm; null when it closes the card.
    public string? GitEscapeLabel
    {
        get
        {
            if (!GitPanel.PickerOpen)
            {
                if (GitDraft.Composing) return "back";
                if (GitPhase is GitPhase.Confirming) return "cancel";
                return null;
            }
            if (GitPanel.RepoMenuOpen) return "close";
            if (GitPanel.FilterFocused || GitPanel.Filter.Length > 0) return "clear";
            return "back";
        }
    }

    /// The Git tool's keys. Null: not a Git key, let the card handle it.
    public bool? HandleGitKey(NotchKey key)
    {
        if (GitPanel.PickerOpen)
        {
            if (GitPanel.RepoMenuOpen)
            {
                switch (key.Kind)
                {
                    case NotchKeyKind.Up or NotchKeyKind.Down:
                        int count = GitPanel.Repos.Count;
                        if (count == 0) return true;
                        int next = Math.Max(0, Math.Min(count - 1, GitPanel.RepoMenuCursor + (key == NotchKey.Up ? -1 : 1)));
                        UpdateGit(s => s with { RepoMenuCursor = next });
                        return true;
                    case NotchKeyKind.Primary:
                        var repos = GitPanel.Repos;
                        if (GitPanel.RepoMenuCursor >= 0 && GitPanel.RepoMenuCursor < repos.Count) ChooseGitRepo(repos[GitPanel.RepoMenuCursor].Id);
                        return true;
                    case NotchKeyKind.Repository:
                        UpdateGit(s => s with { RepoMenuOpen = false });
                        return true;
                    case NotchKeyKind.Worktree:
                        CloseGitPicker();
                        return true;
                    case NotchKeyKind.NextTab or NotchKeyKind.PreviousTab or NotchKeyKind.Number or NotchKeyKind.Settings
                        or NotchKeyKind.Teleport or NotchKeyKind.Escape or NotchKeyKind.Quit:
                        return null;
                    default:
                        return true;     // the dropdown has the keys; nothing under it reacts
                }
            }
            switch (key.Kind)
            {
                case NotchKeyKind.Up or NotchKeyKind.Down:
                    int count = GitPickerRows.Count;
                    if (count == 0) return true;
                    int next = Math.Max(0, Math.Min(count - 1, GitPanel.PickerCursor + (key == NotchKey.Up ? -1 : 1)));
                    UpdateGit(s => s with { PickerCursor = next });
                    return true;
                case NotchKeyKind.Primary:
                    var rows = GitPickerRows;
                    if (GitPanel.PickerCursor >= 0 && GitPanel.PickerCursor < rows.Count) PickGitBranch(rows[GitPanel.PickerCursor]);
                    return true;
                case NotchKeyKind.Worktree:
                    CloseGitPicker();
                    return true;
                case NotchKeyKind.Repository:       // R
                    OpenGitRepoMenu();
                    return true;
                case NotchKeyKind.Filter:           // /
                    if (GitPickerShowsFilter) SetGitFilterFocused(true);
                    return true;
                case NotchKeyKind.MarkdownMode or NotchKeyKind.Left or NotchKeyKind.Right or NotchKeyKind.Copy
                    or NotchKeyKind.Diff or NotchKeyKind.ToggleTree:
                    return true;     // the picker has the keys; nothing under it reacts
                default:
                    return null;
            }
        }
        switch (key.Kind)
        {
            case NotchKeyKind.Worktree:         // W
                OpenGitPicker();
                return true;
            case NotchKeyKind.MarkdownMode:     // P
                PressGitSync();
                return true;
            case NotchKeyKind.Commit:           // C
                OpenGitCommitForm();
                return true;
            case NotchKeyKind.Undo:             // U: not while composing (the refill would replace the draft)
                if (!GitCanUndo || GitDraft.Composing) return null;
                RunGitUndo();
                return true;
            case NotchKeyKind.Toggle:           // space
                if (FocusedGit?.CheckedOut != true || GitSelectedFile is not { } file) return null;
                ToggleGitFile(file.Path);
                return true;
            case NotchKeyKind.Submit:           // Ctrl ⏎
                if (GitDraft.Composing) RunGitCommit();
                return true;
            case NotchKeyKind.Primary:
                // The selected file's diff already shows; ⏎ confirms a sync, or commits from the
                // form when no field has the keys (the summary's own ⏎ commits itself).
                if (GitPhase is GitPhase.Confirming) RunGitSync();
                else if (GitDraft.Composing) RunGitCommit();
                return true;
            case NotchKeyKind.ToggleTree:       // Ctrl B
                ToggleGitList();
                return true;
            case NotchKeyKind.Up or NotchKeyKind.Down:
                // Selecting shows that file's diff at once. The rail stays folded: the stage
                // header names the file.
                int count = GitRows.Count;
                if (count == 0) return false;
                // As a click on a row: the stage shows the diff, the draft keeps its text, a
                // confirm is dropped.
                if (GitDraft.Composing) SetGitComposing(false);
                CancelGitConfirm();
                RowCursor = Math.Max(0, Math.Min(count - 1, RowCursor + (key == NotchKey.Up ? -1 : 1)));
                return true;
            default:
                return null;
        }
    }
}
