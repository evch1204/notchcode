// StatusLine.cs
// `notchcode-hook.exe statusline`: the port of hooks/notchcode-statusline.sh, Claude Code's
// statusLine command. Claude Code hands the status line the only copy of the plan limits
// (rate_limits.five_hour / seven_day: used_percentage, resets_at in unix s), plus
// context_window, cost, model and session_id. This:
//
//   1. forwards that JSON to the notchcode app as an envelope of kind "statusline", through a
//      detached `notchcode-hook.exe statusline-forward`, at most once every 5 s per session;
//   2. runs the status line that was configured before notchcode (saved by Connect in
//      %LOCALAPPDATA%\notchcode\statusline-chain.json as {"previous": {...}, "shell": …})
//      with the same stdin, through the shell Claude Code would have used (bash -c, or
//      powershell -NoProfile -Command), and prints exactly what it prints. With nothing
//      chained it prints nothing.
//
// A session's first stamp also deletes stamps older than 7 days, so the folder never grows.
// Never prints an error; always exits 0, including when the app is not running.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Notchcode.Core;

namespace Notchcode.Hook;

internal static partial class StatusLine
{
    private const int ThrottleSeconds = 5;
    private static readonly TimeSpan StampKeep = TimeSpan.FromDays(7);
    private const int ChainTimeoutMs = 30_000;

    [GeneratedRegex("\"session_id\"\\s*:\\s*\"([A-Za-z0-9_-]*)\"", RegexOptions.RightToLeft)]
    private static partial Regex SessionIdPattern();

    public static void Run()
    {
        var input = Program.ReadStdin();

        // 1. Forward, only when the app is listening, throttled per session with a stamp file.
        if (input.Length > 0 && Native.PipeExists(Program.PipePath))
        {
            try { MaybeForward(input); } catch { }
        }

        // 2. Chain to the previous status line, if one was saved. Never to ourselves.
        var (previous, shell) = ReadChain();
        if (previous is null || previous.Length == 0
            || previous.Contains("notchcode-hook", StringComparison.OrdinalIgnoreCase)
            || previous.Contains("notchcode-statusline", StringComparison.OrdinalIgnoreCase)) return;
        var output = RunChained(previous, shell, input);
        if (output is { Length: > 0 }) Program.WriteStdout(output);
    }

    private static void MaybeForward(byte[] input)
    {
        var text = Encoding.UTF8.GetString(input).Replace('\r', ' ').Replace('\n', ' ');
        var match = SessionIdPattern().Match(text);
        var sid = match.Success && match.Groups[1].Value.Length > 0 ? match.Groups[1].Value : "unknown";
        var stamps = Path.Combine(Program.SupportDirectory, "statusline-stamps");
        var stamp = Path.Combine(stamps, sid);
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        long last = 0;
        bool exists = File.Exists(stamp);
        if (exists)
        {
            try { last = new DateTimeOffset(File.GetLastWriteTimeUtc(stamp)).ToUnixTimeSeconds(); } catch (IOException) { }
        }
        if (now - last < ThrottleSeconds && now >= last) return;

        if (!exists) Prune(stamps);
        Directory.CreateDirectory(stamps);
        File.WriteAllBytes(stamp, []);
        File.SetLastWriteTimeUtc(stamp, DateTime.UtcNow);

        // Detached: the status line is never slowed, and Claude Code cancelling this process
        // (it does when a newer update arrives) does not wait on the pipe.
        var self = Environment.ProcessPath;
        if (string.IsNullOrEmpty(self)) return;
        var psi = new ProcessStartInfo
        {
            FileName = self,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.ArgumentList.Add("statusline-forward");
        var child = Process.Start(psi);
        if (child is null) return;
        try
        {
            child.StandardInput.BaseStream.Write(input);
            child.StandardInput.Close();
        }
        catch (IOException) { }
    }

    /// A session's first status line: prune the stamps of sessions long gone.
    private static void Prune(string stamps)
    {
        try
        {
            if (!Directory.Exists(stamps)) return;
            var cutoff = DateTime.UtcNow - StampKeep;
            foreach (var f in new DirectoryInfo(stamps).EnumerateFiles())
            {
                if (f.LastWriteTimeUtc < cutoff)
                {
                    try { f.Delete(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// previous.command and the shell from the chain file; nulls when there is none.
    private static (string? Command, string Shell) ReadChain()
    {
        byte[] data;
        try { data = File.ReadAllBytes(Path.Combine(Program.SupportDirectory, "statusline-chain.json")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return (null, "bash"); }
        string? command = null;
        string shell = "bash";
        string? ownShell = null;   // the previous status line's own "shell", which wins
        try
        {
            var reader = new Utf8JsonReader(data, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return (null, shell);
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var name = reader.GetString();
                reader.Read();
                if (name == "shell" && reader.TokenType == JsonTokenType.String)
                {
                    shell = reader.GetString() ?? "bash";
                }
                else if (name == "previous" && reader.TokenType == JsonTokenType.StartObject)
                {
                    while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
                    {
                        var key = reader.GetString();
                        reader.Read();
                        if (key == "command" && reader.TokenType == JsonTokenType.String) command = reader.GetString();
                        else if (key == "shell" && reader.TokenType == JsonTokenType.String) ownShell = reader.GetString();
                        else reader.Skip();
                    }
                }
                else
                {
                    reader.Skip();
                }
            }
        }
        catch (JsonException) { return (null, shell); }
        // A status line that named its shell (`"shell": "powershell"`, as the hooks on this PC
        // do) ran through that shell before Connect; it keeps doing so.
        if (ownShell is "bash" or "powershell") shell = ownShell;
        return (command, shell);
    }

    /// Runs the previous status line with the same stdin; its stdout, or null.
    private static byte[]? RunChained(string command, string shell, byte[] input)
    {
        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        var bash = shell == "bash" ? FindBash() : null;
        if (bash is not null)
        {
            psi.FileName = bash;
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add(command);
        }
        else
        {
            psi.FileName = "powershell.exe";
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-NonInteractive");
            psi.ArgumentList.Add("-Command");
            psi.ArgumentList.Add(command);
        }
        try
        {
            using var p = Process.Start(psi);
            if (p is null) return null;
            var outTask = Task.Run(() =>
            {
                var ms = new MemoryStream();
                p.StandardOutput.BaseStream.CopyTo(ms);
                return ms.ToArray();
            });
            var errTask = p.StandardError.BaseStream.CopyToAsync(Stream.Null);
            try
            {
                p.StandardInput.BaseStream.Write(input);
                p.StandardInput.Close();
            }
            catch (IOException) { }
            if (!p.WaitForExit(ChainTimeoutMs))
            {
                try { p.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
            return outTask.Wait(2000) ? outTask.Result : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or AggregateException)
        {
            return null;
        }
    }

    /// Git Bash, found as HooksInstaller.FindBash finds it.
    private static string? FindBash()
    {
        var env = Environment.GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env)) return env;
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim().Trim('"'), "bash.exe");
                if (!File.Exists(candidate)) continue;
                var full = Path.GetFullPath(candidate);
                if (full.StartsWith(system, StringComparison.OrdinalIgnoreCase)) continue;
                if (full.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase)) continue;
                return full;
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        var git = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "bin", "bash.exe");
        return File.Exists(git) ? git : null;
    }
}
