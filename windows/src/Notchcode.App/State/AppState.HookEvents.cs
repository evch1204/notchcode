// AppState.HookEvents.cs
// Port of Sources/notchcode/State/AppState+HookEvents.swift.
// IHookEventSink: every hook envelope lands here and is handed to its handler.

using System.IO;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: - IHookEventSink

    public void Receive(HookEnvelope envelope, ReplyHandler reply)
    {
        var sid = envelope.ResolvedSessionId;

        // The status line refreshes on its own schedule: it carries numbers, not activity,
        // so it neither creates sessions nor moves "most recently active".
        if (envelope.Kind == EventKind.Statusline)
        {
            HandleStatusline(envelope.Payload, sid);
            return;
        }

        // Claude Code's own helper runs (sdk-cli) fire hooks too; PLAN says they never show.
        if (HeadlessIds.Contains(sid))
        {
            if (envelope.IsBlocking) reply(new HookReply { Id = envelope.Id, Decision = Decision.None });
            return;
        }

        HookSeenAt[sid] = DateTime.UtcNow;
        EndedAt.Remove(sid);

        if (envelope.Kind == EventKind.SessionEnd)
        {
            EndSession(sid);
            Refresh();
            return;
        }

        TouchSession(envelope);
        var payload = envelope.Payload;

        // Any sign that Claude moved on ends a notification's "needs you".
        switch (envelope.Kind)
        {
            case EventKind.UserPrompt or EventKind.PreTool or EventKind.PostTool or EventKind.Stop or EventKind.SubagentStart:
                ClearNeedsYou(sid);
                break;
        }
        switch (envelope.Kind)
        {
            case EventKind.UserPrompt or EventKind.PreTool or EventKind.PostTool or EventKind.SubagentStart or EventKind.Permission:
                OpenTurns.Add(sid);
                break;
            case EventKind.Stop:
                OpenTurns.Remove(sid);
                break;
        }

        switch (envelope.Kind)
        {
            case EventKind.Permission:
                HandlePermission(envelope, sid, reply);
                break;

            case EventKind.PreTool:
                HandlePreTool(envelope, sid, reply);
                break;

            case EventKind.PostTool:
                HandlePostTool(payload, sid);
                if (payload["tool_name"]?.StringValue == "Bash")
                {
                    HandleShellTree(envelope.Tree, sid, envelope.ResolvedCwd, payload["agent_id"]?.StringValue);
                    GitTreeReported(envelope.ResolvedCwd);
                }
                // Turns include subagent edits; the transcript may be the only record of them.
                ReloadTurns(sid);
                break;

            case EventKind.Notification:
                HandleNotification(payload, sid);
                break;

            case EventKind.Stop:
                if (Question?.SessionId == sid) Question = null;
                if (RunningAgents(sid).Count == 0)
                {
                    FinishTurn(sid);
                }
                else
                {
                    // Background agents still run: the session is not done, and their edits
                    // (Bash ones included) still count toward this turn. The last SubagentStop
                    // finishes it.
                    StoppedWithAgents.Add(sid);
                    UpdateSession(sid, s => s with { State = SessionState.Working, Verb = s.Verb ?? "Agents" });
                }
                ReloadTurns(sid);
                break;

            case EventKind.UserPrompt:
                HandleUserPrompt(envelope, sid);
                break;

            case EventKind.SessionStart:
                ReloadTurns(sid);
                ReloadAgents(sid);
                break;

            case EventKind.SubagentStart:
            {
                var agentId = payload["agent_id"]?.StringValue ?? envelope.Id;
                var type = payload["agent_type"]?.StringValue ?? "agent";
                var description = payload["description"]?.StringValue;
                AgentStarted(agentId, type, description, sid, DateTime.UtcNow);
                // The Agent tool call that started it is already in the transcript: pick up its description.
                ReloadAgents(sid);
                break;
            }

            case EventKind.SubagentStop:
            {
                var agentId = payload["agent_id"]?.StringValue ?? "";
                if (AgentStopped(agentId, payload["agent_type"]?.StringValue, sid, DateTime.UtcNow) is { } agent)
                {
                    ShowPeek(new Peek
                    {
                        Kind = PeekKind.Agent,
                        SessionId = sid,
                        Title = agent.Type + " finished",
                        ColorIndex = AgentColorIndex(agent),
                    });
                }
                // The last agent of a turn that already stopped: the turn is done now. Their own
                // tool hooks reopened it (`OpenTurns`), so it closes again here.
                if (StoppedWithAgents.Contains(sid) && RunningAgents(sid).Count == 0)
                {
                    OpenTurns.Remove(sid);
                    if (!Pending.Any(p => p.SessionId == sid)) FinishTurn(sid);
                }
                // The agent's edits are in the turns now.
                ReloadTurns(sid);
                break;
            }

            case EventKind.SessionEnd:
            case EventKind.Statusline:
                break;
        }
        Settle(sid);
        Refresh();
    }

    /// The hook went away before a reply: the owner answered in the terminal, or Claude Code
    /// gave up on the hook. Forget the request without replying, then recompute the state.
    public void Cancel(string requestId)
    {
        if (DropPending(requestId) is not { } sid) return;
        AfterPendingChange(sid);
    }

    public void TimedOut(string requestId)
    {
        if (DropPending(requestId) is not { } sid) return;
        Unanswered(sid);
        AfterPendingChange(sid);
    }

    /// A request left the queue without the hook getting an answer: the terminal prompt waits,
    /// so the session needs the owner unless another request of its own is still showing.
    public void Unanswered(string sid)
    {
        if (!Pending.Any(p => p.SessionId == sid)) MarkNeedsYou(sid);
    }

    /// A turn with no agent left running is done: the session shows done, the done peek
    /// counts the turn's files, and the turn's tallies start over. Stop, or the last
    /// SubagentStop after a Stop that found agents running.
    private void FinishTurn(string sid)
    {
        StoppedWithAgents.Remove(sid);
        UpdateSession(sid, s => s with { State = SessionState.Done, Verb = null });
        ShowPeek(DonePeek(sid));
        TurnFiles[sid] = [];
        TurnLineCounts.Remove(sid);
        TurnShellCounts.Remove(sid);
    }

    // MARK: - Envelope handling

    private void HandleUserPrompt(HookEnvelope envelope, string sid)
    {
        var payload = envelope.Payload;
        UpdateSession(sid, s => s with { State = SessionState.Working, Verb = "Thinking" });
        // A wakeup (a background agent's task notification, a loop or a schedule) fires
        // this hook too, with `source` other than "user". The transcript reader does not
        // count it as a turn, so neither does the app: the turn, its files and its tree
        // baseline carry on. No `source` (older Claude Code) is a prompt.
        if (payload["source"]?.StringValue is { } source && source != "user")
        {
            ReloadTurns(sid);
            return;
        }
        var prompt = payload["prompt"]?.StringValue ?? "";
        StoppedWithAgents.Remove(sid);
        // Shell changes still held for the previous turn were made before this prompt,
        // so the newest transcript turn is theirs.
        if (ShellFiles.TryGetValue(sid, out var inner) && inner.TryGetValue(PendingTurnKey, out var held))
        {
            ShellFiles = ShellFiles.SetItem(sid, inner.Remove(PendingTurnKey));
            if (TurnsBySession.TryGetValue(sid, out var turns) && turns.Count > 0)
            {
                var newest = turns.Aggregate((a, b) => b.StartedAt >= a.StartedAt ? b : a);
                AttachShellFiles(held, sid, newest.Id);
            }
        }
        TurnStarts = TurnStarts.SetItem(sid, DateTime.UtcNow);
        TurnTitles = TurnTitles.SetItem(sid, prompt);
        TurnFiles[sid] = [];
        TurnLineCounts.Remove(sid);
        TurnShellCounts.Remove(sid);
        // The turn's baseline: what a Bash call's report is compared against. No report
        // (not a git work tree) means nothing to compare.
        if (envelope.Tree is { } tree) TreeSnapshots[sid] = UnifiedDiff.Snapshot(tree);
        else TreeSnapshots.Remove(sid);
        if (Question?.SessionId == sid) Question = null;
        ReloadTurns(sid);
    }

    private void HandlePermission(HookEnvelope envelope, string sessionId, ReplyHandler reply)
    {
        var payload = envelope.Payload;
        var tool = payload["tool_name"]?.StringValue ?? "Tool";
        var input = payload["tool_input"];
        var now = DateTime.UtcNow;
        if (envelope.IsPlanRequest)
        {
            var markdown = PlanMarkdown(input);
            Enqueue(new PendingRequest
            {
                Id = envelope.Id,
                Kind = PendingRequestKind.Plan,
                SessionId = sessionId,
                Tool = tool,
                Title = HookText.PlanTitle(markdown) ?? "Plan ready",
                Detail = markdown,
                Reason = null,
                ToolUseId = payload["tool_use_id"]?.StringValue,
                ReceivedAt = now,
                Deadline = now.AddSeconds(Theme.Timing.ReplyDeadline(plan: true)),
            }, reply);
            UpdateSession(sessionId, s => s with { State = SessionState.NeedsYou });
            return;
        }
        var request = new PendingRequest
        {
            Id = envelope.Id,
            Kind = PendingRequestKind.Permission,
            SessionId = sessionId,
            Tool = tool,
            Title = HookText.PermissionTitle(tool),
            Detail = HookText.PermissionDetail(tool, input),
            Reason = HookText.PermissionReason(payload),
            AlwaysRules = HookText.AlwaysRules(payload),
            ToolUseId = payload["tool_use_id"]?.StringValue,
            ReceivedAt = now,
            Deadline = now.AddSeconds(Theme.Timing.ReplyDeadline(plan: false)),
        };
        // A file change: show what it would do, and name the file in the title.
        if (HookText.ProposedChange(tool, input, envelope.ResolvedCwd, ReadsLocalFiles) is { } proposed)
        {
            request = request with { Files = [proposed.File], Title = proposed.Title, Detail = proposed.File.Path };
        }
        Enqueue(request, reply);
        UpdateSession(sessionId, s => s with { State = SessionState.NeedsYou });
    }

    /// An `ExitPlanMode` input's Markdown: `plan`, else the file at `planFilePath` (up to 1 MB,
    /// and only under %USERPROFILE%\.claude\plans\) when the app reads local files; "" when
    /// neither gives text.
    private string PlanMarkdown(JsonValue? input)
    {
        if (input?["plan"]?.StringValue is { Length: > 0 } plan) return plan;
        if (!ReadsLocalFiles || input?["planFilePath"]?.StringValue is not { } path
            || !HookText.IsUnderPlansDirectory(path)) return "";
        using var stream = RegularFile.Open(path, Theme.Limits.PlanFileBytes);
        if (stream is null) return "";
        try
        {
            using var reader = new StreamReader(stream, System.Text.Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            return reader.ReadToEnd();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return ""; }
    }

    private void HandlePreTool(HookEnvelope envelope, string sessionId, ReplyHandler reply)
    {
        var payload = envelope.Payload;
        var tool = payload["tool_name"]?.StringValue ?? "";
        var command = payload["tool_input"]?["command"]?.StringValue ?? "";
        var trimmed = command.Trim();

        // Commit answers for the whole command, so only a plain `git commit` gets the commit
        // card. Anything riding on it goes through the permission card, which shows it all.
        if (tool == "Bash" && HookText.IsPlainCommit(trimmed))
        {
            var now = DateTime.UtcNow;
            // A file with no recorded patch still opens to its snippet.
            var latestFiles = (Turns(sessionId).FirstOrDefault()?.Files ?? [])
                .Select(f => f.Patch.Count == 0 ? f with { Patch = f.Snippet } : f)
                .ToList();
            Enqueue(new PendingRequest
            {
                Id = envelope.Id,
                Kind = PendingRequestKind.Commit,
                SessionId = sessionId,
                Tool = tool,
                Title = HookText.CommitSubject(trimmed) ?? "git commit",
                Detail = trimmed,
                Reason = payload["tool_input"]?["description"]?.StringValue,
                Files = latestFiles,
                ToolUseId = payload["tool_use_id"]?.StringValue,
                ReceivedAt = now,
                Deadline = now.AddSeconds(Theme.Timing.ReplyDeadline(plan: false)),
            }, reply);
            UpdateSession(sessionId, s => s with { State = SessionState.NeedsYou });
            return;
        }

        reply(new HookReply { Id = envelope.Id, Decision = Decision.None });
        UpdateSession(sessionId, s => s with { State = SessionState.Working, Verb = HookText.Verb(tool) });
    }

    private void HandlePostTool(JsonValue payload, string sessionId)
    {
        var tool = payload["tool_name"]?.StringValue ?? "";
        if (tool is not ("Edit" or "Write" or "MultiEdit")) return;

        var response = payload["tool_response"];
        var input = payload["tool_input"];
        if ((response?["filePath"]?.StringValue ?? input?["file_path"]?.StringValue) is not { } path) return;

        int? added = null;
        int? removed = null;
        if (HookText.PatchCounts(response?["structuredPatch"]) is { } counts)
        {
            added = counts.Added;
            removed = counts.Removed;
        }
        else if (tool == "Write" && input?["content"]?.StringValue is { } content)
        {
            added = content.FileLines().Count;
            removed = 0;
        }

        var files = TurnFiles.TryGetValue(sessionId, out var f) ? f : [];
        if (!files.Contains(path)) files.Add(path);
        TurnFiles[sessionId] = files;
        int position = files.IndexOf(path) + 1;
        string? detail = files.Count > 1 ? $"{position} of {files.Count}" : null;
        var totals = TurnLineCounts.TryGetValue(sessionId, out var t) ? t : (Added: 0, Removed: 0);
        TurnLineCounts[sessionId] = (totals.Added + (added ?? 0), totals.Removed + (removed ?? 0));

        UpdateSession(sessionId, s => s with { State = SessionState.Working, Verb = "Thinking" });
        if (Prefs.PeekEdits)
        {
            ShowPeek(new Peek
            {
                Kind = PeekKind.Edit,
                SessionId = sessionId,
                Title = Format.FileName(path),
                Added = added,
                Removed = removed,
                Detail = detail,
            });
        }
        ReloadTurns(sessionId);
    }

    private void HandleNotification(JsonValue payload, string sessionId)
    {
        var type = payload["notification_type"]?.StringValue ?? "";
        var message = payload["message"]?.StringValue ?? "";
        switch (type)
        {
            case "idle_prompt":
            case "agent_completed":
                // Claude finished and waits for the owner to type: that is done, not blocked.
                ClearNeedsYou(sessionId);
                OpenTurns.Remove(sessionId);
                UpdateSession(sessionId, s => s with { State = SessionState.Done, Verb = null });
                break;
            case var _ when type == "permission_prompt" || type == "agent_needs_input" || type.StartsWith("elicitation", StringComparison.Ordinal):
                OpenTurns.Add(sessionId);
                MarkNeedsYou(sessionId);
                if (type == "agent_needs_input" && message.Length > 0)
                {
                    Question = new QuestionPreview { SessionId = sessionId, Question = message, Options = [] };
                    FillQuestionOptions(sessionId);
                    ReloadTurns(sessionId);
                }
                break;
        }
    }
}
