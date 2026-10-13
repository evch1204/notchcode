// TreeReporter.cs
// The working-tree report of hooks/notchcode-hook.sh (tree_report, tree_diff): git status and
// the diff against HEAD, base64, so the app can see files a shell command changed. Read-only
// git (GIT_OPTIONAL_LOCKS=0), skipped outside a work tree or without git.
//
//   ,"tree":{"root":"<toplevel>","head":"<sha>","status_b64":"…","diff_b64":"…","truncated":false}
//
// Status is capped at 2000 lines (a huge untracked tree must not push the envelope past the
// pipe's 8 MB), the diff at 256 KB. Untracked files (the first 20) are diffed against NUL;
// a `a/NUL` header is rewritten to the /dev/null form so one parser reads both platforms.

using System.Diagnostics;
using System.Text;

namespace Notchcode.Hook;

internal static class TreeReporter
{
    private const int StatusLines = 2000;
    private const int DiffCap = 262144;
    private const int UntrackedDiffs = 20;
    private const int GitTimeoutMs = 10_000;

    /// The `,"tree":{…}` fragment for the work tree holding `cwd`, or null outside one.
    public static string? Report(string cwd)
    {
        var topOut = Git(cwd, ["rev-parse", "--show-toplevel"], 64 * 1024);
        if (topOut is null) return null;
        var top = TrimTrailingNewlines(Encoding.UTF8.GetString(topOut));
        if (top.Length == 0) return null;

        var statusOut = Git(top, ["-c", "core.quotePath=false", "status", "--porcelain=v1", "--untracked-files=all"], 8 * 1024 * 1024);
        if (statusOut is null) return null;
        var statusLines = Encoding.UTF8.GetString(statusOut).Split('\n');
        // `$(… | head -n 2000)`: at most 2000 lines, trailing newlines dropped.
        var status = TrimTrailingNewlines(string.Join("\n", statusLines.Take(StatusLines)));

        var headOut = Git(top, ["rev-parse", "-q", "--verify", "HEAD"], 4096);
        var head = headOut is null ? "" : TrimTrailingNewlines(Encoding.UTF8.GetString(headOut));

        var diff = TreeDiff(top, status);
        // `diff=$(tree_diff | head -c cap+1)`, then cut to the cap when it went past.
        diff = TrimTrailingNewlineBytes(diff);
        bool truncated = false;
        if (diff.Length > DiffCap)
        {
            truncated = true;
            diff = diff[..DiffCap];
        }

        var sb = new StringBuilder();
        sb.Append(",\"tree\":{\"root\":\"").Append(Program.Esc(top))
          .Append("\",\"head\":\"").Append(Program.Esc(head))
          .Append("\",\"status_b64\":\"").Append(Convert.ToBase64String(Encoding.UTF8.GetBytes(status)))
          .Append("\",\"diff_b64\":\"").Append(Convert.ToBase64String(diff))
          .Append("\",\"truncated\":").Append(truncated ? "true" : "false").Append('}');
        return sb.ToString();
    }

    /// The diff against HEAD, then each untracked file (first 20) against NUL, at most cap+1 bytes.
    private static byte[] TreeDiff(string top, string status)
    {
        var output = new MemoryStream();
        var main = Git(top, ["-c", "core.quotePath=false", "diff", "HEAD", "--no-color", "--no-ext-diff", "--no-renames",
                             "--src-prefix=a/", "--dst-prefix=b/"], DiffCap + 1, acceptAnyExit: true);
        if (main is not null) output.Write(main);

        var untracked = new List<string>();
        // `sed -n 's/^?? //p' | head -n 20`: the first 20 untracked names, then the skips.
        foreach (var line in status.Split('\n').Where(l => l.StartsWith("?? ", StringComparison.Ordinal)).Take(UntrackedDiffs))
        {
            var f = line[3..].TrimEnd('\r');
            // A quoted name: drop the quotes when nothing inside is escaped, else skip it.
            if (f.Contains('\\')) continue;
            if (f.Length >= 2 && f[0] == '"' && f[^1] == '"') f = f[1..^1];
            untracked.Add(f);
        }
        if (untracked.Count > 0 && output.Length <= DiffCap)
        {
            // Exit 1 from `diff --no-index` is normal. Run side by side, joined in order.
            var parts = new byte[]?[untracked.Count];
            Parallel.For(0, untracked.Count, new ParallelOptions { MaxDegreeOfParallelism = 4 }, i =>
            {
                parts[i] = Git(top, ["-c", "core.quotePath=false", "diff", "--no-index", "--no-color", "--no-ext-diff",
                                     "--src-prefix=a/", "--dst-prefix=b/", "--", "NUL", untracked[i]], DiffCap + 1, acceptAnyExit: true);
            });
            for (int i = 0; i < parts.Length && output.Length <= DiffCap; i++)
            {
                if (parts[i] is { } p) output.Write(RewriteNulHeader(p, untracked[i]));
            }
        }
        var bytes = output.ToArray();
        return bytes.Length > DiffCap + 1 ? bytes[..(DiffCap + 1)] : bytes;
    }

    /// Git for Windows writes `--- /dev/null` for NUL already; an older one may write
    /// `a/NUL`. Both header lines are put in the macOS form.
    private static byte[] RewriteNulHeader(byte[] diff, string file)
    {
        var text = Encoding.UTF8.GetString(diff);
        if (!text.Contains("a/NUL", StringComparison.Ordinal)) return diff;
        var lines = text.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            if (lines[i].StartsWith("@@", StringComparison.Ordinal)) break;
            if (lines[i] == "--- a/NUL" || lines[i] == "--- a/NUL\t") lines[i] = "--- /dev/null";
            else if (lines[i].StartsWith("diff --git a/NUL b/", StringComparison.Ordinal)) lines[i] = "diff --git a/" + file + " b/" + file;
        }
        return Encoding.UTF8.GetBytes(string.Join("\n", lines));
    }

    /// git.exe by absolute path: a bare "git.exe" would be searched in the current directory
    /// first, which is the session's repository, so a git.exe committed there would run.
    /// Fully qualified PATH entries only, else Git for Windows' default place.
    private static readonly Lazy<string> GitExecutable = new(() =>
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

    /// Runs git with `GIT_OPTIONAL_LOCKS=0`, stdin closed, and returns at most `cap` bytes of
    /// its output; null when it failed to start or (unless `acceptAnyExit`) exited non-zero.
    private static byte[]? Git(string dir, string[] args, int cap, bool acceptAnyExit = false)
    {
        var psi = new ProcessStartInfo
        {
            FileName = GitExecutable.Value,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("-C");
        psi.ArgumentList.Add(dir);
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";
        try
        {
            using var p = Process.Start(psi);
            if (p is null) return null;
            p.StandardInput.Close();
            var errTask = p.StandardError.BaseStream.CopyToAsync(Stream.Null);
            var output = new MemoryStream();
            var buffer = new byte[64 * 1024];
            var stream = p.StandardOutput.BaseStream;
            var readTask = Task.Run(() =>
            {
                while (output.Length < cap)
                {
                    int n = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, cap - output.Length));
                    if (n <= 0) break;
                    output.Write(buffer, 0, n);
                }
            });
            if (!readTask.Wait(GitTimeoutMs) || output.Length >= cap)
            {
                // Past the cap (`head -c`) or too slow: stop it; what was read stands.
                try { p.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                if (!readTask.IsCompleted && output.Length == 0) return null;
                return output.ToArray();
            }
            if (!p.WaitForExit(GitTimeoutMs)) return null;
            errTask.Wait(1000);
            if (!acceptAnyExit && p.ExitCode != 0) return null;
            return output.ToArray();
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or AggregateException)
        {
            return null;
        }
    }

    private static string TrimTrailingNewlines(string s) => s.TrimEnd('\n', '\r');

    private static byte[] TrimTrailingNewlineBytes(byte[] b)
    {
        int end = b.Length;
        while (end > 0 && b[end - 1] == (byte)'\n') end--;
        return end == b.Length ? b : b[..end];
    }
}
