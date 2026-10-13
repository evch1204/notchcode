// Program.cs
// notchcode-hook.exe <kind>: the Windows port of hooks/notchcode-hook.sh and
// hooks/notchcode-statusline.sh, run by Claude Code in exec form (no shell).
//
// Forwards one Claude Code hook event to the notchcode app over its named pipe.
// kind: permission pre_tool post_tool notification stop session_start session_end user_prompt
//       subagent_start subagent_stop     (hook events, as the sh script)
//       statusline                       (Claude Code's statusLine command, as notchcode-statusline.sh)
//       launch                           (SessionStart: starts the app when it is not running)
//       statusline-forward               (internal: the detached forward the status line fires)
//
// Rules: no dependencies beyond itself (git is used when present, for the tree report);
// prints nothing unless the app replied allow or deny to a blocking event (or the chained
// status line printed something); always exits 0, including when the app is not running.
// Wire format: see Contract.cs. The envelope is written by hand, as the sh writes it, so the
// trimmed exe needs no reflection: {"v":1,"kind","id","term_program","term_bundle_id","pid",
// "ts","payload"[,"tree"]}, the payload embedded verbatim with CR and LF turned into spaces.
//
// For user_prompt, and for post_tool on Bash, the envelope also carries a working-tree
// report ("tree", see TreeReporter.cs).

using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Notchcode.Core;

namespace Notchcode.Hook;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            Native.KeepStdHandlesFromChildren();
            var kind = args.Length > 0 ? args[0] : "";
            switch (kind)
            {
                case "permission" or "pre_tool":
                    Forward(kind, blocking: true);
                    break;
                case "post_tool" or "notification" or "stop" or "session_start" or "session_end" or "user_prompt"
                    or "subagent_start" or "subagent_stop":
                    Forward(kind, blocking: false);
                    break;
                case "statusline-forward":
                    Forward("statusline", blocking: false);
                    break;
                case "statusline":
                    StatusLine.Run();
                    break;
                case "launch":
                    DrainStdin();
                    Launcher.LaunchIfNeeded();
                    break;
                default:
                    DrainStdin();
                    break;
            }
        }
        catch
        {
            // A hook never fails Claude Code and never prints an error.
        }
        return 0;
    }

    /// The pipe's name: NOTCHCODE_PIPE when set (tests, harnesses), else the user's own.
    internal static string PipeName
        => Environment.GetEnvironmentVariable("NOTCHCODE_PIPE") is { Length: > 0 } p ? p : NotchcodePaths.PipeName;

    internal static string PipePath => @"\\.\pipe\" + PipeName;

    /// %LOCALAPPDATA%\notchcode (the chain file, the stamps): NOTCHCODE_SUPPORT_DIR when set (tests).
    internal static string SupportDirectory
        => Environment.GetEnvironmentVariable("NOTCHCODE_SUPPORT_DIR") is { Length: > 0 } d ? d : NotchcodePaths.SupportDirectory;

    // MARK: Forwarding

    private static void Forward(string kind, bool blocking)
    {
        var payload = ReadStdin();
        // The hook input is one JSON object. Raw newlines can only sit between tokens (inside
        // strings they are escaped), so turning them into spaces keeps it valid.
        for (int i = 0; i < payload.Length; i++)
            if (payload[i] is (byte)'\r' or (byte)'\n') payload[i] = (byte)' ';

        // App not running: stay silent, let Claude Code carry on.
        if (!Native.PipeExists(PipePath)) return;

        if (IsBlank(payload)) payload = "{}"u8.ToArray();
        var info = PayloadInfo.Read(payload);

        // The tree report rides on a turn's start (the baseline) and on every Bash call.
        string? tree = null;
        if (kind == "user_prompt" || (kind == "post_tool" && info.ToolName == "Bash"))
        {
            try { tree = TreeReporter.Report(info.Cwd ?? Environment.CurrentDirectory); }
            catch { tree = null; }
        }

        var envelope = BuildEnvelope(kind, payload, tree);

        if (!blocking)
        {
            Exchange(envelope, waitSeconds: 1);
            return;
        }

        // Blocking: wait up to 59 s for one reply line (299 s for a plan). The app answers
        // "none" at 58 s (298 s for a plan), and Claude Code's own hook timeout is 305 s,
        // so nothing is ever cut off mid-way.
        int wait = info.ToolName == "ExitPlanMode" ? 299 : 59;
        var reply = Exchange(envelope, wait);
        if (reply is null || reply.Length == 0) return;
        if (Decision(kind, reply) is { } line) WriteStdout(Encoding.UTF8.GetBytes(line));
    }

    /// {"v":1,"kind":…,"id":…,"term_program":…,"term_bundle_id":"","pid":…,"ts":…,"payload":…[,"tree":…]}
    internal static byte[] BuildEnvelope(string kind, byte[] payload, string? tree)
    {
        var id = Guid.NewGuid().ToString().ToUpperInvariant();
        long ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        int pid = Native.ParentProcessId();
        var head = new StringBuilder()
            .Append("{\"v\":1,\"kind\":\"").Append(Esc(kind))
            .Append("\",\"id\":\"").Append(id)
            .Append("\",\"term_program\":\"").Append(Esc(TermProgram()))
            .Append("\",\"term_bundle_id\":\"\",\"pid\":").Append(pid)
            .Append(",\"ts\":").Append(ts)
            .Append(",\"payload\":").ToString();
        var ms = new MemoryStream();
        ms.Write(Encoding.UTF8.GetBytes(head));
        ms.Write(payload);
        if (tree is not null) ms.Write(Encoding.UTF8.GetBytes(tree));
        ms.Write("}\n"u8);
        return ms.ToArray();
    }

    /// TERM_PROGRAM when set (VS Code sets it); "WindowsTerminal" when WT_SESSION is set; else "".
    private static string TermProgram()
    {
        var tp = Environment.GetEnvironmentVariable("TERM_PROGRAM");
        if (!string.IsNullOrEmpty(tp)) return tp;
        return string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WT_SESSION")) ? "" : "WindowsTerminal";
    }

    /// Sends the envelope and reads one reply line within `waitSeconds`. Null when the app
    /// could not be reached or said nothing in time.
    private static byte[]? Exchange(byte[] envelope, int waitSeconds)
    {
        using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try { pipe.Connect(2000); }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException) { return null; }
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(waitSeconds));
        try
        {
            pipe.WriteAsync(envelope, cts.Token).AsTask().GetAwaiter().GetResult();
            pipe.FlushAsync(cts.Token).GetAwaiter().GetResult();
            var data = new MemoryStream();
            var buffer = new byte[16 * 1024];
            while (true)
            {
                int n = pipe.ReadAsync(buffer, cts.Token).AsTask().GetAwaiter().GetResult();
                if (n <= 0) break;
                int nl = Array.IndexOf(buffer, (byte)'\n', 0, n);
                if (nl >= 0) { data.Write(buffer, 0, nl); break; }
                data.Write(buffer, 0, n);
            }
            return data.ToArray();
        }
        catch (Exception e) when (e is OperationCanceledException or IOException or ObjectDisposedException)
        {
            return null;
        }
    }

    // MARK: The decision line

    /// What Claude Code reads on stdout, byte for byte what notchcode-hook.sh prints; null for
    /// "none" (print nothing: the terminal prompt continues).
    internal static string? Decision(string kind, byte[] reply)
    {
        string? decision = null;
        bool always = false;
        string? reason = null;     // the JSON string literal as the app wrote it
        string? perms = null;      // the JSON array as the app wrote it
        try
        {
            var reader = new Utf8JsonReader(reply);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var name = reader.GetString();
                reader.Read();
                switch (name)
                {
                    case "decision" when reader.TokenType == JsonTokenType.String:
                        decision = reader.GetString();
                        break;
                    case "always":
                        always = reader.TokenType == JsonTokenType.True;
                        break;
                    case "reason" when reader.TokenType == JsonTokenType.String:
                        reason = "\"" + Encoding.UTF8.GetString(reader.ValueSpan) + "\"";
                        break;
                    case "updated_permissions" when reader.TokenType == JsonTokenType.StartArray:
                    {
                        int start = (int)reader.TokenStartIndex;
                        reader.Skip();
                        perms = Encoding.UTF8.GetString(reply, start, (int)reader.BytesConsumed - start);
                        break;
                    }
                    default:
                        reader.Skip();
                        break;
                }
            }
        }
        catch (JsonException)
        {
            if (decision is null) return null;
        }
        if (decision is not ("allow" or "deny")) return null;

        const string denied = "\"Denied from notchcode\"";
        switch (kind)
        {
            case "permission":
                if (decision == "allow")
                {
                    if (always && perms is not null)
                        return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"updatedPermissions\":" + perms + "}}}\n";
                    return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}\n";
                }
                return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":" + (reason ?? denied) + "}}}\n";
            case "pre_tool":
                if (decision == "allow")
                    return "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Approved in notchcode\"}}\n";
                return "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":" + (reason ?? denied) + "}}\n";
        }
        return null;
    }

    // MARK: Helpers

    /// A JSON string body: tabs become spaces and every other control character goes, so a
    /// stray one in TERM_PROGRAM or a path cannot make the envelope invalid JSON.
    internal static string Esc(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if (c == '\t') sb.Append(' ');
            else if (c < 0x20) continue;
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '"') sb.Append("\\\"");
            else sb.Append(c);
        }
        return sb.ToString();
    }

    internal static byte[] ReadStdin()
    {
        try
        {
            using var stdin = Console.OpenStandardInput();
            var ms = new MemoryStream();
            stdin.CopyTo(ms);
            var data = ms.ToArray();
            // PowerShell can put a UTF-8 BOM in front of what it pipes; JSON never starts with one.
            return data.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? data[3..] : data;
        }
        catch (IOException) { return []; }
    }

    internal static void DrainStdin()
    {
        try
        {
            using var stdin = Console.OpenStandardInput();
            stdin.CopyTo(Stream.Null);
        }
        catch (IOException) { }
    }

    internal static void WriteStdout(byte[] bytes)
    {
        try
        {
            using var stdout = Console.OpenStandardOutput();
            stdout.Write(bytes);
            stdout.Flush();
        }
        catch (IOException) { }
    }

    private static bool IsBlank(byte[] data)
    {
        foreach (var b in data) if (b is not ((byte)' ' or (byte)'\t')) return false;
        return true;
    }
}

/// The two payload fields the hook needs: `cwd` (the tree report's folder) and `tool_name`
/// (Bash gets a tree report; ExitPlanMode waits longer). Top-level only.
internal readonly record struct PayloadInfo(string? Cwd, string? ToolName)
{
    public static PayloadInfo Read(byte[] payload)
    {
        string? cwd = null, tool = null;
        try
        {
            var reader = new Utf8JsonReader(payload, new JsonReaderOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return default;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                var name = reader.GetString();
                reader.Read();
                if (name == "cwd" && reader.TokenType == JsonTokenType.String) cwd ??= reader.GetString();
                else if (name == "tool_name" && reader.TokenType == JsonTokenType.String) tool ??= reader.GetString();
                else reader.Skip();
            }
        }
        catch (JsonException) { }
        return new PayloadInfo(cwd is { Length: > 0 } ? cwd : null, tool);
    }
}
