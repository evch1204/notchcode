// AppState.Requests.cs
// Port of Sources/notchcode/State/AppState+Requests.swift.
// Pending requests: the queue and the owner's answers. The diff inside a request card
// (toggleRequestDiff and friends) is ported by wave 1d in AppState.RequestDiff.cs;

using Notchcode.UI;

namespace Notchcode.State;

/// The owner's answer to a request: Allow (Commit), Deny (Skip), Always, or Edit.
public enum RequestAnswer { Allow, Deny, Always, Edit }

public sealed partial class AppState
{
    /// Revise's deny reason: Claude stays in plan mode and asks in the terminal.
    public const string RevisePlanReason
        = "The owner read the plan in notchcode and wants changes. Ask them what to change, then plan again.";

    /// Deny's reason.
    public const string DenyReason = "The owner denied this from notchcode.";

    /// Commit card Edit's deny reason: Claude asks the owner for a new message.
    public const string CommitEditReason
        = "The owner wants to change the commit message first. Ask them for the message, then commit again.";

    /// The hint shown when an answer lands after the transport's deadline.
    public const string TooLateHint = "Too late: the terminal asks";

    /// Posts a system notification for a blocking request (Prefs.SystemNotifications on).
    /// Set by the notifier wiring (App/SystemNotifier, wave 1b); null shows nothing. The
    /// notification's title and body are the request's headline and summary.
    internal Action<PendingRequest>? NotifyBlocking;

    /// Takes a request's system notification down again (by request id). Set with `NotifyBlocking`.
    internal Action<string>? RemoveBlockingNotification;

    // MARK: - Owner actions

    /// Every answer, key or click, comes through here. None counts before
    /// `AnswerKeysAllowedAt`: a press meant for the terminal, or a click as the card slides
    /// in under the pointer, must not answer a request the owner has not seen.
    public void Answer(RequestAnswer kind, PendingRequest request)
    {
        if (DateTime.UtcNow < AnswerKeysAllowedAt) return;
        switch (kind)
        {
            case RequestAnswer.Allow: Allow(request.Id); break;
            case RequestAnswer.Deny when request.Kind == PendingRequestKind.Plan: RevisePlan(request.Id); break;
            case RequestAnswer.Deny: Deny(request.Id); break;
            case RequestAnswer.Always when request.Kind == PendingRequestKind.Plan: ApproveAcceptingEdits(request.Id); break;
            case RequestAnswer.Always: AllowAlways(request.Id); break;
            case RequestAnswer.Edit: RequestCommitEdit(request.Id); break;
        }
    }

    private void Allow(string id)
        => Resolve(id, new HookReply { Id = id, Decision = Decision.Allow });

    private void Deny(string id)
        => Resolve(id, new HookReply { Id = id, Decision = Decision.Deny, Reason = DenyReason });

    /// A plan sent back stays in plan mode: Claude asks in the terminal what to change.
    private void RevisePlan(string id)
        => Resolve(id, new HookReply { Id = id, Decision = Decision.Deny, Reason = RevisePlanReason });

    private void AllowAlways(string id)
        => Resolve(id, new HookReply { Id = id, Decision = Decision.Allow, Always = true });

    /// Plan "Auto-accept": approve, and the session accepts edits from now on.
    private void ApproveAcceptingEdits(string id)
    {
        var acceptEdits = JsonValue.Object(
            ("type", JsonValue.String("setMode")),
            ("mode", JsonValue.String("acceptEdits")),
            ("destination", JsonValue.String("session")));
        Resolve(id, new HookReply
        {
            Id = id,
            Decision = Decision.Allow,
            Always = true,
            UpdatedPermissions = JsonValue.Array(acceptEdits),
        });
    }

    /// Commit card "Edit": let Claude know the owner wants a different message.
    private void RequestCommitEdit(string id)
        => Resolve(id, new HookReply { Id = id, Decision = Decision.Deny, Reason = CommitEditReason });

    // MARK: - Pending requests

    public void Enqueue(PendingRequest request, ReplyHandler reply)
    {
        // The plugin and Connect both installed: one tool call arrives twice. Keep the first;
        // the second hook falls back to Claude Code, which the first answer settles.
        if (request.ToolUseId is { } toolUseId
            && Pending.Any(p => p.SessionId == request.SessionId && p.ToolUseId == toolUseId && p.Id != request.Id))
        {
            reply(new HookReply { Id = request.Id, Decision = Decision.None });
            return;
        }
        if (Handlers.ContainsKey(request.Id))
        {
            // Same id twice: answer the old one so it is never left hanging.
            Resolve(request.Id, new HookReply { Id = request.Id, Decision = Decision.None });
        }
        Handlers[request.Id] = reply;
        Pending = Pending.Add(request);
        if (Pending.Count == 1) RequestRowCursor = 0;
        if (Prefs.SystemNotifications) NotifyBlocking?.Invoke(request);
        // The deadline is the transport's: it replies "none" and calls `TimedOut(requestId)`.
    }

    /// Replies exactly once and forgets the request. An answer means Claude moves on.
    /// A press that lands after the transport's deadline reached no one: the terminal still
    /// asks, so the session is marked the timed-out way and the card says so.
    public void Resolve(string id, HookReply reply)
    {
        if (!Handlers.TryGetValue(id, out var handler)) return;
        var sid = DropPending(id);
        bool delivered = handler(reply);
        if (sid is not null)
        {
            if (!delivered) Unanswered(sid);
            else if (reply.Decision != Decision.None) ClearNeedsYou(sid);
        }
        AfterPendingChange(sid);
        if (!delivered && reply.Decision != Decision.None) Flash(TooLateHint);
    }

    /// Forgets a request and its reply handler without replying. Returns its session id.
    public string? DropPending(string id)
    {
        if (!Handlers.Remove(id)) return null;
        var sid = Pending.FirstOrDefault(p => p.Id == id)?.SessionId;
        Pending = Pending.RemoveAll(p => p.Id == id);
        RemoveBlockingNotification?.Invoke(id);
        return sid;
    }

    /// State and card follow-up after a request left the queue.
    public void AfterPendingChange(string? sid)
    {
        if (sid is not null) Settle(sid);
        if (RequestDiff is not null && RequestDiff.RequestId != CurrentPending?.Id)
        {
            RequestDiff = null;
            RequestRowCursor = 0;
        }
        if (Pending.IsEmpty && IsCardOpen && CardOpenedForRequest)
        {
            CloseCard();
            return;
        }
        Refresh();
    }
}
