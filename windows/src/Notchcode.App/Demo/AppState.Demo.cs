// AppState.Demo.cs
// Port of Sources/notchcode/Demo/AppState+Demo.swift: hooks DemoScript uses to set up sample
// state directly.

using System.Windows.Threading;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: - Hooks for DemoScript

    /// An envelope as the pipe would deliver it. The demo has no pipe, so a blocking one gets
    /// the transport's deadline here: past it the request goes the timed-out way.
    internal void ReceiveDemo(HookEnvelope envelope)
    {
        Receive(envelope, _ => true);
        if (!envelope.IsBlocking) return;
        string id = envelope.Id;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.ReplyDeadline(envelope.IsPlanRequest)) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            TimedOut(id);
        };
        timer.Start();
    }

    internal void MutateSession(string id, Func<Session, Session> change)
    {
        int index = Sessions.FindIndex(s => s.Id == id);
        if (index < 0) return;
        Sessions = Sessions.SetItem(index, change(Sessions[index]));
        Refresh();
    }

    internal void SetFiles(IReadOnlyList<FileChange> files, string requestId)
    {
        int index = Pending.FindIndex(p => p.Id == requestId);
        if (index < 0) return;
        Pending = Pending.SetItem(index, Pending[index] with { Files = files });
    }

    internal void SetTurns(IReadOnlyList<TranscriptTurn> turns, string sessionId)
    {
        TurnsBySession = TurnsBySession.SetItem(sessionId, [.. turns]);
        RecomputeUsage();
    }

    internal void SeedTurnFiles(IEnumerable<string> paths, string sessionId) => TurnFiles[sessionId] = [.. paths];

    internal void SetAgentDescription(string description, string agentId, string sessionId)
    {
        string stored = AgentKeys.TryGetValue(agentId, out var key) ? key : agentId;
        if (!Agents.TryGetValue(sessionId, out var list)) return;
        int index = list.FindIndex(a => a.Id == stored);
        if (index < 0) return;
        Agents = Agents.SetItem(sessionId, list.SetItem(index, list[index] with { Description = description }));
    }

    /// What Claude Code's usage cache and `claude -p /usage` would say, matching the demo's
    /// status line. WAVE 2: the macOS demo seeds `PlanUsage` and `UsageBehaviors` here
    /// (61% / 34%, a Fable week at 41%, the 24 h and 7 d breakdowns); those types are 1c's
    /// stubs until Features/Usage lands, so only the recompute runs.
    internal void SeedDemoPlanUsage() => RecomputeUsage();

    internal void SetQuestion(QuestionPreview? preview)
    {
        Question = preview;
        Refresh();
    }
}
