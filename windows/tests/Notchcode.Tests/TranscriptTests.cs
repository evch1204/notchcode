// TranscriptTests.cs
// The transcript reader, the agents builder and the watcher, on a small fixture written here:
// a prompt, an assistant Edit with its structuredPatch, token usage, an Agent launch with its
// subagent file, a headless (`entrypoint: sdk-cli`) helper run, Windows paths throughout.

using System.Text;
using Notchcode.ClaudeCode;
using Notchcode.Core;

namespace Notchcode.Tests;

public sealed class TranscriptTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("nc-transcripts-").FullName;
    private const string Cwd = @"C:\Users\me\Desktop\Personal Projects\demo";

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static string Iso(DateTime t) => t.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'");

    private static string J(string s) => System.Text.Json.JsonSerializer.Serialize(s);

    /// The main transcript: one turn with an Edit (structuredPatch), usage, an Agent launch.
    private (string Path, string Project) WriteFixture(DateTime start)
    {
        var project = Path.Combine(_root, NotchcodePaths.ProjectFolderName(Cwd));
        Directory.CreateDirectory(project);
        var sid = "11111111-2222-3333-4444-555555555555";
        var path = Path.Combine(project, sid + ".jsonl");
        var file = Cwd + @"\src\app.cs";
        var lines = new[]
        {
            $$$$"""{"type":"user","uuid":"u1","sessionId":"{{{{sid}}}}","timestamp":"{{{{Iso(start)}}}}","cwd":{{{{J(Cwd)}}}},"entrypoint":"cli","permissionMode":"acceptEdits","isSidechain":false,"message":{"role":"user","content":"Fix the greeting"}}""",
            $$$$"""{"type":"assistant","timestamp":"{{{{Iso(start.AddSeconds(2))}}}}","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":{{{{J(file)}}}},"old_string":"hi","new_string":"hello\nworld"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}""",
            $$$$"""{"type":"user","timestamp":"{{{{Iso(start.AddSeconds(3))}}}}","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":{{{{J(file)}}}},"structuredPatch":[{"oldStart":4,"oldLines":3,"newStart":4,"newLines":4,"lines":[" a","-hi","+hello","+world"," b"]}]}}""",
            // The same message again (one API message over several lines): usage counts once.
            $$$$"""{"type":"assistant","timestamp":"{{{{Iso(start.AddSeconds(4))}}}}","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Now an agent."}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}""",
            $$$$"""{"type":"assistant","timestamp":"{{{{Iso(start.AddSeconds(5))}}}}","isSidechain":false,"message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"description":"Look around","subagent_type":"Explore","prompt":"x"}}],"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}""",
            $$$$"""{"type":"user","timestamp":"{{{{Iso(start.AddSeconds(9))}}}}","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2"}]},"toolUseResult":{"status":"completed","agentId":"a7"}}""",
            $$$$"""{"type":"assistant","timestamp":"{{{{Iso(start.AddSeconds(10))}}}}","isSidechain":false,"message":{"id":"m3","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}""",
        };
        // CRLF line ends, as a Windows editor might leave them: the reader must not care.
        File.WriteAllText(path, string.Join("\r\n", lines) + "\r\n", new UTF8Encoding(false));

        var subDir = Path.Combine(project, sid, "subagents");
        Directory.CreateDirectory(subDir);
        var other = Cwd + @"\README.md";
        var sub = new[]
        {
            $$$$"""{"type":"assistant","agentId":"a7","isSidechain":true,"timestamp":"{{{{Iso(start.AddSeconds(6))}}}}","message":{"id":"s1","model":"claude-haiku","content":[{"type":"tool_use","id":"st1","name":"Write","input":{"file_path":{{{{J(other)}}}},"content":"# Demo\n"}}],"usage":{"input_tokens":5,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}""",
            $$$$"""{"type":"user","agentId":"a7","isSidechain":true,"timestamp":"{{{{Iso(start.AddSeconds(7))}}}}","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"st1"}]},"toolUseResult":{"type":"create","filePath":{{{{J(other)}}}},"content":"# Demo\n","structuredPatch":[]}}""",
        };
        File.WriteAllText(Path.Combine(subDir, "agent-a7.jsonl"), string.Join("\n", sub) + "\n");
        return (path, project);
    }

    [Fact]
    public void TurnsReadEditsTokensAndSubagentFiles()
    {
        var start = DateTime.UtcNow.AddMinutes(-1);
        var (path, _) = WriteFixture(start);
        var turns = TranscriptReader.Turns(path);
        var turn = Assert.Single(turns);
        Assert.Equal("u1", turn.Id);
        Assert.Equal("Fix the greeting", turn.Prompt);
        Assert.Equal("claude-opus-5-5", turn.Model);
        // m1 once + m2 + the subagent's s1.
        Assert.Equal(16, turn.Tokens.Input);
        Assert.Equal(27, turn.Tokens.Output);
        Assert.Equal(1L, turn.ContextTokens); // the last main-thread usage: m2

        Assert.Equal(2, turn.Files.Count);
        var app = turn.Files[0];
        Assert.Equal(@"src\app.cs", app.Path);
        Assert.Equal(2, app.Added);
        Assert.Equal(1, app.Removed);
        Assert.Null(app.AgentId);
        Assert.Equal("@@ -4,3 +4,4 @@", app.Patch[0].Text);
        Assert.Equal(app.Patch, app.Snippet);

        var readme = turn.Files[1];
        Assert.Equal("README.md", readme.Path);
        Assert.Equal("new", readme.Kind);
        Assert.Equal(1, readme.Added);
        Assert.Equal("a7", readme.AgentId);
    }

    [Fact]
    public void TurnsGrowIncrementally()
    {
        var start = DateTime.UtcNow.AddMinutes(-1);
        var (path, _) = WriteFixture(start);
        Assert.Single(TranscriptReader.Turns(path));
        File.AppendAllText(path,
            $$$$"""{"type":"user","uuid":"u2","timestamp":"{{{{Iso(start.AddSeconds(20))}}}}","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"  And the docs  "}]}}""" + "\n");
        var turns = TranscriptReader.Turns(path);
        Assert.Equal(2, turns.Count);
        Assert.Equal("And the docs", turns[1].Prompt);
        // A line still being written (no newline yet) counts for the value, not the saved builder.
        File.AppendAllText(path, $$$$"""{"type":"user","uuid":"u3","timestamp":"{{{{Iso(start.AddSeconds(30))}}}}","message":{"role":"user","content":"<command-name>/review</command-name><command-args>12</command-args>"}}""");
        turns = TranscriptReader.Turns(path);
        Assert.Equal(3, turns.Count);
        Assert.Equal("/review 12", turns[2].Prompt);
    }

    [Fact]
    public void AgentsComeFromTheMainTranscript()
    {
        var (path, _) = WriteFixture(DateTime.UtcNow.AddMinutes(-1));
        var agent = Assert.Single(TranscriptReader.Agents(path));
        Assert.Equal("a7", agent.Id);
        Assert.Equal("Explore", agent.Type);
        Assert.Equal("Look around", agent.Description);
        Assert.False(agent.IsRunning);
        Assert.Equal("11111111-2222-3333-4444-555555555555", agent.SessionId);
    }

    [Fact]
    public void PromptTextDropsNoise()
    {
        JsonValue Line(string content) => JsonValue.Parse("{\"type\":\"user\",\"message\":{\"content\":" + J(content) + "}}");
        Assert.Null(JsonLines.PromptText(Line("<system-reminder>x</system-reminder>")));
        Assert.Null(JsonLines.PromptText(Line("[Request interrupted by user]")));
        Assert.Equal("! dir", JsonLines.PromptText(Line("<bash-input>dir</bash-input>")));
        Assert.Equal("hello", JsonLines.PromptText(Line("  hello \r\n")));
    }

    private sealed class Sink : ITranscriptWatcherSink
    {
        public List<IReadOnlyList<DiscoveredSession>> Calls = [];
        public void TranscriptsChanged(IReadOnlyList<DiscoveredSession> sessions) => Calls.Add(sessions);
    }

    [Fact]
    public void WatcherFindsSessionsAndMarksHeadlessOnes()
    {
        var now = DateTime.UtcNow;
        var (path, project) = WriteFixture(now.AddSeconds(-30));
        // A helper run Claude Code started for itself, in the same folder.
        var helper = Path.Combine(project, "99999999-0000-0000-0000-000000000000.jsonl");
        File.WriteAllText(helper,
            $$$$"""{"type":"user","uuid":"h1","timestamp":"{{{{Iso(now.AddSeconds(-5))}}}}","cwd":{{{{J(Cwd)}}}},"entrypoint":"sdk-cli","message":{"role":"user","content":"Name this branch"}}""" + "\n" +
            $$$$"""{"type":"assistant","timestamp":"{{{{Iso(now.AddSeconds(-4))}}}}","message":{"id":"x","content":[{"type":"tool_use","id":"b","name":"Bash","input":{}}]}}""" + "\n");

        var sink = new Sink();
        var watcher = new TranscriptWatcher(sink, projectsDirectory: _root, clock: () => now);
        watcher.PollOnce();
        var sessions = Assert.Single(sink.Calls);
        Assert.Equal(2, sessions.Count);
        var main = sessions.Single(s => s.TranscriptPath == path);
        Assert.Equal(Cwd, main.Cwd);
        Assert.Equal(SessionState.Done, main.State);
        Assert.Equal("Fix the greeting", main.LastPrompt);
        Assert.Equal("acceptEdits", main.PermissionMode);
        Assert.False(main.IsHeadless);
        var h = sessions.Single(s => s.TranscriptPath == helper);
        Assert.True(h.IsHeadless);
        Assert.Equal(SessionState.Working, h.State);
        Assert.Equal("Running", h.Verb);

        // Nothing changed: no second delivery.
        watcher.PollOnce();
        Assert.Single(sink.Calls);
    }

    [Fact]
    public void LatestTranscriptPathNormalisesTheCwd()
    {
        var (path, _) = WriteFixture(DateTime.UtcNow);
        Assert.Equal(path, TranscriptReader.LatestTranscriptPath(Cwd.ToLowerInvariant().Replace('\\', '/') + "/", _root),
                     StringComparer.OrdinalIgnoreCase);
        Assert.True(TranscriptReader.SamePath(@"C:\Users\me\x\", "c:/users/ME/x"));
    }
}
