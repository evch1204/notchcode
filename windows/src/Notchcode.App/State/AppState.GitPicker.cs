// AppState.GitPicker.cs
// Port of Sources/notchcode/Features/Git/AppState+GitPicker.swift.
// The Git tool's branch picker (W): the repository it lists, its filtered rows, opening
// and closing it, moving its cursor, picking a branch as the target, and the branch
// listing that fills it.

using System.IO;
using Notchcode.App;
using Notchcode.Features.Git;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: Branch picker

    /// The repository the picker lists: the one chosen in the dropdown, else the first.
    public GitRepoGroup? GitPickerGroup
    {
        get
        {
            var repos = GitPanel.Repos;
            return repos.FirstOrDefault(r => r.Id == GitPanel.PickerRepo) ?? repos.FirstOrDefault();
        }
    }

    /// Past `gitPickerFilterMin` branches the filter field shows above the rows.
    public bool GitPickerShowsFilter => (GitPickerGroup?.Branches.Count ?? 0) > Theme.Limits.GitPickerFilterMin;

    /// The chosen repository's branches the filter lets through; `PickerCursor` indexes them.
    public List<GitBranch> GitPickerRows
    {
        get
        {
            var branches = GitPickerGroup?.Branches ?? [];
            var query = GitPanel.Filter.Trim(' ', '\t');
            if (query.Length == 0) return branches.ToList();
            return branches.Where(b => b.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        }
    }

    /// The branch the tool shows is this row: its checkout is the target, or it is the
    /// branch page's branch.
    public bool GitBranchIsCurrent(GitBranch branch, string repo) => GitTarget switch
    {
        GitTarget.Branch b => b.Repo == repo && b.Name == branch.Name,
        GitTarget.Folder => branch.Path is { } path && SamePath(path, FocusedGit?.Root ?? GitCwd),
        _ => false,
    };

    /// The live sessions whose folder is inside `path`'s worktree.
    public List<Session> GitSessions(string worktreePath) =>
        Sessions.Where(s => s.Cwd.Length > 0 && SamePath(GitPanel.RootByCwd.GetValueOrDefault(s.Cwd) ?? s.Cwd, worktreePath)).ToList();

    /// W or the pill: the picker replaces the tool's content, on the target's repository,
    /// the cursor on the target's row.
    public void OpenGitPicker()
    {
        if (!ReadsLocalFiles) return;
        CancelGitConfirm();
        if (GitDraft.Focus is not null) SetGitDraftFocus(null);
        UpdateGit(s => s.ResetPicker(open: true));
        PlaceGitPickerOnTarget();
        RefreshGitWorktrees();
    }

    /// The picker's repository and cursor follow the target.
    private void PlaceGitPickerOnTarget()
    {
        var repos = GitPanel.Repos;
        string? repoId = null;
        switch (GitTarget)
        {
            case GitTarget.Branch b: repoId = b.Repo; break;
            case GitTarget.Folder:
                var root = FocusedGit?.Root ?? GitCwd;
                repoId = repos.FirstOrDefault(r => r.Branches.Any(b => b.Path is { } p && SamePath(p, root)))?.Id;
                break;
        }
        UpdateGit(s => s with { PickerRepo = repoId ?? s.PickerRepo ?? repos.FirstOrDefault()?.Id });
        var repo = GitPickerGroup?.Id ?? "";
        int index = Math.Max(0, GitPickerRows.FindIndex(b => GitBranchIsCurrent(b, repo)));
        UpdateGit(s => s with { PickerCursor = index });
    }

    /// Esc, W again, or the pill while the picker shows. False when it was not open.
    public bool CloseGitPicker()
    {
        if (!GitPanel.PickerOpen) return false;
        UpdateGit(s => s.ResetPicker());
        return true;
    }

    public void ToggleGitPicker()
    {
        if (!CloseGitPicker()) OpenGitPicker();
    }

    /// R or the pill: the repository dropdown, the cursor on the chosen one. Only with more
    /// than one repository; with one the pill is static.
    public void OpenGitRepoMenu()
    {
        var repos = GitPanel.Repos;
        if (repos.Count <= 1) return;
        int current = Math.Max(0, repos.FindIndex(r => r.Id == GitPickerGroup?.Id));
        UpdateGit(s => s with { RepoMenuOpen = !s.RepoMenuOpen, RepoMenuCursor = current, FilterFocused = false });
    }

    public void CloseGitRepoMenu() => UpdateGit(s => s with { RepoMenuOpen = false });

    /// ⏎ or a click in the dropdown: that repository's branches, the filter cleared.
    public void ChooseGitRepo(string id)
    {
        UpdateGit(s => s with { PickerRepo = id, RepoMenuOpen = false, Filter = "", PickerCursor = 0 });
        int index = GitPickerRows.FindIndex(b => GitBranchIsCurrent(b, id));
        if (index >= 0) UpdateGit(s => s with { PickerCursor = index });
    }

    /// Typing in the filter field: the rows narrow and the cursor goes to the first match.
    public void SetGitFilter(string text) => UpdateGit(s => s with { Filter = text, PickerCursor = 0 });

    public void SetGitFilterFocused(bool focused) => UpdateGit(s => s with { FilterFocused = focused });

    /// A click on a row: the cursor goes there first, then it is picked.
    public void PickGitBranch(GitBranch branch)
    {
        if (GitPickerGroup is not { } repo) return;
        GitTarget target = branch.Path is { } path ? new GitTarget.Folder(path) : new GitTarget.Branch(repo.Id, branch.Name);
        UpdateGit(s => s.ResetPicker().DropConfirms() with { Picked = target });
        RowCursor = 0;
        DebugLog.Write("git target picked: " + target.Key);
        RefreshGit(thenFetch: true);
    }

    /// Lists every repository a session runs in, with its local branches, in the background.
    public void RefreshGitWorktrees()
    {
        if (!ReadsLocalFiles || GitPanel.Listing) return;
        var cwds = new List<string>();
        foreach (var session in OrderedSessions)
            if (session.Cwd.Length > 0 && !cwds.Contains(session.Cwd)) cwds.Add(session.Cwd);
        switch (GitPanel.Picked)
        {
            case GitTarget.Folder f: if (!cwds.Contains(f.Path)) cwds.Add(f.Path); break;
            case GitTarget.Branch b: if (!cwds.Contains(b.Repo)) cwds.Add(b.Repo); break;
        }
        UpdateGit(s => s with { Listing = true });
        OffUi(() => GitRunner.ListBranches(cwds), listing => ApplyGitWorktrees(listing.Repos, listing.RootByCwd));
    }

    private void ApplyGitWorktrees(System.Collections.Immutable.ImmutableList<GitRepoGroup> repos,
                                   System.Collections.Immutable.ImmutableDictionary<string, string> rootByCwd)
    {
        var before = GitPickerRows;
        var cursorName = GitPanel.PickerCursor >= 0 && GitPanel.PickerCursor < before.Count ? before[GitPanel.PickerCursor].Name : null;
        bool hadRepo = GitPanel.PickerRepo is { } pickerRepo && GitPanel.Repos.Any(r => r.Id == pickerRepo);
        UpdateGit(s => s with { Listing = false, Repos = repos, RootByCwd = s.RootByCwd.SetItems(rootByCwd) });
        if (hadRepo && GitPanel.PickerRepo is { } id && repos.Any(r => r.Id == id))
        {
            // A refresh while the picker shows: the cursor stays on its branch.
            var rows = GitPickerRows;
            int index = cursorName is null ? -1 : rows.FindIndex(b => b.Name == cursorName);
            if (index >= 0) UpdateGit(s => s with { PickerCursor = index });
            else UpdateGit(s => s with { PickerCursor = Math.Min(s.PickerCursor, Math.Max(0, rows.Count - 1)) });
        }
        else
        {
            PlaceGitPickerOnTarget();
        }
        DebugLog.Write("git branches: " + string.Join(" ", repos.Select(repo =>
            repo.Name + "[" + string.Join(", ", repo.Branches.Select(branch =>
            {
                var place = branch.Place switch
                {
                    GitPlace.Main => "main",
                    GitPlace.Worktree w => Path.GetFileName(w.Path.TrimEnd('/', '\\')),
                    _ => "-",
                };
                return $"{branch.Name}@{place} u={branch.Uncommitted?.ToString() ?? "-"} a={branch.Ahead?.ToString() ?? "-"}";
            })) + "]")));
    }
}
