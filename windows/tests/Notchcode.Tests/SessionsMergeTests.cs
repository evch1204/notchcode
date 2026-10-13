// SessionsMergeTests.cs
// AppState.TranscriptsChanged: sessions found on disk merged with what hooks said, the
// Windows way (cwds that differ only in case or slashes are one folder), headless helper runs
// dropped, the 2 h idle cutoff, and a session ended by SessionEnd revived only by newer activity.

using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Tests;

public class SessionsMergeTests
{
    // Folders that do not exist: git and the transcript reader find nothing there.
    private const string Cwd = @"C:\nc-test-missing\repo";

    private static DiscoveredSession Found(string id, string cwd, double ageSeconds, SessionState state = SessionState.Working,
                                           bool headless = false, string? prompt = null)
    {
        var at = DateTime.UtcNow.AddSeconds(-ageSeconds);
        return new DiscoveredSession
        {
            Id = id, Cwd = cwd, TranscriptPath = Path.Combine(@"C:\nc-test-missing\projects", id + ".jsonl"),
            StartedAt = at.AddMinutes(-5), LastActivityAt = at, State = state, Verb = state == SessionState.Working ? "Thinking" : null,
            LastPrompt = prompt, IsHeadless = headless,
        };
    }

    [Fact]
    public void CwdsThatDifferOnlyInCaseOrSlashesAreOneFolder()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        state.TranscriptsChanged([
            Found("old", Cwd, 60),
            Found("new", "c:/nc-test-missing/REPO/", 10),
        ]);
        var older = state.Session("old")!;
        var newer = state.Session("new")!;
        Assert.True(state.IsAmbiguous(older));
        Assert.True(state.IsNewest(newer));
        Assert.False(state.IsNewest(older));
        Assert.Single(state.SessionGroups);
        Assert.True(Paths.CwdComparer.Equals(@"C:\x\y\", "c:/X/Y"));
        Assert.False(Paths.CwdComparer.Equals(@"C:\x\y", @"C:\x\yz"));
        Assert.Equal(@"C:\", Paths.CwdKey("c:/"));
    }

    [Fact]
    public void HeadlessRunsAndOldSessionsNeverShow()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        state.TranscriptsChanged([
            Found("mine", Cwd, 30, prompt: "Fix it"),
            Found("helper", Cwd, 5, headless: true, prompt: "Generate a short git branch name"),
            Found("stale", @"C:\nc-test-missing\other", Theme.Timing.SessionIdleCutoff + 60, SessionState.Idle),
        ]);
        Assert.Equal(["mine"], state.Sessions.Select(s => s.Id));
        Assert.Equal("repo", state.Session("mine")!.WorktreeName);
        Assert.Equal("Fix it", state.TurnTitles["mine"]);
        // The helper's hooks are ignored from now on, blocking ones answered none.
        var replies = new HookEventsTests.Replies();
        state.Receive(HookEventsTests.Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"x"}}""", id: "h1", sid: "helper"), replies.Handle);
        Assert.Equal(Decision.None, Assert.Single(replies.Got)!.Decision);
        Assert.Null(state.Session("helper"));
    }

    [Fact]
    public void AnEndedSessionComesBackOnlyWithNewerActivity()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        state.TranscriptsChanged([Found("s", Cwd, 20)]);
        state.Receive(HookEventsTests.Envelope(EventKind.SessionEnd, "{}", sid: "s"), _ => true);
        Assert.Equal(SessionState.Idle, state.Session("s")!.State);

        // The transcript's last line is older than the end: it stays idle.
        state.TranscriptsChanged([Found("s", Cwd, 20)]);
        Assert.Equal(SessionState.Idle, state.Session("s")!.State);

        // New activity after the end (the owner resumed it): the transcript's state again.
        state.TranscriptsChanged([Found("s", Cwd, -5)]);
        Assert.Equal(SessionState.Working, state.Session("s")!.State);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void AnAgentSeenByTheHookAndTheTranscriptIsOneAgent(bool hookFirst)
    {
        var state = HookEventsTests.MakeState();
        state.Receive(HookEventsTests.Envelope(EventKind.SessionStart, "{}", sid: "m"), _ => true);
        var at = DateTime.UtcNow.AddSeconds(-20);
        var fromTranscript = new Agent { Id = "toolu_01", SessionId = "m", Type = "Explore", Description = "Look around", StartedAt = at.AddSeconds(1) };
        if (hookFirst)
        {
            state.AgentStarted("agent-7", "Explore", null, "m", at);
            state.MergeTranscriptAgents([fromTranscript], "m");
        }
        else
        {
            state.MergeTranscriptAgents([fromTranscript], "m");
            state.AgentStarted("agent-7", "Explore", null, "m", at);
        }
        var agent = Assert.Single(state.AgentsFor("m"));
        Assert.Equal("Look around", agent.Description);
        Assert.True(agent.IsRunning);
        // The hook's stop, by its own id, ends that one agent.
        Assert.NotNull(state.AgentStopped("agent-7", "Explore", "m", DateTime.UtcNow));
        Assert.Empty(state.RunningAgents("m"));
        // A later transcript read (still running there) does not bring it back.
        state.MergeTranscriptAgents([fromTranscript], "m");
        Assert.Empty(state.RunningAgents("m"));
    }

    [Fact]
    public void TwoSessionsRequestsQueueAndAnswerSeparately()
    {
        var state = HookEventsTests.MakeState();
        var a = new HookEventsTests.Replies();
        var b = new HookEventsTests.Replies();
        state.Receive(HookEventsTests.Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"one"}}""", id: "ra", sid: "A"), a.Handle);
        state.Receive(HookEventsTests.Envelope(EventKind.Permission, """{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Ship it"}}""", id: "rb", sid: "B"), b.Handle);
        Assert.Equal(["ra", "rb"], state.Pending.Select(p => p.Id));
        Assert.Equal("ra", state.CurrentPending!.Id);
        Assert.True((state.Pending[1].Deadline - state.Pending[1].ReceivedAt).TotalSeconds is > 297.9 and < 298.1);

        // Inside the key guard nothing counts; after it, the first request is answered first.
        state.Answer(RequestAnswer.Allow, state.Pending[0]);
        Assert.Empty(a.Got);
        state.AnswerKeysAllowedAt = DateTime.MinValue;
        state.Answer(RequestAnswer.Deny, state.Pending[0]);
        Assert.Equal(Decision.Deny, Assert.Single(a.Got)!.Decision);
        Assert.Equal("rb", state.CurrentPending!.Id);
        Assert.Equal(SessionState.NeedsYou, state.Session("B")!.State);

        // The plan's deadline passes in the transport: dropped the timed-out way, no reply.
        state.TimedOut("rb");
        Assert.Empty(b.Got);
        Assert.Empty(state.Pending);
        Assert.Equal(SessionState.NeedsYou, state.Session("B")!.State);
    }
}
