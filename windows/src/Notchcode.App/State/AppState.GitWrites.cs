// AppState.GitWrites.cs
// Port of Sources/notchcode/Features/Git/AppState+GitWrites.swift.
// Everything the Git tool writes, all through one phase per target so two writes never run
// at once: the sync pill (publish, pull, push, fetch), the quiet fetch when the tool opens,
// the commit of the checked files from the form (with its Co-authored-by trailers), and the
// undo of the newest unpushed commit (U, or the dock's receipt). Each runs `git.exe` off
// the UI thread and only from an explicit press, except the quiet fetch, which touches no
// phase and no pill. The draft it commits is in AppState.GitDraft.cs.

using System.Windows.Threading;
using Notchcode.App;
using Notchcode.Features.Git;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: Sync

    /// P or the pill: a fetch runs at once; publish, push and pull ask first in the right
    /// pane. Nothing while a write runs or a sync's result holds: re-arming then would ask
    /// again for the commits just sent. A fetch or pull does nothing while the quiet fetch runs
    /// on the same root (two fetches can fail on git's ref locks); the pill stays enabled and
    /// works again once it lands. The quiet fetch, in turn, waits for an idle phase.
    public void PressGitSync()
    {
        if (GitCwd is not { } cwd || !GitCanSync || GitSyncOp is not { } op || FocusedGit is not { } snap) return;
        if (GitPhase is GitPhase.Confirming) return;
        if (op is GitOp.Fetch or GitOp.Pull && GitPanel.Fetching.Contains(snap.Root)) return;
        if (op == GitOp.Fetch)
        {
            RunGitFetch();
            return;
        }
        // The confirm takes the pane; the form's text stays for later.
        if (GitDraft.Composing) SetGitComposing(false);
        UpdateGit(s => s.SetPhase(new GitPhase.Confirming(op), cwd));
    }

    /// The pill while the confirm shows: the same as ⏎.
    public void PressGitPill()
    {
        if (GitPhase is GitPhase.Confirming) RunGitSync(); else PressGitSync();
    }

    /// Esc while the confirm shows. False when there was nothing to cancel.
    public bool CancelGitConfirm()
    {
        if (GitPhase is not GitPhase.Confirming || GitCwd is not { } cwd) return false;
        UpdateGit(s => s.SetPhase(GitPhase.Idle.Instance, cwd));
        return true;
    }

    /// ⏎ on the confirm. Push: `git push -- <remote> refs/heads/<b>:refs/heads/<upstream branch>`;
    /// publish: `git push -u -- <remote> refs/heads/<b>:refs/heads/<b>`. Full refs on both
    /// sides: a plain `git push` follows push.default and pushRemote (it can go elsewhere, or
    /// push several branches), and a bare name is ambiguous with a tag. The branch, not HEAD: a
    /// checkout that moved between the poll and ⏎ cannot push the wrong head. Pull: `git pull
    /// --ff-only --no-rebase -- <remote> <upstream branch>`, a checkout only: it never merges
    /// or rebases, so a diverged branch is sent to the terminal.
    public void RunGitSync()
    {
        if (GitPhase is not GitPhase.Confirming confirming || !GitCanSync || confirming.Op != GitSyncOp || GitCwd is not { } cwd
            || FocusedGit is not { Branch: { } branch, Remote: { } remote } snap) return;
        var op = confirming.Op;
        var upstreamBranch = snap.UpstreamBranch
            ?? (snap.Upstream is { } up && up.Length > remote.Length ? up[(remote.Length + 1)..] : null)
            ?? branch;
        string[] args;
        string message;
        switch (op)
        {
            case GitOp.Publish:
                args = GitCommands.Publish(remote, branch);
                message = "Published " + branch + " to " + remote;
                break;
            case GitOp.Push:
                args = GitCommands.Push(remote, branch, upstreamBranch);
                message = "Pushed " + Commits(snap.Unpushed);
                break;
            case GitOp.Pull:
                if (!snap.CheckedOut) return;
                args = GitCommands.Pull(remote, upstreamBranch);
                message = "Pulled " + Commits(snap.Behind);
                break;
            default:
                return;
        }
        UpdateGit(s => s.SetPhase(new GitPhase.Running(op), cwd));
        DebugLog.Write($"git {op.Command} in {snap.Root}: {string.Join(" ", args)}");
        OffUi(async () =>
        {
            var result = await GitRunner.RunAsync(args, snap.Root, Theme.Timing.GitSyncTimeout);
            bool ok = result.Status == 0;
            return (ok, ok ? message : GitRunner.ErrorLine(result, remote, op));
        }, r => FinishGitOp(op, r.ok, r.Item2, cwd));
    }

    /// P or the pill offering Fetch: `git fetch --prune -- <remote>` at once, no confirm. The
    /// pill pulses "Fetching"; when nothing came, "Fetched · up to date" holds, else the
    /// fresh read's status and pill say what came.
    private void RunGitFetch()
    {
        if (GitCwd is not { } cwd || FocusedGit is not { Remote: { } remote } snap) return;
        var root = snap.Root;
        UpdateGit(s => s.SetPhase(new GitPhase.Running(GitOp.Fetch), cwd));
        DebugLog.Write($"git fetch in {root}: fetch --prune -- {remote}");
        OffUi(async () =>
        {
            var result = await GitRunner.RunAsync(GitCommands.Fetch(remote), root, Theme.Timing.GitSyncTimeout);
            bool ok = result.Status == 0;
            // git fetch reports each ref it moved; nothing on stderr means nothing came.
            bool unchanged = result.Err.Trim().Length == 0;
            string? message = ok
                ? (unchanged ? "Fetched" + Theme.Glyphs.Separator + "up to date" : null)
                : GitRunner.ErrorLine(result, remote, GitOp.Fetch);
            return (ok, message);
        }, r => FinishGitFetch(root, r.ok, r.message, cwd));
    }

    private void FinishGitFetch(string root, bool ok, string? message, string cwd)
    {
        UpdateGit(s => s with { LastFetch = s.LastFetch.SetItem(root, DateTime.UtcNow) });
        FinishGitOp(GitOp.Fetch, ok, message, cwd);
    }

    // MARK: Quiet fetch

    /// When the tool opens or a branch is picked: the target's remote is fetched in the
    /// background if it was not in the last `gitAutoFetchInterval`, touching neither the phase
    /// nor the pill; the fresh counts then arrive through a poll's read. One at a time per root;
    /// failures are only logged. Only from an idle phase, so it never overlaps a manual fetch
    /// or pull (or a confirm that would become one); `PressGitSync` checks the other way.
    public void GitAutoFetchIfDue()
    {
        // NOTCHCODE_NO_AUTOFETCH=1: a dev run against a repository that must not be fetched.
        if (Environment.GetEnvironmentVariable("NOTCHCODE_NO_AUTOFETCH") == "1") return;
        if (!ReadsLocalFiles || !IsCardOpen || FocusedGit is not { IsRepo: true, Remote: { } remote } snap || snap.Root.Length == 0
            || GitPhase is not GitPhase.Idle) return;
        var root = snap.Root;
        if (GitPanel.Fetching.Contains(root)) return;
        if (GitPanel.LastFetch.TryGetValue(root, out var last) && (DateTime.UtcNow - last).TotalSeconds < Theme.Timing.GitAutoFetchInterval) return;
        UpdateGit(s => s with { Fetching = s.Fetching.Add(root) });
        DebugLog.Write($"git quiet fetch in {root}: fetch --prune -- {remote}");
        OffUi(async () =>
        {
            var result = await GitRunner.RunAsync(GitCommands.Fetch(remote), root, Theme.Timing.GitFetchTimeout);
            return result.Status == 0 ? null : GitRunner.ErrorLine(result, remote, GitOp.Fetch);
        }, error => FinishGitAutoFetch(root, error));
    }

    private void FinishGitAutoFetch(string root, string? error)
    {
        UpdateGit(s => s with { Fetching = s.Fetching.Remove(root), LastFetch = s.LastFetch.SetItem(root, DateTime.UtcNow) });
        DebugLog.Write($"git quiet fetch {(error is null ? "ok" : "failed: " + error)} in {root}");
        RefreshGit(poll: true);
    }

    // MARK: Commit

    /// ⏎ in the summary, Ctrl ⏎ anywhere in the form, or the Commit pill. `git add -- <paths>`
    /// for every checked file but the deleted ones (stages new files), then `git commit --only
    /// --quiet -m <summary> [-m <description>] [-m <trailers>] -- <paths>`, a staged rename
    /// naming its old path too: `--only` commits exactly these paths' working-tree state
    /// (a deletion included) and leaves the rest of the index as it was. Unchecked
    /// files are never touched; the index is never reset. The trailers are one
    /// "Co-authored-by: Name <email>" line per co-author, the message's last paragraph, where
    /// git reads trailers. Then `git log -1` names the commit for the dock's receipt.
    public void RunGitCommit()
    {
        if (!GitCanCommit || GitCwd is not { } cwd || FocusedGit is not { CheckedOut: true } snap) return;
        var summary = GitCommitSummary;
        var description = GitDraft.Description.Trim();
        var trailers = string.Join("\n", GitDraft.Coauthors.Select(c => GitCoauthorTrailer + " " + c));
        var checkedFiles = GitCheckedFiles;
        // A staged rename is two paths: the commit takes the old one's removal with the new one.
        var paths = checkedFiles.SelectMany(f => f.RenamedFrom is { } from ? new[] { f.Path, from } : [f.Path]).ToList();
        // `git add` refuses a path in neither the work tree nor the index (a staged deletion, a
        // rename's old name), and needs none for a deletion: `--only` commits it as it is.
        var adds = checkedFiles.Where(f => f.Kind != "deleted").Select(f => f.Path).ToList();
        var remote = snap.Remote ?? "";
        UpdateGit(s => s.SetPhase(new GitPhase.Running(GitOp.Commit), cwd));
        var args = GitCommands.Commit(summary, description, trailers, paths);
        DebugLog.Write($"git commit in {snap.Root}: {checkedFiles.Count} files, summary \"{summary}\"");
        OffUi<(bool Ok, string Message, GitReceipt? Receipt)>(async () =>
        {
            if (adds.Count > 0)
            {
                var add = await GitRunner.RunAsync(GitCommands.Add(adds), snap.Root, Theme.Timing.GitCommitTimeout);
                if (add.Status != 0) return (false, GitRunner.ErrorLine(add, remote, GitOp.Commit), null);
            }
            var result = await GitRunner.RunAsync(args, snap.Root, Theme.Timing.GitCommitTimeout);
            bool ok = result.Status == 0;
            var message = ok ? "Committed " + Format.Files(checkedFiles.Count) : GitRunner.ErrorLine(result, remote, GitOp.Commit);
            GitReceipt? receipt = null;
            if (ok)
            {
                var head = await GitRunner.RunAsync(["log", "-1", "--format=%h%x1f%s"], snap.Root);
                var parts = head.Out.Trim().Split('\u001f', 2);
                if (head.Status == 0 && parts.Length == 2) receipt = new GitReceipt(parts[0], parts[1]);
            }
            return (ok, message, receipt);
        }, r => FinishGitCommit(r.Ok, r.Message, r.Receipt, cwd));
    }

    /// "Co-authored-by:", the trailer's key.
    public const string GitCoauthorTrailer = "Co-authored-by:";

    /// A commit's end: on success the draft goes (text, co-authors, checks, form), the receipt
    /// takes the dock, and the cursor goes to the top; on failure the form stays with its text
    /// and says why.
    private void FinishGitCommit(bool ok, string message, GitReceipt? receipt, string cwd)
    {
        if (ok)
        {
            UpdateGit(s => s with { Drafts = s.Drafts.SetItem(cwd, new GitDraft { Receipt = receipt }) });
            if (GitCwd == cwd) RowCursor = 0;
        }
        FinishGitOp(GitOp.Commit, ok, message, cwd);
    }

    /// The dock's receipt while it still names the newest commit and that commit is not pushed.
    /// While the commit's result holds, the snapshot may not have caught up yet, so it shows.
    public GitReceipt? GitReceipt
    {
        get
        {
            var draft = GitDraft;
            if (draft.Receipt is not { } receipt || draft.Composing || FocusedGit is not { CheckedOut: true } snap) return null;
            if (GitPhase is GitPhase.Done { Op: GitOp.Commit }) return receipt;
            if (snap.Commits.FirstOrDefault() is not { } newest || newest.Sha != receipt.Sha || newest.Pushed) return null;
            return receipt;
        }
    }

    // MARK: Undo

    /// U or the receipt's Undo: a checkout whose newest commit is not on the remote and has a
    /// parent, with no write running or holding, except a commit's own result: undo is most
    /// wanted then, and the reset acts on the real HEAD, the commit just made.
    public bool GitCanUndo
    {
        get
        {
            if (FocusedGit is not { IsRepo: true, CheckedOut: true, HeadHasParent: true } snap
                || snap.Commits.FirstOrDefault() is not { Pushed: false }) return false;
            return GitPhase switch
            {
                GitPhase.Idle or GitPhase.Failed => true,
                GitPhase.Done d => d.Op == GitOp.Commit,
                _ => false,
            };
        }
    }

    /// No confirm: `git log -1 --format=%B`, then `git reset --quiet HEAD~1` (mixed), which
    /// loses nothing: the commit's changes come back to the rail and its message refills the
    /// form (co-authors from its trailers), as GitHub Desktop does. The reset happens only while
    /// HEAD is still the commit the card shows; else the undo fails with "HEAD moved" and the
    /// failure's read brings the card up to date.
    public void RunGitUndo()
    {
        if (!GitCanUndo || GitCwd is not { } cwd || FocusedGit is not { } snap || snap.Commits.FirstOrDefault()?.Sha is not { } expected) return;
        var remote = snap.Remote ?? "";
        UpdateGit(s => s.SetPhase(new GitPhase.Running(GitOp.Undo), cwd));
        DebugLog.Write($"git reset in {snap.Root}: reset --quiet HEAD~1 (undo {expected})");
        OffUi<(bool Ok, string Text)>(async () =>
        {
            var log = await GitRunner.RunAsync(["log", "-1", "--format=%B"], snap.Root);
            if (log.Status != 0) return (false, GitRunner.ErrorLine(log, remote, GitOp.Undo));
            // `%h` is short: the full sha must start with it.
            var head = await GitRunner.RunAsync(["rev-parse", "--verify", "HEAD"], snap.Root);
            if (head.Status != 0 || !head.Out.Trim().StartsWith(expected, StringComparison.Ordinal))
                return (false, "HEAD moved; refresh and try again");
            var reset = await GitRunner.RunAsync(GitCommands.Reset(), snap.Root);
            bool ok = reset.Status == 0;
            return (ok, ok ? log.Out : GitRunner.ErrorLine(reset, remote, GitOp.Undo));
        }, r => FinishGitUndo(r.Ok, r.Text, cwd));
    }

    /// `text`: the undone commit's message on success, else the error line.
    private void FinishGitUndo(bool ok, string text, string cwd)
    {
        if (!ok)
        {
            FinishGitOp(GitOp.Undo, false, text, cwd);
            return;
        }
        // Co-authored-by lines come back as chips; the rest is the summary and description.
        var coauthors = new List<string>();
        var kept = new List<string>();
        foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
        {
            var trimmedLine = line.Trim(' ', '\t');
            if (trimmedLine.StartsWith(GitCoauthorTrailer, StringComparison.OrdinalIgnoreCase))
            {
                var value = trimmedLine[GitCoauthorTrailer.Length..].Trim(' ', '\t');
                if (value.Length > 0) coauthors.Add(value);
            }
            else
            {
                kept.Add(line);
            }
        }
        var message = string.Join("\n", kept).Trim();
        var lines = message.Split('\n', 2);
        var subject = lines[0];
        var body = lines.Length > 1 ? lines[1].Trim() : "";
        UpdateGit(s => s with
        {
            Drafts = s.Drafts.SetItem(cwd, new GitDraft
            {
                Summary = subject,
                Description = body,
                Composing = true,
                Focus = GitDraftFocus.Summary,
                Coauthors = [.. coauthors],
                CoauthorsShown = coauthors.Count > 0,
            }),
        });
        if (GitCwd == cwd) RowCursor = 0;
        var shortSubject = subject.Length > Theme.Limits.GitUndoSubject
            ? subject[..Theme.Limits.GitUndoSubject] + Theme.Glyphs.Ellipsis
            : subject;
        FinishGitOp(GitOp.Undo, true, "Undid \"" + shortSubject + "\"", cwd);
    }

    // MARK: Result

    /// Every write's end. `message` null (a fetch that brought something): straight back to
    /// idle, the fresh read speaks. Else the result holds `gitResultHold`, an error until a
    /// refresh other than the poll. The result is kept on `cwd`, its own target, even when
    /// another one shows by now; a read for the target on screen then counts as a poll, so it
    /// leaves that target's error alone.
    public void FinishGitOp(GitOp op, bool ok, string? message, string cwd)
    {
        DebugLog.Write($"git {op.Command} {(ok ? "ok" : "failed")}: {message ?? "-"}");
        bool shown = GitCwd == cwd;
        if (message is null)
        {
            UpdateGit(s => s.SetPhase(GitPhase.Idle.Instance, cwd));
            RefreshGit(poll: !shown);
            return;
        }
        UpdateGit(s => s.SetPhase(ok ? new GitPhase.Done(op, message) : new GitPhase.Failed(op, message), cwd));
        if (!ok)
        {
            // The counts may have moved (a partial push); the error stays.
            RefreshGit(poll: true);
            return;
        }
        // Read at once so the pill and the counts stop offering what was just sent.
        RefreshGit(poll: !shown);
        // After the hold, the result gives way to the status; the second read is a safety net
        // for when the first was skipped because a poll's read was in flight.
        if (GitHoldTasks.TryGetValue(cwd, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        GitHoldTasks[cwd] = cts;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.GitResultHold) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (cts.IsCancellationRequested) return;
            if (GitPanel.Phases.GetValueOrDefault(cwd) is GitPhase.Done)
                UpdateGit(s => s.SetPhase(GitPhase.Idle.Instance, cwd));
            if (GitHoldTasks.GetValueOrDefault(cwd) == cts) GitHoldTasks.Remove(cwd);
            RefreshGit(poll: GitCwd != cwd);
        };
        timer.Start();
    }
}
