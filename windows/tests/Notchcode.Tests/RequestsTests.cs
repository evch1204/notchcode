// RequestsTests.cs
// The answers' reply lines, byte for byte: plan Auto-accept, Revise, Always, commit Edit, deny.

using Notchcode.Core;
using Notchcode.State;
using static Notchcode.Tests.HookEventsTests;

namespace Notchcode.Tests;

public class RequestsTests
{
    private const string PlanPayload = """{"tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan: X\n\nDo it"}}""";

    private static (AppState State, Replies Replies, string Payload) Raise(EventKind kind, string payload, string id)
    {
        var state = MakeState();
        var replies = new Replies();
        state.Receive(Envelope(kind, payload, id: id), replies.Handle);
        state.AnswerKeysAllowedAt = DateTime.MinValue;
        return (state, replies, payload);
    }

    private static string Line(Replies replies, string id, string payload)
        => HookReply.ReplyLine(Assert.Single(replies.Got), id, JsonValue.Parse(payload));

    [Fact]
    public void PlanAutoAcceptSetsAcceptEditsForTheSession()
    {
        var (state, replies, payload) = Raise(EventKind.Permission, PlanPayload, "p");
        Assert.True(state.HandleKey(NotchKey.Always));
        Assert.Equal(
            """{"always":true,"decision":"allow","id":"p","updated_permissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]}""" + "\n",
            Line(replies, "p", payload));
    }

    [Fact]
    public void PlanApproveIsAPlainAllow()
    {
        var (state, replies, payload) = Raise(EventKind.Permission, PlanPayload, "p");
        state.Answer(RequestAnswer.Allow, state.CurrentPending!);
        Assert.Equal("""{"always":false,"decision":"allow","id":"p"}""" + "\n", Line(replies, "p", payload));
    }

    [Fact]
    public void PlanReviseDeniesWithTheAskMessage()
    {
        var (state, replies, payload) = Raise(EventKind.Permission, PlanPayload, "p");
        Assert.True(state.HandleKey(NotchKey.Deny));
        Assert.Equal(
            """{"always":false,"decision":"deny","id":"p","reason":"The owner read the plan in notchcode and wants changes. Ask them what to change, then plan again."}""" + "\n",
            Line(replies, "p", payload));
    }

    [Fact]
    public void AlwaysEchoesThePermissionSuggestions()
    {
        const string payload = """{"tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}""";
        var (state, replies, _) = Raise(EventKind.Permission, payload, "a/1");
        Assert.Equal(["Always allows Bash(npm test:*) in this project's local settings."], state.CurrentPending!.AlwaysRules);
        Assert.True(state.HandleKey(NotchKey.Always));
        Assert.Equal(
            """{"always":true,"decision":"allow","id":"a/1","updated_permissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"npm test:*","toolName":"Bash"}],"type":"addRules"}]}""" + "\n",
            Line(replies, "a/1", payload));
    }

    [Fact]
    public void DenySaysTheOwnerDenied()
    {
        const string payload = """{"tool_name":"Bash","tool_input":{"command":"rm x"}}""";
        var (state, replies, _) = Raise(EventKind.Permission, payload, "d");
        state.Answer(RequestAnswer.Deny, state.CurrentPending!);
        Assert.Equal("""{"always":false,"decision":"deny","id":"d","reason":"The owner denied this from notchcode."}""" + "\n", Line(replies, "d", payload));
    }

    [Fact]
    public void CommitEditAsksForANewMessageAndAlwaysIsNotACommitKey()
    {
        const string payload = """{"tool_name":"Bash","tool_input":{"command":"git commit -m \"x\""}}""";
        var (state, replies, _) = Raise(EventKind.PreTool, payload, "c");
        Assert.False(state.HandleKey(NotchKey.Always));
        Assert.Empty(replies.Got);
        Assert.True(state.HandleKey(NotchKey.Edit));
        Assert.Equal(
            """{"always":false,"decision":"deny","id":"c","reason":"The owner wants to change the commit message first. Ask them for the message, then commit again."}""" + "\n",
            Line(replies, "c", payload));
    }

    [Fact]
    public void TheSameToolCallTwiceKeepsTheFirst()
    {
        var state = MakeState();
        var first = new Replies();
        var second = new Replies();
        const string payload = """{"tool_name":"Bash","tool_use_id":"tu1","tool_input":{"command":"ls"}}""";
        state.Receive(Envelope(EventKind.Permission, payload, id: "r1"), first.Handle);
        state.Receive(Envelope(EventKind.Permission, payload, id: "r2"), second.Handle);
        Assert.Equal("r1", Assert.Single(state.Pending).Id);
        Assert.Empty(first.Got);
        Assert.Equal(Decision.None, Assert.Single(second.Got)!.Decision);
    }

    [Fact]
    public void BlockingRequestsNotifyWhenTheOwnerAskedForIt()
    {
        var state = MakeState(new Preferences { SystemNotifications = true });
        var posted = new List<string>();
        var removed = new List<string>();
        state.NotifyBlocking = r => posted.Add(r.Id);
        state.RemoveBlockingNotification = removed.Add;
        state.Receive(Envelope(EventKind.Permission, """{"tool_name":"Bash","tool_input":{"command":"ls"}}""", id: "n1"), _ => true);
        state.Cancel("n1");
        Assert.Equal(["n1"], posted);
        Assert.Equal(["n1"], removed);
    }
}
