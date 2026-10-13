// GitRunner.cs
// Port of Sources/notchcode/Features/Git/GitRunner.swift.
// Runs `git.exe` for the Git tool and parses what it prints: status, ahead and behind, the
// newest commit, recent co-authors, branches and worktrees, and the writes: push, pull, fetch,
// commit and the undo's reset. Off the UI thread, with GIT_OPTIONAL_LOCKS=0; the writes run
// only from `AppState`'s explicit presses (and the quiet fetch), never from a read.

using System.Collections.Immutable;
using System.IO;
using System.Text;
using Notchcode.UI;

namespace Notchcode.Features.Git;

/// `git.exe -C <dir>`, through `ProcessRunner` (stdin closed, both outputs drained, the
/// process tree killed past the timeout after `processKillGrace` for its output).
public static class GitRunner
{
    /// Git for Windows' `git.exe`: the first on PATH (absolute folders only, so a relative
    /// entry such as "." can never pick up a git.exe from the repository being read), else
    /// its default install.
    public static string GitExecutable => gitExecutable.Value;
    private static readonly Lazy<string> gitExecutable = new(() =>
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var folder = dir.Trim().Trim('"');
                if (!Path.IsPathFullyQualified(folder)) continue;
                var candidate = Path.Combine(folder, "git.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return @"C:\Program Files\Git\cmd\git.exe";
    });

    /// The environment every git run gets on top of the app's own.
    public static readonly IReadOnlyDictionary<string, string?> GitEnvironment = new Dictionary<string, string?>
    {
        ["GIT_OPTIONAL_LOCKS"] = "0",
        // No prompt can be answered from a notch: fail instead of waiting on one.
        ["GIT_TERMINAL_PROMPT"] = "0",
        // Git Credential Manager would open its own window; a notch cannot host it either.
        ["GCM_INTERACTIVE"] = "Never",
        // Nor an askpass helper (core.askPass, SSH_ASKPASS): an empty GIT_ASKPASS turns them all off.
        ["GIT_ASKPASS"] = "",
        ["SSH_ASKPASS_REQUIRE"] = "never",
        // A pull never merges, but if git ever wanted a merge message it must not open an editor.
        ["GIT_MERGE_AUTOEDIT"] = "no",
        ["LC_ALL"] = "C",
        // Paths from `git status` come back as pathspecs: `app/[id]/page.tsx` must not glob to `app/i/page.tsx`.
        ["GIT_LITERAL_PATHSPECS"] = "1",
    };

    /// What `git.exe` is given for `args` in `cwd`: `-C <cwd> -c core.quotePath=false`, then the args.
    public static List<string> Arguments(IEnumerable<string> args, string cwd) => ["-C", cwd, "-c", "core.quotePath=false", .. args];

    /// Every git run goes through here: `ProcessRunner` (no shell, stdin closed, the process
    /// tree killed past `timeout`).
    public static Task<ProcessRunner.Result> RunAsync(IEnumerable<string> args, string cwd, double timeout = Theme.Timing.GitReadTimeout)
        => ProcessRunner.RunAsync(GitExecutable, Arguments(args, cwd), environment: GitEnvironment, timeout: timeout);

    private static string Trimmed(string text) => text.Trim();

    private static List<string> Lines(string text) =>
        text.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0).ToList();

    /// Everything the tool shows about `cwd`'s worktree.
    public static async Task<GitSnapshot> Read(string cwd)
    {
        var top = await RunAsync(["rev-parse", "--show-toplevel"], cwd);
        var root = Trimmed(top.Out);
        if (top.Status != 0 || root.Length == 0) return new GitSnapshot { Cwd = cwd, IsRepo = false };
        var snap = new GitSnapshot { Cwd = cwd, IsRepo = true, Root = root };
        var common = await RunAsync(["rev-parse", "--path-format=absolute", "--git-common-dir"], root);
        if (common.Status == 0) snap = snap with { RepoName = GitDir.RepoNameFromCommonDir(Trimmed(common.Out)) };

        var head = await RunAsync(["rev-parse", "--abbrev-ref", "HEAD"], root);
        if (head.Status == 0)
        {
            var name = Trimmed(head.Out);
            snap = snap with { Branch = name == "HEAD" || name.Length == 0 ? null : name };
        }
        else
        {
            // No commit yet: the branch still has a name.
            var unborn = await RunAsync(["symbolic-ref", "--short", "HEAD"], root);
            if (unborn.Status == 0 && Trimmed(unborn.Out).Length > 0) snap = snap with { Branch = Trimmed(unborn.Out) };
        }

        var remotes = Lines((await RunAsync(["remote"], root)).Out);
        snap = await ResolveUpstream(snap, "@{u}", snap.Branch, remotes, root);
        if (snap.Upstream is not null || snap.Branch is not null)
            snap = await CountUnpushed(snap, snap.Upstream is null ? null : "@{u}", "HEAD", remotes, root);

        // Uncommitted files: the same commands the hook's tree report runs.
        var status = await RunAsync(["status", "--porcelain=v1", "--untracked-files=all"], root);
        var entries = UnifiedDiff.Status(status.Out.Split('\n').Select(l => l.TrimEnd('\r')));
        var diffText = new StringBuilder((await RunAsync(["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-renames",
            "--src-prefix=a/", "--dst-prefix=b/"], root)).Out);
        foreach (var entry in entries.Where(e => e.Code == "??").Take(Theme.Limits.GitUntrackedDiffs))
        {
            // Exit 1 means "they differ", which is the point. NUL is Windows' /dev/null.
            var created = await RunAsync(["diff", "--no-index", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
                "--", "NUL", entry.Path], root);
            if (diffText.Length > 0 && diffText[^1] != '\n') diffText.Append('\n');
            diffText.Append(DevNull(created.Out, entry.Path));
        }
        var byPath = new Dictionary<string, FileDiff>();
        foreach (var diff in UnifiedDiff.Parse(diffText.ToString())) byPath.TryAdd(diff.Path, diff);
        var seen = new HashSet<string>();
        var files = ImmutableList.CreateBuilder<FileChange>();
        foreach (var entry in entries)
        {
            if (!seen.Add(entry.Path)) continue;
            var file = FileChangeOf(entry.Path, Kind(entry.Code), byPath.GetValueOrDefault(entry.Path)) with { RenamedFrom = entry.RenamedFrom };
            files.Add(file);
        }
        snap = snap with { Files = files.ToImmutable() };
        var counts = ImmutableDictionary.CreateBuilder<string, int>();
        foreach (var file in snap.Files.Take(Theme.Limits.GitLineCountFiles).Where(f => f.Kind != "deleted"))
        {
            // Regular files only: a device or a pipe would block the read.
            using var handle = RegularFile.Open(Path.Combine(root, file.Path), Theme.Limits.GitOutputBytes);
            if (handle is null) continue;
            var data = new byte[Math.Min(handle.Length, Theme.Limits.GitOutputBytes)];
            int read = 0;
            try
            {
                while (read < data.Length)
                {
                    int n = await handle.ReadAsync(data.AsMemory(read));
                    if (n <= 0) break;
                    read += n;
                }
            }
            catch (IOException) { continue; }
            counts[file.Path] = LineCount(data.AsSpan(0, read));
        }
        snap = snap with { LineCounts = counts.ToImmutable() };

        snap = snap with { Commits = await RecentCommits([], snap.Unpushed, root) };
        // Undo resets to HEAD~1, which the root commit does not have.
        snap = snap with { HeadHasParent = (await RunAsync(["rev-parse", "--verify", "--quiet", "HEAD~1"], root)).Status == 0 };
        snap = snap with { RecentCoauthors = await RecentCoauthors(root) };
        return snap;
    }

    /// A no-index diff against NUL with Windows' name for it rewritten to /dev/null (Git for
    /// Windows usually prints /dev/null already), so one parser reads both platforms.
    private static string DevNull(string diff, string path)
    {
        if (!diff.Contains("NUL", StringComparison.Ordinal)) return diff;
        var lines = diff.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].TrimEnd('\r');
            if (line is "--- a/NUL" or "--- NUL") lines[i] = "--- /dev/null";
            else if (line.StartsWith("diff --git a/NUL ", StringComparison.Ordinal)) lines[i] = "diff --git a/" + path + " b/" + path;
            else if (line.StartsWith("@@", StringComparison.Ordinal)) break;
        }
        return string.Join('\n', lines);
    }

    /// The co-author suggestions: every Co-authored-by trailer value of the last
    /// `gitCoauthorLog` commits, trimmed, newest first, each once (case-insensitively), at most
    /// `gitCoauthorHistory`.
    private static async Task<ImmutableList<string>> RecentCoauthors(string root)
    {
        var log = await RunAsync(["log", $"-{Theme.Limits.GitCoauthorLog}",
            "--format=%(trailers:key=Co-authored-by,valueonly,separator=%x1f)"], root);
        if (log.Status != 0) return [];
        var seen = new HashSet<string>();
        var names = ImmutableList.CreateBuilder<string>();
        foreach (var part in log.Out.Split(['\u001f', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var value = Trimmed(part);
            if (value.Length == 0 || !seen.Add(value.ToLowerInvariant())) continue;
            names.Add(value);
            if (names.Count == Theme.Limits.GitCoauthorHistory) break;
        }
        return names.ToImmutable();
    }

    /// The upstream `spec` names ("@{u}", or "<branch>@{u}") and the remote a push goes to:
    /// the upstream's, else origin, else the first; with an upstream, the exact push target.
    private static async Task<GitSnapshot> ResolveUpstream(GitSnapshot snap, string spec, string? branch, List<string> remotes, string root)
    {
        var upstream = await RunAsync(["rev-parse", "--abbrev-ref", spec], root);
        if (upstream.Status == 0 && Trimmed(upstream.Out).Length > 0) snap = snap with { Upstream = Trimmed(upstream.Out) };
        if (snap.Upstream is { } up && remotes.FirstOrDefault(r => up.StartsWith(r + "/", StringComparison.Ordinal)) is { } owner)
            snap = snap with { Remote = owner };
        else
            snap = snap with { Remote = remotes.Contains("origin") ? "origin" : remotes.FirstOrDefault() };
        if (snap.Upstream is not null && branch is not null) snap = await ResolvePushTarget(snap, branch, root);
        return snap;
    }

    /// What a push would send from `reference`: behind and ahead of `upstream`, or without one
    /// the commits on no remote.
    private static async Task<GitSnapshot> CountUnpushed(GitSnapshot snap, string? upstream, string reference, List<string> remotes, string root)
    {
        if (upstream is not null)
        {
            // "<behind>\t<ahead>": left is the upstream, right is the ref.
            var counts = Trimmed((await RunAsync(["rev-list", "--left-right", "--count", upstream + "..." + reference], root)).Out)
                .Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries);
            if (counts.Length == 2)
            {
                snap = snap with
                {
                    Behind = int.TryParse(counts[0], out var b) ? b : 0,
                    Ahead = int.TryParse(counts[1], out var a) ? a : 0,
                };
            }
            return snap with { Unpushed = snap.Ahead };
        }
        string[] args = remotes.Count == 0
            ? ["rev-list", "--count", reference]
            : ["rev-list", "--count", reference, "--not", "--remotes"];
        return snap with { Unpushed = int.TryParse(Trimmed((await RunAsync(args, root)).Out), out var n) ? n : 0 };
    }

    /// A file of the list with its parsed diff; counts are 0 without one.
    private static FileChange FileChangeOf(string path, string kind, FileDiff? diff) => new()
    {
        Path = path,
        Added = diff?.Added ?? 0,
        Removed = diff?.Removed ?? 0,
        Kind = kind,
        Patch = diff?.Lines ?? [],
        PatchTruncated = diff?.Truncated ?? false,
    };

    /// The last `gitRecentCommits` commits (of `range`, else HEAD's), the newest `unpushed` of
    /// them marked as not pushed.
    private static async Task<ImmutableList<GitCommit>> RecentCommits(string[] range, int unpushed, string root)
    {
        var log = await RunAsync(["log", $"-{Theme.Limits.GitRecentCommits}", "--format=%h%x1f%s%x1f%ct", .. range], root);
        if (log.Status != 0) return [];
        var commits = ImmutableList.CreateBuilder<GitCommit>();
        foreach (var (line, index) in Lines(log.Out).Select((l, i) => (l, i)))
        {
            var parts = line.Split('\u001f');
            if (parts.Length != 3) continue;
            commits.Add(new GitCommit
            {
                Sha = parts[0],
                Subject = parts[1],
                Date = DateTime.UnixEpoch.AddSeconds(double.TryParse(parts[2], out var t) ? t : 0),
                Pushed = index >= unpushed,
            });
        }
        return commits.ToImmutable();
    }

    /// The upstream as git's config names it (`branch.<b>.remote` and `.merge`), so the push
    /// can name the exact remote and branch the confirm shows: `upstream` alone is the
    /// remote-tracking ref, which a custom fetch refspec can name differently.
    private static async Task<GitSnapshot> ResolvePushTarget(GitSnapshot snap, string branch, string root)
    {
        var reference = await RunAsync(["for-each-ref", "--format=%(upstream:remotename)%1f%(upstream:remoteref)",
            "refs/heads/" + branch], root);
        var parts = Trimmed(reference.Out).Split('\u001f');
        if (reference.Status != 0 || parts.Length != 2 || parts[0].Length == 0 || !parts[1].StartsWith("refs/heads/", StringComparison.Ordinal)) return snap;
        return snap with { Remote = parts[0], UpstreamBranch = parts[1]["refs/heads/".Length..] };
    }

    /// "new" for an untracked or added file, "renamed" for a staged rename, "deleted", else
    /// "edit"; the diff pane's badge reads A, R, D or M from it.
    private static string Kind(string code)
    {
        if (code == "??") return "new";
        if (code.Contains('R')) return "renamed";
        if (code.Contains('A')) return "new";
        if (code.Contains('D')) return "deleted";
        return "edit";
    }

    /// Lines in a file's bytes: its newlines, plus one for a last line without one.
    private static int LineCount(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty) return 0;
        int newlines = 0;
        foreach (var b in data) if (b == 0x0A) newlines++;
        return data[^1] == 0x0A ? newlines : newlines + 1;
    }

    /// "main" when the repository has it, else "master", else null.
    private static async Task<string?> DefaultBranch(string root)
    {
        foreach (var name in new[] { "main", "master" })
            if ((await RunAsync(["show-ref", "--verify", "--quiet", "refs/heads/" + name], root)).Status == 0) return name;
        return null;
    }

    /// A branch checked out nowhere, read from the repository's main folder: its changes
    /// against its upstream (else the default branch) with `git diff base...branch`, the
    /// commits `base..branch`, and what a push would send. Nothing is checked out.
    public static async Task<GitSnapshot> ReadBranch(string repo, string name, string key)
    {
        var reference = "refs/heads/" + name;
        if ((await RunAsync(["show-ref", "--verify", "--quiet", reference], repo)).Status != 0)
            return new GitSnapshot { Cwd = key, IsRepo = false };
        var snap = new GitSnapshot { Cwd = key, IsRepo = true, Root = repo, CheckedOut = false, Branch = name };
        var common = await RunAsync(["rev-parse", "--path-format=absolute", "--git-common-dir"], repo);
        if (common.Status == 0) snap = snap with { RepoName = GitDir.RepoNameFromCommonDir(Trimmed(common.Out)) };

        var remotes = Lines((await RunAsync(["remote"], repo)).Out);
        snap = await ResolveUpstream(snap, name + "@{u}", name, remotes, repo);
        snap = await CountUnpushed(snap, snap.Upstream, reference, remotes, repo);
        if (snap.Upstream is { } up) snap = snap with { Base = up };
        else if (await DefaultBranch(repo) is { } main && main != name) snap = snap with { Base = main };

        if (snap.Base is not { } baseRef) return snap;
        snap = snap with
        {
            BaseAhead = int.TryParse(Trimmed((await RunAsync(["rev-list", "--count", baseRef + ".." + reference], repo)).Out), out var ahead) ? ahead : 0,
        };

        // Changes vs the base, with the hook's flags so one parser reads them: the counts and
        // the kinds (from the mode lines) come with the lines.
        var patch = await RunAsync(["diff", "-p", "--no-color", "--no-ext-diff", "--no-renames",
            "--src-prefix=a/", "--dst-prefix=b/", baseRef + "..." + reference], repo);
        var seen = new HashSet<string>();
        var files = ImmutableList.CreateBuilder<FileChange>();
        foreach (var diff in UnifiedDiff.Parse(patch.Out))
        {
            if (!seen.Add(diff.Path)) continue;
            files.Add(FileChangeOf(diff.Path, diff.Kind ?? "edit", diff));
        }
        snap = snap with { Files = files.ToImmutable() };
        var counts = ImmutableDictionary.CreateBuilder<string, int>();
        foreach (var file in snap.Files.Take(Theme.Limits.GitLineCountFiles).Where(f => f.Kind != "deleted"))
        {
            var blob = await RunAsync(["cat-file", "blob", reference + ":" + file.Path], repo);
            if (blob.Status == 0) counts[file.Path] = LineCount(Encoding.UTF8.GetBytes(blob.Out));
        }
        snap = snap with { LineCounts = counts.ToImmutable() };

        snap = snap with { Commits = await RecentCommits([baseRef + ".." + reference], snap.Unpushed, repo) };
        return snap;
    }

    /// Every repository the folders belong to, with its local branches: the newest
    /// `gitPickerBranches` by last commit (`for-each-ref --sort=-committerdate refs/heads`)
    /// and every checked-out one besides, each placed by `git worktree list --porcelain`
    /// (main checkout, a worktree, or nowhere), with its uncommitted files (checkouts only)
    /// and the commits it is ahead of its upstream, or of the default branch without one.
    /// Repositories in the order the folders come, each listed once.
    public static async Task<(ImmutableList<GitRepoGroup> Repos, ImmutableDictionary<string, string> RootByCwd)> ListBranches(IReadOnlyList<string> cwds)
    {
        var repos = ImmutableList.CreateBuilder<GitRepoGroup>();
        var rootByCwd = ImmutableDictionary.CreateBuilder<string, string>();
        var seenRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var cwd in cwds)
        {
            var top = await RunAsync(["rev-parse", "--show-toplevel"], cwd);
            var root = Trimmed(top.Out);
            if (top.Status != 0 || root.Length == 0) continue;
            rootByCwd[cwd] = root;
            if (seenRoots.Contains(root)) continue;
            var list = await RunAsync(["worktree", "list", "--porcelain"], root);
            if (list.Status != 0) continue;
            var entries = WorktreeEntries(list.Out);
            if (entries.Count == 0) continue;
            var main = entries[0];
            foreach (var entry in entries) seenRoots.Add(entry.Path);
            if (repos.Any(r => r.Id == main.Path)) continue;
            var last = Path.GetFileName(main.Path.TrimEnd('/', '\\'));
            string name = main.Bare && last.EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? last[..^4] : last;

            // Branch -> the folder it is checked out in; the first entry is the main one.
            var checkouts = new Dictionary<string, GitPlace>();
            for (int index = 0; index < entries.Count; index++)
            {
                var entry = entries[index];
                if (entry.Bare || entry.Branch is not { } branchName || !Directory.Exists(entry.Path)) continue;
                checkouts[branchName] = index == 0 ? new GitPlace.Main(entry.Path) : new GitPlace.Worktree(entry.Path);
            }
            var defaultName = await DefaultBranch(root);

            var refs = await RunAsync(["for-each-ref", "--sort=-committerdate",
                "--format=%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)", "refs/heads"], root);
            var branches = ImmutableList.CreateBuilder<GitBranch>();
            foreach (var (line, index) in Lines(refs.Out).Select((l, i) => (l, i)))
            {
                var parts = line.Split('\u001f');
                if (parts.Length != 3) continue;
                var place = checkouts.GetValueOrDefault(parts[0]) ?? GitPlace.Nowhere.Instance;
                if (index >= Theme.Limits.GitPickerBranches && place is GitPlace.Nowhere) continue;
                var branch = new GitBranch
                {
                    Name = parts[0],
                    Upstream = parts[1].Length == 0 ? null : parts[1],
                    Date = DateTime.UnixEpoch.AddSeconds(double.TryParse(parts[2], out var t) ? t : 0),
                    Place = place,
                };
                if (branch.Path is { } path)
                {
                    var status = await RunAsync(["status", "--porcelain=v1", "--untracked-files=all"], path);
                    branch = branch with { Uncommitted = status.Status == 0 ? Lines(status.Out).Count : null };
                }
                var reference = "refs/heads/" + branch.Name;
                string? baseRef = branch.Upstream is { } upstream ? upstream
                    : defaultName is not null && defaultName != branch.Name ? "refs/heads/" + defaultName
                    : null;
                if (baseRef is not null)
                {
                    var count = await RunAsync(["rev-list", "--count", baseRef + ".." + reference], root);
                    branch = branch with { Ahead = count.Status == 0 && int.TryParse(Trimmed(count.Out), out var a) ? a : null };
                }
                branches.Add(branch);
            }
            if (branches.Count > 0)
                repos.Add(new GitRepoGroup { Id = main.Path, Name = name, DefaultBranch = defaultName, Branches = branches.ToImmutable() });
        }
        return (repos.ToImmutable(), rootByCwd.ToImmutable());
    }

    /// The blocks of `git worktree list --porcelain`: "worktree <path>", then "branch
    /// refs/heads/<name>", "detached" or "bare", separated by a blank line.
    private static List<(string Path, string? Branch, bool Bare)> WorktreeEntries(string text)
    {
        var entries = new List<(string, string?, bool)>();
        foreach (var block in text.Replace("\r\n", "\n").Split("\n\n"))
        {
            string? path = null, branch = null;
            bool bare = false;
            foreach (var line in block.Split('\n'))
            {
                if (line.StartsWith("worktree ", StringComparison.Ordinal)) path = line["worktree ".Length..];
                if (line.StartsWith("branch ", StringComparison.Ordinal))
                {
                    var r = line["branch ".Length..];
                    branch = r.StartsWith("refs/heads/", StringComparison.Ordinal) ? r["refs/heads/".Length..] : r;
                }
                if (line == "bare") bare = true;
            }
            if (path is not null) entries.Add((path, branch, bare));
        }
        return entries;
    }

    /// The first useful line of a failed write, for the header (a commit's: the form).
    /// Credential failures say so and point at the terminal, where a prompt can be answered;
    /// a pull that cannot fast-forward, a missing identity and a commit hook say what to do.
    public static string ErrorLine(ProcessRunner.Result result, string remote, GitOp op)
    {
        var command = op.Command;
        var terminal = Theme.Glyphs.Separator + command + " from the terminal";
        if (result.TimedOut) return "git " + command + " took too long" + terminal;
        // A commit hook may print to either stream.
        var all = Lines(result.Err).Concat(op == GitOp.Commit ? Lines(result.Out) : []).Select(Trimmed).ToList();
        string[] credentials = ["could not read Username", "terminal prompts disabled", "Permission denied",
            "Authentication failed", "Host key verification failed", "could not read Password"];
        if (op != GitOp.Commit && all.Any(line => credentials.Any(c => line.Contains(c, StringComparison.Ordinal))))
            return "No credentials for " + remote + " here" + terminal;
        switch (op)
        {
            case GitOp.Pull:
                if (all.Any(l => l.Contains("would be overwritten", StringComparison.Ordinal)))
                    return "Uncommitted changes in the way" + terminal;
                if (all.Any(l => l.Contains("Not possible to fast-forward", StringComparison.Ordinal) || l.Contains("diverged", StringComparison.Ordinal)))
                    return "Pull needs a merge" + terminal;
                break;
            case GitOp.Commit:
                if (all.Any(l => l.Contains("Please tell me who you are", StringComparison.Ordinal) || l.Contains("empty ident", StringComparison.Ordinal)))
                    return "No git identity" + Theme.Glyphs.Separator + "set user.name and user.email in the terminal";
                var hook = all.FirstOrDefault(line =>
                {
                    var lower = line.ToLowerInvariant();
                    return lower.StartsWith("husky", StringComparison.Ordinal) || lower.Contains("pre-commit hook", StringComparison.Ordinal)
                        || (lower.Contains("hook", StringComparison.Ordinal) && lower.Contains("failed", StringComparison.Ordinal));
                });
                if (hook is not null)
                    return "A commit hook said no" + Theme.Glyphs.Separator + (hook.Length > Theme.Limits.GitHookLine ? hook[..Theme.Limits.GitHookLine] : hook);
                break;
        }
        string[] markers = ["fatal:", "error:", "! [rejected]", "! [remote rejected]", "remote: error"];
        var marked = all.FirstOrDefault(line => markers.Any(m => line.Contains(m, StringComparison.Ordinal)));
        var text = marked ?? all.FirstOrDefault(l => !l.StartsWith("hint:", StringComparison.Ordinal) && !l.StartsWith("To ", StringComparison.Ordinal)) ?? "";
        foreach (var prefix in new[] { "fatal: ", "error: " })
            if (text.StartsWith(prefix, StringComparison.Ordinal)) text = text[prefix.Length..];
        return text.Length == 0 ? "git " + command + " failed" : text;
    }
}

/// The argument lists of every write, in one place so a test can pin them (GitRunnerTests).
/// Every user-supplied value (a remote, a path, a message) sits after `--` or behind its own
/// flag (`-m`), so none can be read as an option; branches go as full refs on both sides of a
/// push, so neither push.default nor a tag of the same name can redirect one.
public static class GitCommands
{
    /// `git push -u -- <remote> refs/heads/<b>:refs/heads/<b>`: the first push of a branch.
    public static string[] Publish(string remote, string branch)
    {
        var local = "refs/heads/" + branch;
        return ["push", "-u", "--", remote, local + ":" + local];
    }

    /// `git push -- <remote> refs/heads/<b>:refs/heads/<upstream branch>`.
    public static string[] Push(string remote, string branch, string upstreamBranch)
        => ["push", "--", remote, "refs/heads/" + branch + ":refs/heads/" + upstreamBranch];

    /// `git pull --ff-only --no-rebase -- <remote> <upstream branch>`: never a merge or a rebase.
    public static string[] Pull(string remote, string upstreamBranch)
        => ["pull", "--ff-only", "--no-rebase", "--", remote, upstreamBranch];

    /// `git fetch --prune -- <remote>` (the pill's fetch and the quiet fetch).
    public static string[] Fetch(string remote) => ["fetch", "--prune", "--", remote];

    /// `git add -- <paths>`: stages new files before the commit.
    public static string[] Add(IEnumerable<string> paths) => ["add", "--", .. paths];

    /// `git commit --only --quiet -m <summary> [-m <description>] [-m <trailers>] -- <paths>`.
    public static string[] Commit(string summary, string description, string trailers, IEnumerable<string> paths)
    {
        var args = new List<string> { "commit", "--only", "--quiet", "-m", summary };
        if (description.Length > 0) args.AddRange(["-m", description]);
        if (trailers.Length > 0) args.AddRange(["-m", trailers]);
        args.Add("--");
        args.AddRange(paths);
        return [.. args];
    }

    /// `git reset --quiet HEAD~1`: the undo, a mixed reset that loses nothing.
    public static string[] Reset() => ["reset", "--quiet", "HEAD~1"];
}
