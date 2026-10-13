// GitDir.cs
// Port of Sources/notchcode/Core/GitDir.swift.
// Reads a checkout's git facts straight from its `.git` (no `git` process): the branch
// from HEAD, and the repository's name from its git directory. Shared by the transcript
// reader (sessions) and GitRunner (the Git tool). Windows paths, '/' or '\' separators, and
// worktree `gitdir:` files (Git for Windows writes "gitdir: C:/Users/.../.git/worktrees/x").

using System.IO;

namespace Notchcode.Core;

public static class GitDir
{
    /// The checked-out branch, from HEAD. A detached HEAD gives its short SHA.
    public static string? GitBranch(string cwd)
    {
        if (LocateGit(cwd) is not { } git) return null;
        string head;
        try { head = File.ReadAllText(Path.Combine(git.GitDir, "HEAD")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
        var line = head.Trim();
        const string prefix = "ref: refs/heads/";
        if (line.StartsWith(prefix, StringComparison.Ordinal)) return line[prefix.Length..];
        if (line.StartsWith("ref: ", StringComparison.Ordinal)) return line[5..];
        if (line.Length == 0) return null;
        return line.Length > 7 ? line[..7] : line;   // detached HEAD: short SHA
    }

    /// For a linked worktree, the name of the main repo folder. Null for a plain checkout.
    public static string? RepoName(string cwd)
    {
        if (LocateGit(cwd) is not { IsWorktree: true } git) return null;
        // gitdir looks like <repo>/.git/worktrees/<name>, or <name>.git/worktrees/<name> for a bare repo.
        var parts = Components(git.GitDir);
        int idx = parts.LastIndexOf("worktrees");
        if (idx < 1) return null;
        var gitFolder = parts[idx - 1];
        if (gitFolder == ".git")
        {
            // A ".git" right under the root ("C:\.git") names no folder.
            if (idx < 2 || IsRootComponent(parts[idx - 2], idx - 2)) return null;
        }
        else if (!gitFolder.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }
        return RepoNameFromCommonDir(Join(parts.GetRange(0, idx)));
    }

    /// "notchcode" for "C:\…\notchcode\.git", "tools" for a bare "C:\…\tools.git".
    public static string? RepoNameFromCommonDir(string commonDir)
    {
        if (string.IsNullOrEmpty(commonDir)) return null;
        var parts = Components(commonDir);
        if (parts.Count == 0) return null;
        var last = parts[^1];
        if (last == ".git") return parts.Count >= 2 ? parts[^2] : null;
        if (last.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) return last[..^4];
        return last;
    }

    private readonly record struct GitLocation(string GitDir, bool IsWorktree);

    /// Walks up from cwd to the first `.git`. A directory is a plain checkout; a file
    /// (`gitdir: <path>`) is a linked worktree or a submodule.
    private static GitLocation? LocateGit(string cwd)
    {
        if (string.IsNullOrEmpty(cwd)) return null;
        string dir;
        try { dir = Path.GetFullPath(cwd); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
        for (int i = 0; i < 64; i++)
        {
            var dotGit = Path.Combine(dir, ".git");
            if (Directory.Exists(dotGit)) return new GitLocation(dotGit, false);
            if (File.Exists(dotGit))
            {
                string text;
                try { text = File.ReadAllText(dotGit); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
                foreach (var raw in text.SplitLines(omittingEmptySubsequences: true))
                {
                    var line = raw.Trim();
                    if (!line.StartsWith("gitdir:", StringComparison.Ordinal)) continue;
                    var p = line["gitdir:".Length..].Trim();
                    string gitDir;
                    try
                    {
                        gitDir = Path.GetFullPath(Path.IsPathRooted(p) ? p : Path.Combine(dir, p));
                    }
                    catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
                    gitDir = gitDir.TrimEnd('\\', '/');
                    return new GitLocation(gitDir, Components(gitDir).Contains("worktrees"));
                }
                return null;
            }
            var parent = Path.GetDirectoryName(dir);
            if (parent is null || parent == dir) break;
            dir = parent;
        }
        return null;
    }

    /// Path components, '/' and '\' alike; a drive ("C:") or UNC prefix stays as the first part.
    private static List<string> Components(string path)
        => path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).ToList();

    private static bool IsRootComponent(string part, int index) => index == 0 && part.EndsWith(':');

    private static string Join(List<string> parts)
    {
        var joined = string.Join(Path.DirectorySeparatorChar, parts);
        // A drive letter alone needs its separator back ("C:" → "C:\").
        return parts.Count == 1 && parts[0].EndsWith(':') ? joined + Path.DirectorySeparatorChar : joined;
    }
}
