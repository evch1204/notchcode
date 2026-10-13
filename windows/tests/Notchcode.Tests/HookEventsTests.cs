// HookEventsTests.cs
// Envelopes fed through AppState.Receive with a fake reply handler: requests, answers,
// timeouts, the done peek, shell-change attribution, agents and session end.

using Notchcode.Core;
using Notchcode.State;

namespace Notchcode.Tests;

public class HookEventsTests
{
    internal const string Sid = "s1";
    internal const string Cwd = @"C:\r\app";

    internal static AppState MakeState(Preferences? prefs = null)
        => new(prefs ?? new Preferences(), savesPrefs: false) { ReadsLocalFiles = false };

    internal static HookEnvelope Envelope(EventKind kind, string payload, string id = "e1", TreeReport? tree = null, string sid = Sid)
        => new() { Kind = kind, Id = id, SessionId = sid, Cwd = Cwd, Payload = JsonValue.Parse(payload), Tree = tree };

    /// A reply handler that records what it got and reports `delivered`.
    internal sealed class Replies
    {
        public readonly List<HookReply?> Got = [];
        public bool Delivered = true;
        public bool Handle(HookReply? reply) { Got.Add(reply); return Delivered; }
    }

    /// The diff text as the hook sends it: the macOS script captures it with `$(…)`, which drops
    /// the trailing newline (else the last file's body would hash with an extra empty line).
    private static TreeReport Tree(string[] status, string diff, string? head = "abc")
        => new() { Root = "C:/r/app", Head = head, Status = status, Diff = diff.TrimEnd('\n') };

    private static string FileDiff(string path, params string[] added)
        => $"diff --git a/{path} b/{path}\nindex 1..2 100644\n--- a/{path}\n+++ b/{path}\n@@ -1,1 +1,{added.Length + 1} @@\n ctx\n"
           + string.Concat(added.Select(a => "+" + a + "\n"));

    /// Waits for a timer callback (they run off the test thread without a WPF app).
    private static void WaitFor(AppState state, Func<bool> condition, double seconds = 5)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            lock (state.TimerGate) { if (condition()) return; }
            Thread.Sleep(20);
        }
        lock (state.TimerGate) Assert.True(condition());
    }

    [Fact]
    public void PermissionWaitsInAttentionAndAllowRepliesOnce()
    {
        var state = MakeState();
        var replies = new Replies();
        const string payload = """{"tool_name":"Bash","tool_input":{"command":"npm test","description":"Runs the tests"},"permission_mode":"default"}""";
        state.Receive(Envelope(EventKind.Permission, payload, id: "p1"), replies.Handle);

        var req = Assert.Single(state.Pending);
        Assert.Equal(PendingRequestKind.Permission, req.Kind);
        Assert.Equal("Run a command?", req.Title);
        Assert.Equal("npm test", req.Detail);
        Assert.Equal("Runs the tests", req.Reason);
        Assert.Equal(NotchMode.Attention, state.Mode);
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
        Assert.Equal("app", state.Session(Sid)!.WorktreeName);
        Assert.True((req.Deadline - req.ReceivedAt).TotalSeconds is > 57.9 and < 58.1);
        Assert.Empty(replies.Got);

        // Inside the key guard a press does nothing.
        state.Answer(RequestAnswer.Allow, req);
        Assert.Empty(replies.Got);

        state.AnswerKeysAllowedAt = DateTime.MinValue;
        Assert.True(state.HandleKey(NotchKey.Primary));
        var reply = Assert.Single(replies.Got);
        Assert.Equal("{\"always\":false,\"decision\":\"allow\",\"id\":\"p1\"}\n", HookReply.ReplyLine(reply, "p1", JsonValue.Parse(payload)));
        Assert.Empty(state.Pending);
        Assert.Equal(SessionState.Working, state.Session(Sid)!.State);
        Assert.Equal(NotchMode.Wings, state.Mode);

        // A second answer reaches no one.
        state.Answer(RequestAnswer.Deny, req);
        Assert.Single(replies.Got);
    }

    [Fact]
    public void TimeoutDropsTheRequestAndTheSessionNeedsYou()
    {
        var state = MakeState();
        var replies = new Replies();
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), replies.Handle);
        state.TimedOut("p1");
        Assert.Empty(state.Pending);
        Assert.Empty(replies.Got);
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
        Assert.Equal(NotchMode.Wings, state.Mode);

        // Cancel of an unknown id is ignored.
        state.Cancel("nope");
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
    }

    [Fact]
    public void CancelDropsTheRequestWithoutReplying()
    {
        var state = MakeState();
        var replies = new Replies();
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), replies.Handle);
        state.Cancel("p1");
        Assert.Empty(state.Pending);
        Assert.Empty(replies.Got);
        Assert.Equal(SessionState.Working, state.Session(Sid)!.State);
    }

    [Fact]
    public void ALateAnswerSaysTooLate()
    {
        var state = MakeState();
        var replies = new Replies { Delivered = false };
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), replies.Handle);
        state.AnswerKeysAllowedAt = DateTime.MinValue;
        state.Answer(RequestAnswer.Allow, state.CurrentPending!);
        Assert.Equal(AppState.TooLateHint, state.Hint);
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
    }

    [Fact]
    public void StopShowsTheDonePeekThenRests()
    {
        var state = MakeState(new Preferences { PeekSeconds = 0.2 });
        Action<HookEnvelope> send = e => state.Receive(e, _ => true);
        send(Envelope(EventKind.UserPrompt, """{"prompt":"Fix it"}"""));
        Assert.Equal(SessionState.Working, state.Session(Sid)!.State);
        Assert.Equal("Thinking", state.Session(Sid)!.Verb);
        Assert.Equal("Fix it", state.TurnTitles[Sid]);
        send(Envelope(EventKind.PostTool, """{"tool_name":"Edit","tool_input":{"file_path":"C:\\r\\app\\a.cs"},"tool_response":{"filePath":"C:\\r\\app\\a.cs","structuredPatch":[{"lines":["+x","+y","-z"]}]}}"""));
        send(Envelope(EventKind.Stop, "{}"));

        Assert.Equal(SessionState.Done, state.Session(Sid)!.State);
        var peek = state.Peek;
        Assert.NotNull(peek);
        Assert.Equal(PeekKind.Done, peek!.Kind);
        Assert.Equal("Done · app", peek.Title);
        Assert.Equal(2, peek.Added);
        Assert.Equal(1, peek.Removed);
        Assert.Equal("1 file", peek.Detail);
        Assert.Equal(NotchMode.Peek, state.Mode);

        WaitFor(state, () => state.Peek is null);
        lock (state.TimerGate) Assert.Equal(NotchMode.Resting, state.Mode);
    }

    [Fact]
    public void ShellEditsAreAttributedFileByFile()
    {
        var state = MakeState(new Preferences { PeekSeconds = 30 });
        Action<HookEnvelope> send = e => state.Receive(e, _ => true);

        // At the prompt: dirty.txt already changed, staged.txt staged.
        var baseline = Tree([" M dirty.txt", "M  staged.txt"], FileDiff("dirty.txt", "old") + FileDiff("staged.txt", "s"));
        send(Envelope(EventKind.UserPrompt, """{"prompt":"go","source":"user"}""", tree: baseline));

        // A Bash call: dirty.txt unchanged, staged.txt only unstaged (same body), new.txt appears, a.txt edited.
        var after = Tree([" M dirty.txt", " M staged.txt", "?? new.txt", " M a.txt"],
            FileDiff("dirty.txt", "old") + FileDiff("staged.txt", "s") + FileDiff("new.txt", "n1", "n2") + FileDiff("a.txt", "x"));
        send(Envelope(EventKind.PostTool, """{"tool_name":"Bash","tool_input":{"command":"sed -i x a.txt"}}""", tree: after));

        var held = state.ShellFiles[Sid][AppState.PendingTurnKey];
        Assert.Equal(["new.txt", "a.txt"], held.Select(f => f.Path));
        Assert.All(held, f => Assert.Equal("shell", f.Kind));
        Assert.Equal(2, held[0].Added);

        // A second Bash call that changes dirty.txt's diff counts it; one that changes nothing adds nothing.
        var later = Tree([" M dirty.txt", " M staged.txt", "?? new.txt", " M a.txt"],
            FileDiff("dirty.txt", "old", "more") + FileDiff("staged.txt", "s") + FileDiff("new.txt", "n1", "n2") + FileDiff("a.txt", "x"));
        send(Envelope(EventKind.PostTool, """{"tool_name":"Bash","agent_id":"ag1"}""", tree: later));
        send(Envelope(EventKind.PostTool, """{"tool_name":"Bash"}""", tree: later));
        held = state.ShellFiles[Sid][AppState.PendingTurnKey];
        Assert.Equal(["new.txt", "a.txt", "dirty.txt"], held.Select(f => f.Path));
        Assert.Equal("ag1", held[2].AgentId);

        // The done peek counts the shell files.
        send(Envelope(EventKind.Stop, "{}"));
        Assert.Equal("3 files", state.Peek!.Detail);
        Assert.Equal(2 + 1 + 2, state.Peek.Added);
    }

    [Fact]
    public void FirstBashReportWithoutABaselineOnlyBecomesTheBaseline()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.PostTool, """{"tool_name":"Bash"}""", tree: Tree(["?? x.txt"], FileDiff("x.txt", "1"))), _ => true);
        Assert.False(state.ShellFiles.ContainsKey(Sid));
        state.Receive(Envelope(EventKind.PostTool, """{"tool_name":"Bash"}""", tree: Tree(["?? x.txt", "?? y.txt"], FileDiff("x.txt", "1") + FileDiff("y.txt", "2"))), _ => true);
        Assert.Equal(["y.txt"], state.ShellFiles[Sid][AppState.PendingTurnKey].Select(f => f.Path));
    }

    [Fact]
    public void AFileBackToHeadCountsButACommitDoesNot()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.UserPrompt, """{"prompt":"go"}""", tree: Tree([" M a.txt", " M b.txt"], FileDiff("a.txt", "1") + FileDiff("b.txt", "2"))), _ => true);
        // a.txt reverted, same HEAD: it changed (back to HEAD, reversed).
        state.Receive(Envelope(EventKind.PostTool, """{"tool_name":"Bash"}""", tree: Tree([" M b.txt"], FileDiff("b.txt", "2"))), _ => true);
        var a = Assert.Single(state.ShellFiles[Sid][AppState.PendingTurnKey]);
        Assert.Equal("a.txt", a.Path);
        Assert.Equal(0, a.Added);
        Assert.Equal(1, a.Removed);
        // b.txt committed: HEAD moved, it left the list, nothing new.
        state.Receive(Envelope(EventKind.PostTool, """{"tool_name":"Bash"}""", tree: Tree([], "", head: "def")), _ => true);
        Assert.Single(state.ShellFiles[Sid][AppState.PendingTurnKey]);
    }

    [Fact]
    public void AWakeupPromptDoesNotStartATurn()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.UserPrompt, """{"prompt":"real","source":"user"}"""), _ => true);
        var started = state.TurnStarts[Sid];
        state.Receive(Envelope(EventKind.UserPrompt, """{"prompt":"<task-notification>","source":"task_notification"}"""), _ => true);
        Assert.Equal("real", state.TurnTitles[Sid]);
        Assert.Equal(started, state.TurnStarts[Sid]);
        Assert.Equal(SessionState.Working, state.Session(Sid)!.State);
    }

    [Fact]
    public void StopWithAgentsRunningWaitsForTheLastAgent()
    {
        var state = MakeState(new Preferences { PeekSeconds = 30 });
        Action<HookEnvelope> send = e => state.Receive(e, _ => true);
        send(Envelope(EventKind.UserPrompt, """{"prompt":"go"}"""));
        send(Envelope(EventKind.SubagentStart, """{"agent_id":"a1","agent_type":"Explore"}"""));
        Assert.Equal(1, state.RunningAgentCount);
        send(Envelope(EventKind.Stop, "{}"));
        Assert.Equal(SessionState.Working, state.Session(Sid)!.State);
        Assert.Equal("Thinking", state.Session(Sid)!.Verb);
        Assert.Null(state.Peek);

        send(Envelope(EventKind.SubagentStop, """{"agent_id":"a1","agent_type":"Explore"}"""));
        Assert.Equal(0, state.RunningAgentCount);
        Assert.Equal(SessionState.Done, state.Session(Sid)!.State);
        Assert.Equal(PeekKind.Done, state.Peek!.Kind);
        Assert.False(state.AgentsFor(Sid)[0].IsRunning);
    }

    [Fact]
    public void SubagentStopShowsTheAgentPeek()
    {
        var state = MakeState(new Preferences { PeekSeconds = 30 });
        state.Receive(Envelope(EventKind.SubagentStart, """{"agent_id":"a1","agent_type":"Explore"}"""), _ => true);
        state.Receive(Envelope(EventKind.SubagentStop, """{"agent_id":"a1"}"""), _ => true);
        Assert.Equal(PeekKind.Agent, state.Peek!.Kind);
        Assert.Equal("Explore finished", state.Peek.Title);
        Assert.Equal(0, state.Peek.ColorIndex);
    }

    [Fact]
    public void SessionEndDropsTheSessionAndAnswersNone()
    {
        var state = MakeState();
        var replies = new Replies();
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), replies.Handle);
        state.Receive(Envelope(EventKind.SessionEnd, "{}", id: "e2"), _ => true);
        Assert.Equal(Decision.None, Assert.Single(replies.Got)!.Decision);
        Assert.Empty(state.Pending);
        Assert.Null(state.Session(Sid));
        Assert.Equal(NotchMode.Closed, state.Mode);
    }

    [Fact]
    public void HeadlessRunsAreIgnored()
    {
        var state = MakeState();
        state.HeadlessIds.Add(Sid);
        var replies = new Replies();
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), replies.Handle);
        Assert.Equal(Decision.None, Assert.Single(replies.Got)!.Decision);
        Assert.Empty(state.Sessions);
        Assert.Empty(state.Pending);
    }

    [Fact]
    public void PlainCommitOpensTheCommitCardAndOtherToolsPassThrough()
    {
        var state = MakeState();
        var replies = new Replies();
        state.Receive(Envelope(EventKind.PreTool, """{"tool_name":"Bash","tool_input":{"command":"npm test"}}""", id: "t1"), replies.Handle);
        Assert.Equal(Decision.None, Assert.Single(replies.Got)!.Decision);
        Assert.Equal("Running", state.Session(Sid)!.Verb);

        state.Receive(Envelope(EventKind.PreTool, """{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix the peek\" && rm x"}}""", id: "t2"), replies.Handle);
        Assert.Equal(2, replies.Got.Count);
        Assert.Empty(state.Pending);

        state.Receive(Envelope(EventKind.PreTool, """{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix the peek\""}}""", id: "c1"), replies.Handle);
        var req = Assert.Single(state.Pending);
        Assert.Equal(PendingRequestKind.Commit, req.Kind);
        Assert.Equal("Fix the peek", req.Title);
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
    }

    [Fact]
    public void PlanRequestTakesItsHeadingAndTheLongDeadline()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.Permission,
            """{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan: Port the app\n\n1. Read\n2. Write","planFilePath":"C:\\x\\plan.md"},"permission_mode":"plan"}""",
            id: "pl1"), _ => true);
        var req = Assert.Single(state.Pending);
        Assert.Equal(PendingRequestKind.Plan, req.Kind);
        Assert.Equal("Port the app", req.Title);
        Assert.StartsWith("# Plan: Port the app", req.Detail);
        Assert.True((req.Deadline - req.ReceivedAt).TotalSeconds is > 297.9 and < 298.1);
        Assert.Equal("plan", state.Session(Sid)!.PermissionMode);

        // An empty plan whose file is outside the plans folder is not read.
        state.Receive(Envelope(EventKind.Permission,
            """{"tool_name":"ExitPlanMode","tool_input":{"plan":"","planFilePath":"C:\\Windows\\win.ini"}}""", id: "pl2", sid: "s2"), _ => true);
        var second = state.Pending.Single(p => p.Id == "pl2");
        Assert.Equal("Plan ready", second.Title);
        Assert.Equal("", second.Detail);
    }

    [Fact]
    public void StatuslineFillsFactsWithoutMakingASession()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.Statusline,
            """{"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1760000000},"seven_day":{"used_percentage":120}},"context_window":{"used_percentage":36,"context_window_size":1000000,"current_usage":{"input_tokens":10,"cache_read_input_tokens":300,"cache_creation_input_tokens":5,"output_tokens":7}},"model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.25}}"""),
            _ => true);
        Assert.Empty(state.Sessions);
        Assert.NotNull(state.LimitsUpdatedAt);
        Assert.Equal(42.5, state.Usage.FiveHourPercent);
        Assert.Equal(100, state.Usage.WeekPercent);
        Assert.Equal(ContractJson.FromUnixSeconds(1760000000), state.Usage.FiveHourResetsAt);
        var facts = state.Statusline[Sid];
        Assert.Equal(315, facts.ContextUsed);
        Assert.Equal(1000000, facts.ContextLimit);
        Assert.Equal("claude-fable-5", facts.Model);
        Assert.Equal(1.25, facts.CostUSD);
        Assert.Equal(7, facts.CurrentUsage!.Output);
    }

    [Fact]
    public void NotificationsMarkNeedsYouOrDone()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.UserPrompt, """{"prompt":"go"}"""), _ => true);
        state.Receive(Envelope(EventKind.Notification, """{"notification_type":"agent_needs_input","message":"Which one?"}"""), _ => true);
        Assert.Equal(SessionState.NeedsYou, state.Session(Sid)!.State);
        Assert.Equal("Which one?", state.Question!.Question);
        state.Receive(Envelope(EventKind.Notification, """{"notification_type":"idle_prompt"}"""), _ => true);
        Assert.Equal(SessionState.Done, state.Session(Sid)!.State);
    }

    [Fact]
    public void EscapeClosesTheCardAndNumbersPickTabs()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.UserPrompt, """{"prompt":"go"}"""), _ => true);
        state.OpenCard(CardTab.Sessions);
        Assert.Equal(NotchMode.Card, state.Mode);
        Assert.Equal(Sid, state.FocusedSessionId);
        Assert.True(state.HandleKey(NotchKey.Number(2)));
        Assert.Equal(CardTab.Changes, state.SelectedTab);
        Assert.True(state.TabMovedForward);
        Assert.Equal(CardTab.Changes, state.ToolLabel);
        Assert.True(state.HandleKey(NotchKey.PreviousTab));
        Assert.Equal(CardTab.Sessions, state.SelectedTab);
        Assert.False(state.TabMovedForward);
        Assert.True(state.HandleKey(NotchKey.Settings));
        Assert.Equal(CardTab.Settings, state.SelectedTab);
        Assert.True(state.HandleKey(NotchKey.Escape));
        Assert.Equal(CardTab.Sessions, state.SelectedTab);
        Assert.True(state.HandleKey(NotchKey.Escape));
        Assert.False(state.IsCardOpen);
        Assert.False(state.HandleKey(NotchKey.Escape));
    }

    [Fact]
    public void ARequestOpensAndClosesItsCard()
    {
        var state = MakeState();
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "p1"), _ => true);
        state.OpenCard();
        Assert.True(state.CardOpenedForRequest);
        Assert.IsType<CardContent.Request>(state.CardContent);
        state.AnswerKeysAllowedAt = DateTime.MinValue;
        Assert.True(state.HandleKey(NotchKey.Deny));
        Assert.False(state.IsCardOpen);
    }
}
