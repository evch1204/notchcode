// RequestActions.cs
// Port of Sources/notchcode/Features/Requests/RequestActions.swift.
// What a pending request offers and says: its actions (Deny · middle · Allow), its
// headline and summary, and the time left before its deadline. And the three action
// segments as the strip and the attention row draw them (Notch/StripView.swift's
// ActionStrip): Deny nearest the camera, Allow (popping in, the countdown draining along it)
// at the outer end.

using System.Windows;
using System.Windows.Controls;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Requests;

/// One action of a request, as the strip, the attention row and the footer show it.
public sealed record RequestAction(string Title, string? Key, string Help, ActionRole Role);

public static class RequestActions
{
    extension(PendingRequestKind kind)
    {
        /// Deny · middle · Allow for a permission (Deny · Always · Allow) or a commit
        /// (Skip · Edit · Commit). The one table every surface reads.
        public (RequestAction Deny, RequestAction Middle, RequestAction Allow) Actions => kind switch
        {
            PendingRequestKind.Permission => (
                new RequestAction("Deny", Theme.Keys.Delete, $"Deny ({Theme.Keys.Delete})", ActionRole.Deny),
                new RequestAction("Always", Theme.Keys.Always, $"Allow and remember ({Theme.Keys.Always})", ActionRole.Neutral),
                new RequestAction("Allow", Theme.Keys.Enter, $"Allow ({Theme.Keys.Enter})", ActionRole.Allow)),
            PendingRequestKind.Commit => (
                new RequestAction("Skip", Theme.Keys.Delete, $"Skip this commit ({Theme.Keys.Delete})", ActionRole.Deny),
                new RequestAction("Edit", Theme.Keys.Edit, $"Ask for a different message ({Theme.Keys.Edit})", ActionRole.Neutral),
                new RequestAction("Commit", Theme.Keys.Enter, $"Commit ({Theme.Keys.Enter})", ActionRole.Allow)),
            _ => (
                // "Revise", not "Keep planning": the open card's right wing has room for one short word.
                new RequestAction("Revise", Theme.Keys.Delete, $"Keep planning: Claude asks what to change ({Theme.Keys.Delete})", ActionRole.Deny),
                new RequestAction("Auto-accept", Theme.Keys.Always, $"Approve and auto-accept edits for this session ({Theme.Keys.Always})", ActionRole.Neutral),
                new RequestAction("Approve", Theme.Keys.Enter, $"Approve the plan ({Theme.Keys.Enter})", ActionRole.Allow)),
        };
    }

    extension(PendingRequest request)
    {
        /// Seconds left until the deadline at `date`, never below 0.
        public double Remaining(DateTime date) => Math.Max(0, (request.Deadline - date).TotalSeconds);

        /// Share of the request's time left at `date`, 1 → 0.
        public double RemainingFraction(DateTime date) =>
            request.Remaining(date) / Math.Max(1, (request.Deadline - request.ReceivedAt).TotalSeconds);

        /// "Allow Bash?" (an MCP tool by its own name), "Commit?" or "Plan ready".
        public string Headline => request.Kind switch
        {
            PendingRequestKind.Permission => $"Allow {Format.ToolName(request.Tool)}?",
            PendingRequestKind.Commit => "Commit?",
            _ => "Plan ready",
        };

        /// The command or path (an MCP tool's server leads it), the commit subject, or the plan's heading.
        public string Summary
        {
            get
            {
                if (request.Kind == PendingRequestKind.Commit) return request.Title;
                if (request.Kind == PendingRequestKind.Plan) return request.Detail.Length == 0 ? "" : request.Title;
                if (Format.McpServer(request.Tool) is not { } server) return request.Detail;
                return request.Detail.Length == 0 ? server : server + Theme.Glyphs.Separator + request.Detail;
            }
        }
    }
}

/// Deny · Always · Allow (or Skip · Edit · Commit, Revise · Auto-accept · Approve). Deny sits
/// nearest the camera; Allow, the primary, at the outer end. `allKeys`: the middle segment
/// and a plan's deny show their keycaps too (the attention row shows all three; the open
/// card's strip drops the ones that do not fit, and the footer carries them).
public sealed class RequestActionStrip : StackPanel
{
    public RequestActionStrip(AppState state, PendingRequest request, bool allKeys = false)
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        var actions = request.Kind.Actions;
        // A plan's titles fill the open card's wing, so its ⌫ keycap stays in the footer there.
        var denyKey = allKeys || request.Kind != PendingRequestKind.Plan ? actions.Deny.Key : null;
        var deny = new ActionSegment(actions.Deny.Title, denyKey, actions.Deny.Role,
            () => state.Answer(RequestAnswer.Deny, request)) { ToolTip = actions.Deny.Help };
        var middle = new ActionSegment(actions.Middle.Title, allKeys ? actions.Middle.Key : null, actions.Middle.Role,
            () => state.Answer(request.Kind == PendingRequestKind.Commit ? RequestAnswer.Edit : RequestAnswer.Always, request))
        { ToolTip = actions.Middle.Help, Margin = new Thickness(Theme.Size.ActionGap, 0, 0, 0) };
        var allow = new ActionSegment(actions.Allow.Title, actions.Allow.Key, actions.Allow.Role,
            () => state.Answer(RequestAnswer.Allow, request), countdown: request)
        { ToolTip = actions.Allow.Help, Margin = new Thickness(Theme.Size.ActionGap, 0, 0, 0) };
        Children.Add(deny);
        Children.Add(middle);
        Children.Add(PopIn.Apply(allow));
        Loaded += (_, _) =>
        {
            Transitions.UnfoldRight(deny, 0);
            Transitions.UnfoldRight(middle, 1);
            Transitions.UnfoldRight(allow, 2);
        };
    }
}
