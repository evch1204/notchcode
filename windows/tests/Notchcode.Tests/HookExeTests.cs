// HookExeTests.cs
// The built notchcode-hook.exe against the real PipeServer on a private pipe name
// (NOTCHCODE_PIPE): the envelope it writes is one the app reads, and the decision line it
// prints is byte for byte what hooks/notchcode-hook.sh prints.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using Notchcode.Core;
using Notchcode.Transport;

namespace Notchcode.Tests;

public sealed class HookExeTests : IDisposable
{
    private readonly string _name = "notchcode-test-" + Guid.NewGuid().ToString("N");
    private readonly AnsweringSink _sink = new();
    private readonly PipeServer _server;

    public HookExeTests()
    {
        _server = new PipeServer(_sink, _name, replyDeadline: plan => plan ? 6 : 4);
        _server.Start();
    }

    public void Dispose() => _server.Stop();

    private sealed class AnsweringSink : IHookEventSink
    {
        public HookReply? Answer;
        public readonly BlockingCollection<HookEnvelope> Received = new();
        public void Receive(HookEnvelope envelope, ReplyHandler reply)
        {
            Received.Add(envelope);
            if (envelope.IsBlocking && Answer is not null) reply(Answer);
        }
        public void Cancel(string requestId) { }
        public void TimedOut(string requestId) { }
    }

    /// The hook exe: the single-file publish when there is one, else the Debug build.
    private static string HookExe()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "src", "Notchcode.Hook"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var bin = Path.Combine(dir!.FullName, "src", "Notchcode.Hook", "bin");
        string[] candidates =
        [
            Path.Combine(bin, "Release", "net10.0", "win-x64", "publish", "notchcode-hook.exe"),
            Path.Combine(bin, "Debug", "net10.0", "win-x64", "notchcode-hook.exe"),
            Path.Combine(bin, "Release", "net10.0", "win-x64", "notchcode-hook.exe"),
        ];
        return candidates.Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).First();
    }

    private (string Out, int Exit, TimeSpan Took) Run(string kind, string stdin, string? pipe = null, string? cwd = null, string? supportDir = null)
    {
        var psi = new ProcessStartInfo(HookExe(), kind)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = cwd ?? AppContext.BaseDirectory,
            StandardInputEncoding = new UTF8Encoding(false),
        };
        psi.Environment["NOTCHCODE_PIPE"] = pipe ?? _name;
        psi.Environment["TERM_PROGRAM"] = "vscode";
        if (supportDir is not null) psi.Environment["NOTCHCODE_SUPPORT_DIR"] = supportDir;
        var sw = Stopwatch.StartNew();
        using var p = Process.Start(psi)!;
        p.StandardInput.Write(stdin);
        p.StandardInput.Close();
        var output = p.StandardOutput.ReadToEndAsync();
        var err = p.StandardError.ReadToEndAsync();
        Assert.True(p.WaitForExit(30_000));
        Assert.Equal("", err.Result);
        return (output.Result, p.ExitCode, sw.Elapsed);
    }

    private const string PermissionPayload =
        "{\"session_id\":\"s1\",\"cwd\":\"C:\\\\x\",\"hook_event_name\":\"PermissionRequest\",\r\n \"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"},\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"npm test:*\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}\r\n";

    [Fact]
    public void AllowAlwaysPrintsTheUpdatedPermissions()
    {
        _sink.Answer = new HookReply { Decision = Decision.Allow, Always = true };
        var (output, exit, _) = Run("permission", PermissionPayload);
        Assert.Equal(0, exit);
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"updatedPermissions\":[{\"behavior\":\"allow\",\"destination\":\"localSettings\",\"rules\":[{\"ruleContent\":\"npm test:*\",\"toolName\":\"Bash\"}],\"type\":\"addRules\"}]}}}\n", output);

        // The envelope the app read: the payload verbatim (CR/LF as spaces), term_program, a pid.
        Assert.True(_sink.Received.TryTake(out var env, 1000));
        Assert.Equal(EventKind.Permission, env.Kind);
        Assert.Equal("s1", env.ResolvedSessionId);
        Assert.Equal("vscode", env.TermProgram);
        Assert.True(env.Pid > 0);
        Assert.Equal(36, env.Id.Length);
    }

    [Fact]
    public void DenyPrintsTheReasonAsWritten()
    {
        _sink.Answer = new HookReply { Decision = Decision.Deny, Reason = "Not \"now\" \\ later" };
        var (output, _, _) = Run("permission", PermissionPayload);
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"Not \\\"now\\\" \\\\ later\"}}}\n", output);
    }

    [Fact]
    public void PreToolAllowAndPlainDeny()
    {
        _sink.Answer = new HookReply { Decision = Decision.Allow };
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Approved in notchcode\"}}\n",
                     Run("pre_tool", "{\"tool_name\":\"Bash\"}").Out);
        _sink.Answer = new HookReply { Decision = Decision.Deny };
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Denied from notchcode\"}}\n",
                     Run("pre_tool", "{\"tool_name\":\"Bash\"}").Out);
    }

    [Fact]
    public void ABomInFrontOfTheInputIsDropped()
    {
        // Windows PowerShell can pipe a UTF-8 BOM before the JSON.
        Run("stop", "﻿{\"session_id\":\"bom\"}");
        Assert.True(_sink.Received.TryTake(out var env, 2000));
        Assert.Equal("bom", env.ResolvedSessionId);
    }

    [Fact]
    public void NoneAtTheDeadlinePrintsNothing()
    {
        _sink.Answer = null;
        var (output, exit, took) = Run("permission", PermissionPayload);
        Assert.Equal("", output);
        Assert.Equal(0, exit);
        Assert.True(took.TotalSeconds < 15);
    }

    [Fact]
    public void NoAppMeansSilenceAtOnce()
    {
        var (output, exit, took) = Run("permission", PermissionPayload, pipe: "notchcode-test-nobody-" + Guid.NewGuid().ToString("N"));
        Assert.Equal("", output);
        Assert.Equal(0, exit);
        Assert.True(took.TotalSeconds < 5);
        Assert.Equal(0, Run("bogus_kind", "x").Exit);
    }

    [Fact]
    public void BashPostToolCarriesTheTreeReport()
    {
        var repo = Directory.CreateTempSubdirectory("nc-tree-").FullName;
        try
        {
            void Git(params string[] args)
            {
                var psi = new ProcessStartInfo("git.exe") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = repo, RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (var a in args) psi.ArgumentList.Add(a);
                using var p = Process.Start(psi)!;
                p.StandardOutput.ReadToEnd();
                p.WaitForExit();
            }
            Git("init", "-q");
            Git("config", "user.email", "t@example.com");
            Git("config", "user.name", "t");
            Git("config", "core.autocrlf", "false");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "one\ntwo\n");
            Git("add", "a.txt");
            Git("commit", "-q", "-m", "first");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "one\r\nTWO\r\n");
            File.WriteAllText(Path.Combine(repo, "new file.txt"), "hello\n");

            var cwd = repo.Replace("\\", "\\\\");
            var (output, _, _) = Run("post_tool", "{\"session_id\":\"s2\",\"cwd\":\"" + cwd + "\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo\"}}");
            Assert.Equal("", output);
            Assert.True(_sink.Received.TryTake(out var env, 3000));
            Assert.Equal(EventKind.PostTool, env.Kind);
            var tree = env.Tree;
            Assert.NotNull(tree);
            Assert.Equal(40, tree!.Head!.Length);
            Assert.Contains(" M a.txt", tree.Status);
            Assert.Contains("?? \"new file.txt\"", tree.Status); // porcelain quotes a name with a space
            var snapshot = UnifiedDiff.Snapshot(tree);
            Assert.Equal((2, 2), (snapshot.Files["a.txt"].Added, snapshot.Files["a.txt"].Removed));
            Assert.Equal(1, snapshot.Files["new file.txt"].Added);
            Assert.True(TranscriptPathsEqual(tree.Root, repo));
        }
        finally
        {
            foreach (var f in Directory.EnumerateFiles(repo, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal);
            Directory.Delete(repo, true);
        }
    }

    // MARK: Wave 3d

    /// A git repo in a temp folder with one commit of `files`; deleted on Dispose.
    private sealed class TempRepo : IDisposable
    {
        public readonly string Root = Directory.CreateTempSubdirectory("nc-tree-").FullName;

        public TempRepo(params (string Path, string Text)[] files)
        {
            Git("init", "-q");
            Git("config", "user.email", "t@example.com");
            Git("config", "user.name", "t");
            Git("config", "core.autocrlf", "false");
            foreach (var (path, text) in files) Write(path, text);
            Git("add", "-A");
            Git("commit", "-q", "-m", "first");
        }

        public void Write(string path, string text)
        {
            var full = System.IO.Path.Combine(Root, path);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
            File.WriteAllText(full, text, new UTF8Encoding(false));
        }

        public void Git(params string[] args)
        {
            var psi = new ProcessStartInfo("git.exe") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Root, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
        }

        /// The payload's cwd as a JSON string body.
        public string JsonCwd => Root.Replace("\\", "\\\\");

        public void Dispose()
        {
            try
            {
                foreach (var f in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories)) File.SetAttributes(f, FileAttributes.Normal);
                Directory.Delete(Root, true);
            }
            catch (IOException) { }
        }
    }

    private TreeReport BashReport(TempRepo repo, string sid)
    {
        var (output, _, _) = Run("post_tool", "{\"session_id\":\"" + sid + "\",\"cwd\":\"" + repo.JsonCwd + "\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x\"}}");
        Assert.Equal("", output);
        Assert.True(_sink.Received.TryTake(out var env, 5000));
        Assert.Equal(sid, env.ResolvedSessionId);
        return env.Tree!;
    }

    [Fact]
    public void NamesWithSpacesAndNonAsciiMatchBetweenStatusAndDiff()
    {
        using var repo = new TempRepo(("café dir/é f.txt", "one\n"), ("plain.txt", "a\n"));
        repo.Write("café dir/é f.txt", "one\ntwo\n");
        repo.Write("naïve new.txt", "hi\n");
        var tree = BashReport(repo, "u1");
        Assert.Contains(" M \"café dir/é f.txt\"", tree.Status);   // quotePath=false: quoted for the space only
        var snapshot = UnifiedDiff.Snapshot(tree);
        Assert.Equal(["café dir/é f.txt", "naïve new.txt"], snapshot.Order);
        Assert.Equal(1, snapshot.Files["café dir/é f.txt"].Added);
        Assert.NotEqual(0, snapshot.Files["café dir/é f.txt"].DiffHash);
        Assert.Equal(1, snapshot.Files["naïve new.txt"].Added);
        Assert.NotEqual(0, snapshot.Files["naïve new.txt"].DiffHash);
        Assert.DoesNotContain("NUL", tree.Diff);
        Assert.False(tree.Truncated);

        // The same tree reported again reads as no change, whatever file came last.
        var again = UnifiedDiff.Snapshot(BashReport(repo, "u1"));
        Assert.Empty(UnifiedDiff.Changes(snapshot, again, repo.Root));
    }

    [Fact]
    public void TheStatusStopsAt2000LinesAndTheDiffAt256KB()
    {
        using var repo = new TempRepo(("big.txt", "x\n"));
        // 300 KB of changes in one tracked file, and 2100 untracked files.
        repo.Write("big.txt", string.Concat(Enumerable.Range(0, 30_000).Select(i => $"line {i:D5}\n")));
        for (int i = 0; i < 2100; i++) repo.Write($"many/f{i:D4}.txt", "x\n");
        var tree = BashReport(repo, "cap");
        Assert.Equal(2000, tree.Status.Count);
        Assert.True(tree.Truncated);
        Assert.True(Encoding.UTF8.GetByteCount(tree.Diff) <= 262144);
        // The cut file counts as having no diff rather than a moving one.
        Assert.Equal(0, UnifiedDiff.Snapshot(tree).Files["big.txt"].DiffHash);
    }

    [Fact]
    public void RawNewlinesInsideTheInputBecomeSpaces()
    {
        // Not valid JSON as given (a raw newline inside a string); the sh's `tr '\r\n' '  '` makes it so.
        Run("stop", "{\"session_id\":\"nl\",\r\n\"last_assistant_message\":\"two\nlines\"}\n");
        Assert.True(_sink.Received.TryTake(out var env, 2000));
        Assert.Equal("nl", env.ResolvedSessionId);
        Assert.Equal("two lines", env.Payload["last_assistant_message"]?.StringValue);
    }

    [Fact]
    public void PlanAutoAcceptPrintsTheSetModeRule()
    {
        // AppState's Auto-accept reply, through the pipe and the exe: byte for byte what
        // hooks/notchcode-hook.sh prints for the same reply line.
        _sink.Answer = new HookReply
        {
            Decision = Decision.Allow,
            Always = true,
            UpdatedPermissions = JsonValue.Array(JsonValue.Object(
                ("type", JsonValue.String("setMode")), ("mode", JsonValue.String("acceptEdits")), ("destination", JsonValue.String("session")))),
        };
        var (output, _, _) = Run("permission", "{\"session_id\":\"p\",\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"# Plan\"},\"permission_mode\":\"plan\"}");
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"updatedPermissions\":[{\"destination\":\"session\",\"mode\":\"acceptEdits\",\"type\":\"setMode\"}]}}}\n", output);
        Assert.True(_sink.Received.TryTake(out var env, 1000));
        Assert.True(env.IsPlanRequest);
    }

    [Fact]
    public void AnAllowWithoutAlwaysNeverCarriesRules()
    {
        // The sh prints updatedPermissions only when "always" is true, rules or not.
        _sink.Answer = new HookReply { Decision = Decision.Allow, Always = false, UpdatedPermissions = JsonValue.Array(JsonValue.String("x")) };
        Assert.Equal("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}\n",
                     Run("permission", PermissionPayload).Out);
    }

    [Fact]
    public void TheChainedStatusLineRunsThroughItsOwnShell()
    {
        var support = Directory.CreateTempSubdirectory("nc-support-").FullName;
        try
        {
            // The chain's default is bash, but the old status line said "shell": "powershell".
            File.WriteAllText(Path.Combine(support, "statusline-chain.json"),
                "{\n  \"previous\": {\n    \"type\": \"command\",\n    \"shell\": \"powershell\",\n    \"command\": \"Write-Host -NoNewline 'own shell'\"\n  },\n  \"shell\": \"bash\"\n}\n");
            var (output, exit, _) = Run("statusline", "{\"session_id\":\"own-1\"}", pipe: "notchcode-test-nobody-" + Guid.NewGuid().ToString("N"), supportDir: support);
            Assert.Equal(0, exit);
            Assert.Equal("own shell", output);
        }
        finally { Directory.Delete(support, true); }
    }

    [Theory]
    [InlineData("bash", "printf 'chained %s' \"$(cat | head -c 13)\"", "chained {\"session_id\"")]
    [InlineData("powershell", "$x = [Console]::In.ReadToEnd(); Write-Host -NoNewline ('ps ' + $x.Length)", "ps 52")]
    public void StatusLineChainsThePreviousOneAndForwards(string shell, string previous, string expected)
    {
        if (shell == "bash" && Notchcode.ClaudeCode.HooksInstaller.FindBash() is null) return; // no Git Bash here
        var support = Directory.CreateTempSubdirectory("nc-support-").FullName;
        try
        {
            var chain = "{\n  \"previous\": {\n    \"type\": \"command\",\n    \"command\": " + System.Text.Json.JsonSerializer.Serialize(previous) +
                        "\n  },\n  \"shell\": \"" + shell + "\"\n}\n";
            File.WriteAllText(Path.Combine(support, "statusline-chain.json"), chain);
            const string input = "{\"session_id\":\"abc-1\",\"rate_limits\":{\"five_hour\":1}}";
            Assert.Equal(52, input.Length);
            var (output, exit, _) = Run("statusline", input, supportDir: support);
            Assert.Equal(0, exit);
            Assert.Equal(expected, output);

            // Forwarded in the background as a statusline envelope, stamped for 5 s.
            Assert.True(_sink.Received.TryTake(out var env, 5000));
            Assert.Equal(EventKind.Statusline, env.Kind);
            Assert.Equal("abc-1", env.ResolvedSessionId);
            Assert.True(File.Exists(Path.Combine(support, "statusline-stamps", "abc-1")));
            Run("statusline", input, supportDir: support);
            Assert.False(_sink.Received.TryTake(out _, 1500)); // throttled
        }
        finally { Directory.Delete(support, true); }
    }

    private static bool TranscriptPathsEqual(string a, string b) => Notchcode.ClaudeCode.TranscriptReader.SamePath(a, b);
}
