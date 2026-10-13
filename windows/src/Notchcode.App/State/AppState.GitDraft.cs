// AppState.GitDraft.cs
// Port of Sources/notchcode/Features/Git/AppState+GitDraft.swift.
// The Git tool's commit draft, one per target: its summary and description, the
// co-authors (those the target's recent commits named, plus any typed), the checked files,
// and the form built from them (the summary prefill, the Commit button). The commit itself
// runs in AppState.GitWrites.cs.

using System.Text.RegularExpressions;
using Notchcode.App;
using Notchcode.Features.Git;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: Draft

    /// The target's commit draft, or a fresh one.
    public GitDraft GitDraft => GitCwd is { } key ? GitPanel.Drafts.GetValueOrDefault(key) ?? new GitDraft() : new GitDraft();

    public void UpdateGitDraft(Func<GitDraft, GitDraft> change)
    {
        if (GitCwd is not { } key) return;
        UpdateGit(s => s with { Drafts = s.Drafts.SetItem(key, change(s.Drafts.GetValueOrDefault(key) ?? new GitDraft())) });
    }

    /// The files going into the commit, in list order: every file but the unchecked ones.
    public List<FileChange> GitCheckedFiles
    {
        get
        {
            var leftOut = GitDraft.Unchecked;
            return (FocusedGit?.Files ?? []).Where(f => !leftOut.Contains(f.Path)).ToList();
        }
    }

    public bool GitAllChecked => GitCheckedFiles.Count == (FocusedGit?.Files.Count ?? 0);

    public bool GitNoneChecked => GitCheckedFiles.Count == 0;

    public void ToggleGitFile(string path) =>
        UpdateGitDraft(d => d with { Unchecked = d.Unchecked.Contains(path) ? d.Unchecked.Remove(path) : d.Unchecked.Add(path) });

    /// The header's box: all checked → none, else all.
    public void ToggleAllGitFiles()
    {
        var paths = (FocusedGit?.Files ?? []).Select(f => f.Path).ToHashSet();
        bool all = GitAllChecked;
        UpdateGitDraft(d => d with { Unchecked = all ? [.. paths] : [] });
    }

    public void SetGitComposing(bool composing) =>
        UpdateGitDraft(d => d with { Composing = composing, Focus = composing ? d.Focus : null });

    public void SetGitDraftFocus(GitDraftFocus? focus) => UpdateGitDraft(d => d with { Focus = focus });

    public void SetGitSummary(string text) => UpdateGitDraft(d => d with { Summary = text });

    public void SetGitDescription(string text) => UpdateGitDraft(d => d with { Description = text });

    // MARK: Co-authors

    public void SetGitCoauthorText(string text) => UpdateGitDraft(d => d with { CoauthorText = text });

    /// The "@ Co-author" pill: the field and its suggestions show (the field focused) or go.
    public void ToggleGitCoauthors()
    {
        bool shown = !GitDraft.CoauthorsShown;
        UpdateGitDraft(d => d with
        {
            CoauthorsShown = shown,
            Focus = shown ? GitDraftFocus.Coauthor : d.Focus == GitDraftFocus.Coauthor ? null : d.Focus,
        });
    }

    /// The "recent" row: co-authors from the recent commits' trailers matching what is typed
    /// (name or email, case-insensitive), minus the ones already added, at most
    /// `gitCoauthorSuggestions`. The first is the one ⏎ adds with the field empty.
    public List<string> GitCoauthorSuggestions
    {
        get
        {
            var draft = GitDraft;
            var added = draft.Coauthors.Select(c => c.ToLowerInvariant()).ToHashSet();
            var query = draft.CoauthorText.Trim(' ', '\t');
            return (FocusedGit?.RecentCoauthors ?? [])
                .Where(c => !added.Contains(c.ToLowerInvariant()) && (query.Length == 0 || c.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                .Take(Theme.Limits.GitCoauthorSuggestions)
                .ToList();
        }
    }

    /// ⏎ in the co-author field: the typed entry as a chip, or with nothing typed the first
    /// suggestion. An entry git could not use as a trailer shakes the field and stays typed.
    public void AddGitCoauthor()
    {
        var typed = GitDraft.CoauthorText.Trim();
        if (typed.Length == 0)
        {
            if (GitCoauthorSuggestions.FirstOrDefault() is { } first) AddGitCoauthor(first);
            return;
        }
        if (GitCoauthorEntry(typed) is not { } entry)
        {
            UpdateGitDraft(d => d with { CoauthorRejects = d.CoauthorRejects + 1 });
            return;
        }
        AddGitCoauthor(entry);
        SetGitCoauthorText("");
    }

    /// A suggestion's click, or a checked entry: added once.
    public void AddGitCoauthor(string entry) =>
        UpdateGitDraft(d => d.Coauthors.Any(c => string.Equals(c, entry, StringComparison.OrdinalIgnoreCase)) ? d : d with { Coauthors = d.Coauthors.Add(entry) });

    public void RemoveGitCoauthor(string entry) => UpdateGitDraft(d => d with { Coauthors = d.Coauthors.RemoveAll(c => c == entry) });

    /// ⌫ in the empty co-author field takes the last chip.
    public void RemoveLastGitCoauthor() =>
        UpdateGitDraft(d => d.Coauthors.IsEmpty ? d : d with { Coauthors = d.Coauthors.RemoveAt(d.Coauthors.Count - 1) });

    /// "Name <email>" from "Name <email>", "<email>" or "email"; with no name, the email's local
    /// part. Null when there is no email git would accept in a trailer.
    public static string? GitCoauthorEntry(string text)
    {
        const string email = @"([^<>@\s]+@[^<>@\s]+)";
        string[] patterns = [@"^\s*([^<>]*?)\s*<" + email + @">\s*$", @"^\s*()" + email + @"\s*$"];
        foreach (var pattern in patterns)
        {
            var match = Regex.Match(text, pattern);
            if (!match.Success) continue;
            var address = match.Groups[2].Value;
            var name = match.Groups[1].Value.Trim(' ', '\t');
            if (name.Length == 0) name = new string(address.TakeWhile(c => c != '@').ToArray());
            return name + " <" + address + ">";
        }
        return null;
    }

    // MARK: Form

    /// C, a click on the dock, or undo's refill: the dock's field travels into the stage and
    /// becomes the form, the summary focused. Only for a checkout with changed files; C again
    /// while it shows does nothing. A folded rail comes back first (the dock lives in it);
    /// the receipt gives way to the fresh field.
    public void OpenGitCommitForm()
    {
        if (FocusedGit is not { IsRepo: true, CheckedOut: true } snap || snap.Files.IsEmpty || GitDraft.Composing) return;
        CancelGitConfirm();
        if (GitListCollapsed) SetGitRailHidden(false);
        UpdateGitDraft(d => d with { Composing = true, Focus = GitDraftFocus.Summary, Receipt = null });
        DebugLog.Write($"git commit form opened for {snap.Root}: {GitCheckedFiles.Count} of {snap.Files.Count} files checked");
    }

    /// Esc or Cancel: the diff comes back; the text and the checks stay for next time.
    /// False when the form was not up.
    public bool CancelGitCommitForm()
    {
        if (!GitDraft.Composing) return false;
        SetGitComposing(false);
        DebugLog.Write("git commit form closed");
        return true;
    }

    /// A click on a file row: its diff shows at once, over the form or the confirm if one was up.
    public void SelectGitRow(string key)
    {
        SetGitRowCursor(key);
        if (GitDraft.Composing) SetGitComposing(false);
        CancelGitConfirm();
    }

    /// With one file checked, GitHub Desktop's prefill: "Create x", "Rename w to x", "Delete x",
    /// "Update x".
    private string? GitSummaryPrefill
    {
        get
        {
            var checkedFiles = GitCheckedFiles;
            if (checkedFiles.Count != 1) return null;
            var file = checkedFiles[0];
            var name = Format.FileName(file.Path);
            return file.Kind switch
            {
                "new" => "Create " + name,
                "renamed" => "Rename " + Format.FileName(file.RenamedFrom ?? file.Path) + " to " + name,
                "deleted" => "Delete " + name,
                _ => "Update " + name,
            };
        }
    }

    /// The summary field's prompt: the one-file prefill, else "Summary (required)".
    public string GitSummaryPlaceholder => GitSummaryPrefill ?? "Summary (required)";

    /// The summary a commit uses: what was typed, else the one-file prefill.
    public string GitCommitSummary
    {
        get
        {
            var typed = GitDraft.Summary.Trim();
            return typed.Length == 0 ? GitSummaryPrefill ?? "" : typed;
        }
    }

    /// A checkout, at least one checked file, a summary, and no write running or holding.
    public bool GitCanCommit
    {
        get
        {
            if (FocusedGit is not { IsRepo: true, CheckedOut: true }) return false;
            if (GitPhase is not (GitPhase.Idle or GitPhase.Failed)) return false;
            return GitCheckedFiles.Count > 0 && GitCommitSummary.Length > 0;
        }
    }

    /// "Commit 3 files to main".
    public string GitCommitButtonTitle
    {
        get
        {
            var files = "Commit " + Format.Files(GitCheckedFiles.Count);
            return FocusedGit?.Branch is { } branch ? files + " to " + branch : files;
        }
    }
}
