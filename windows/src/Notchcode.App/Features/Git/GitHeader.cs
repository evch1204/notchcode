// GitHeader.cs
// Port of Sources/notchcode/Features/Git/GitHeader.swift.
// The Git tool's header row: the target pill, the branch, the status line (where it stands
// against its upstream, and where every result lands), and the sync pill (Publish, Pull,
// Push or Fetch; pulsing while git writes), which stays put and arms with ⏎ for its confirm.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Git;

// MARK: - Header

/// "notchcode › seadevil ▾ W   user-friendly-distribution-plan   [Push 3  P]", or a write's
/// result in the status's place. While a sync is asked the pill stays here armed with ⏎ (the
/// question is in the stage); while any write runs it pulses. A branch checked out nowhere:
/// "notchcode › design/toolbar ▾ W   not checked out · 4 commits ahead of main".
public sealed class GitHeader : Grid
{
    private readonly RowStack row = new() { Spacing = Theme.Size.SpaceM };
    private UIElement? targetPill;
    private RowStack? rest;
    private readonly Grid statusHost = new();
    private readonly Grid pillHost = new();
    private TrimText? branchText;
    private TextBlock? notFocused;
    private string? targetKey;
    private string? statusKey;
    private UIElement? statusElement;
    private string? pillKey;
    private FrameworkElement? pillElement;
    private int? pillCount;
    private string? lastFailure;
    private bool? wasOpen;

    /// The target pill, whose frame the picker's repository pill takes (GitTab morphs them).
    public FrameworkElement? TargetPill => targetPill as FrameworkElement;

    public GitHeader()
    {
        Height = Theme.Size.GitHeaderHeight;
        row.Margin = new Thickness(Theme.Size.RowHPadding, 0, Theme.Size.RowHPadding, 0);
        Children.Add(row);
    }

    /// `open`: the picker is open, the pill has become the picker's repository pill and the
    /// rest has slid out to the right. The row keeps its height.
    public void Update(AppState state, GitSnapshot snap, bool open)
    {
        bool openChanged = wasOpen is not null && wasOpen != open;
        bool first = wasOpen is null;
        wasOpen = open;

        // The target pill: fades as the picker's repository pill takes its place.
        var parts = state.GitTargetParts;
        var key = parts.Repo + "|" + parts.Place + "|" + parts.PlaceIsBranch;
        if (targetPill is null || key != targetKey)
        {
            var old = targetPill;
            targetPill = new GitTargetPill(parts, state.ToggleGitPicker);
            RowStack.SetPriority(targetPill, 2);
            targetKey = key;
            if (old is not null) row.Children.Remove(old);
            row.Children.Insert(0, targetPill);
        }
        if (rest is null)
        {
            rest = BuildRest();
            Kit.Flex(rest);
            row.Children.Add(rest);
        }
        UpdateRest(state, snap);

        if (first)
        {
            targetPill.Visibility = open ? Visibility.Hidden : Visibility.Visible;
            rest.Visibility = open ? Visibility.Hidden : Visibility.Visible;
        }
        else if (openChanged)
        {
            var pill = (FrameworkElement)targetPill;
            if (open)
            {
                Transitions.Remove(pill, TransitionSpec.Opacity(Theme.Motion.PickerPill, Theme.Motion.PickerPill), () => pill.Visibility = Visibility.Hidden);
                Transitions.Remove(rest, Theme.Motion.PickerHeaderTransition, () => rest.Visibility = Visibility.Hidden);
            }
            else
            {
                pill.Visibility = Visibility.Visible;
                rest.Visibility = Visibility.Visible;
                Transitions.Insert(pill, TransitionSpec.Opacity(Theme.Motion.PickerPill, Theme.Motion.PickerPill));
                Transitions.Insert(rest, Theme.Motion.PickerHeaderTransition);
            }
        }
        IsHitTestVisible = !open;
    }

    /// The branch, the status and the sync pill.
    private RowStack BuildRest()
    {
        branchText = new TrimText("", Theme.Fonts.Mono, Theme.Brushes.GitBranch, TrimMode.Middle);
        RowStack.SetPriority(branchText, 1);
        notFocused = Kit.Text("not the focused session", Theme.Fonts.Caption, Theme.Brushes.GitTargetNote, TextTrimming.None);
        var middle = Kit.Flex(new RowStack(Theme.Size.SpaceM, statusHost, notFocused));
        return new RowStack(Theme.Size.SpaceM, branchText, middle, pillHost);
    }

    private void UpdateRest(AppState state, GitSnapshot snap)
    {
        var phase = state.GitPhase;
        branchText!.Visibility = snap.CheckedOut ? Visibility.Visible : Visibility.Collapsed;
        branchText.Text = snap.Branch ?? "detached HEAD";
        notFocused!.Visibility = snap.CheckedOut && !state.GitTargetIsFocused ? Visibility.Visible : Visibility.Collapsed;
        Status(state, phase);
        Pill(state, snap, phase);
    }

    /// The status line: a result drops the old line and rises in, and after its hold drops
    /// back out for the status (the stage swap's transition).
    private void Status(AppState state, GitPhase phase)
    {
        string text;
        FontSpec font;
        Brush color;
        switch (phase)
        {
            case GitPhase.Done done:
                (text, font, color) = (done.Message, Theme.Fonts.CaptionMedium, Theme.Brushes.GitPushed);
                break;
            case GitPhase.Failed failed:
                if (failed.Op == GitOp.Commit && state.GitDraft.Composing)
                    // The form says why, next to its Commit pill.
                    (text, font, color) = (state.GitStatusText, Theme.Fonts.Caption, Theme.Brushes.GitStatus);
                else
                    (text, font, color) = (failed.Message, Theme.Fonts.Caption, Theme.Brushes.GitError);
                break;
            default:
                // The confirm asks in the stage; the status stays what it was.
                (text, font, color) = (state.GitStatusText, Theme.Fonts.Caption, Theme.Brushes.GitStatus);
                break;
        }
        var key = text + "|" + font.Weight + "|" + color;
        if (key == statusKey) return;
        bool animate = statusKey is not null;
        statusKey = key;
        if (statusElement is FrameworkElement old)
        {
            if (animate) Transitions.Remove(old, Theme.Motion.PaneSwapTransition, () => statusHost.Children.Remove(old));
            else statusHost.Children.Remove(old);
        }
        statusElement = null;
        if (text.Length == 0) return;
        var line = Kit.Text(text, font, color);
        line.ToolTip = text;
        line.HorizontalAlignment = HorizontalAlignment.Left;
        statusHost.Children.Add(line);
        statusElement = line;
        if (animate) Transitions.Insert(line, Theme.Motion.PaneSwapTransition);
    }

    /// The sync pill: "Push 3  P", "Pull 2  P", "Publish 4  P" in white, "Fetch  P" dark;
    /// while a publish, push or pull is asked it stays here, pops once and its keycap reads ⏎
    /// (one place to press: it or ⏎ runs the sync); pulsing while any write runs; a check and
    /// "Pushed" while a sync's result holds, so it cannot ask again for the commits just sent.
    /// After a commit or an undo the plain pill stays. The looks overlap so each swap is a
    /// crossfade in place. Its count pops when it changes; a failed sync shakes it once.
    private void Pill(AppState state, GitSnapshot snap, GitPhase phase)
    {
        var op = state.GitSyncOp;
        var verb = state.GitSyncVerb;
        bool enabled = state.GitCanSync;
        var role = enabled && op != GitOp.Fetch ? ActionRole.Allow : ActionRole.Neutral;
        GitOp? running = null, done = null;
        bool confirming = false;
        switch (phase)
        {
            case GitPhase.Running r: running = r.Op; break;
            case GitPhase.Done d when d.Op is not (GitOp.Commit or GitOp.Undo): done = d.Op; break;
            case GitPhase.Confirming: confirming = true; break;
        }
        int? count = state.GitSyncCount;
        string look = running is { } ro ? "run|" + ro
            : done is { } dn ? "done|" + dn
            : confirming ? "confirm|" + (phase.OpValue?.Verb ?? verb)
            : "plain|" + verb + "|" + role + "|" + enabled;
        FrameworkElement Plain() => new ActionSegment(verb, Theme.Keys.Push, role, state.PressGitPill, count)
        {
            Enabled = enabled,
            Opacity = enabled ? 1 : Theme.Opacity.Disabled,
            ToolTip = enabled ? Help(snap, op) : state.GitStatusText,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        if (look != pillKey)
        {
            bool animate = pillKey is not null;
            pillKey = look;
            FrameworkElement next;
            if (running is { } r1) next = new GitRunningPill(r1.RunningTitle);
            else if (done is { } d1) next = new GitDonePill(d1.DoneTitle);
            else if (confirming)
            {
                var armed = new ActionSegment(phase.OpValue?.Verb ?? verb, Theme.Keys.Enter, ActionRole.Allow, state.PressGitPill, count)
                {
                    ToolTip = state.GitConfirmText,
                };
                next = animate ? PopIn.Apply(armed) : armed;
            }
            else
            {
                next = Plain();
            }
            next.HorizontalAlignment = HorizontalAlignment.Right;
            if (pillElement is { } old)
            {
                if (animate) Transitions.Remove(old, TransitionSpec.Opacity(Theme.Motion.StageSwap, Theme.Motion.StageSwap), () => pillHost.Children.Remove(old));
                else pillHost.Children.Remove(old);
            }
            pillHost.Children.Add(next);
            if (animate) Transitions.Insert(next, TransitionSpec.Opacity(Theme.Motion.StageSwap, Theme.Motion.StageSwap));
            pillElement = next;
            pillCount = count;
        }
        else if (pillElement is ActionSegment && count != pillCount)
        {
            // `.countPop(count)`: the same pill with its new count, popped in place (no crossfade).
            var old = pillElement;
            var next = confirming
                ? new ActionSegment(phase.OpValue?.Verb ?? verb, Theme.Keys.Enter, ActionRole.Allow, state.PressGitPill, count)
                    { ToolTip = state.GitConfirmText, HorizontalAlignment = HorizontalAlignment.Right }
                : Plain();
            int index = pillHost.Children.IndexOf(old);
            pillHost.Children.Remove(old);
            pillHost.Children.Insert(Math.Max(0, index), next);
            pillElement = next;
            if (pillCount is not null || count is not null) next.Loaded += (_, _) => Transitions.CountPop(next);
            pillCount = count;
        }
        // A failed publish, push, pull or fetch's message: the pill shakes when one arrives.
        string? failure = phase is GitPhase.Failed f && f.Op is not (GitOp.Commit or GitOp.Undo) ? f.Message : null;
        if (failure is not null && failure != lastFailure && !Theme.Motion.ReduceMotion) Transitions.Shake(pillHost);
        lastFailure = failure;
    }

    private static string Help(GitSnapshot snap, GitOp? op)
    {
        var remote = snap.Remote ?? "";
        return op switch
        {
            GitOp.Fetch => "Fetch from " + remote,
            GitOp.Pull => "Pull from " + (snap.Upstream ?? remote) + " (asks first)",
            _ => (op ?? GitOp.Push).Verb + " this branch (asks first)",
        };
    }
}

/// "notchcode › seadevil ▾  W": the repository dim, then the worktree folder in ink (or the
/// branch in mono when it is checked out nowhere); a press opens the picker.
public sealed class GitTargetPill : SegmentButton
{
    public GitTargetPill((string? Repo, string Place, bool PlaceIsBranch) parts, Action action)
        : base(Label(parts), Theme.Brushes.NeutralActionFill, click: action)
    {
        MaxWidth = Theme.Size.GitTargetMaxWidth;
        VerticalAlignment = VerticalAlignment.Center;
        ToolTip = $"Choose the branch ({Theme.Keys.Worktree})";
    }

    private static UIElement Label((string? Repo, string Place, bool PlaceIsBranch) parts)
    {
        var path = new RowStack { Spacing = Theme.Size.SpaceS };
        if (parts.Repo is { } repo)
        {
            // `.lineLimit(1)` without priority: the repository gives way before the place does.
            path.Children.Add(new TrimText(repo, Theme.Fonts.CaptionMedium, Theme.Brushes.GitTargetRepo, TrimMode.Tail));
            path.Children.Add(Kit.Text(Theme.Glyphs.PathChevron, Theme.Fonts.Caption, Theme.Brushes.GitTargetRepo, TextTrimming.None));
        }
        var place = new TrimText(parts.Place, parts.PlaceIsBranch ? Theme.Fonts.MonoCaption : Theme.Fonts.Action, Theme.Brushes.GitTargetPlace, TrimMode.Middle);
        RowStack.SetPriority(place, 1);
        path.Children.Add(place);
        path.Children.Add(Kit.Text(Theme.Glyphs.PickerChevron, Theme.Fonts.Tiny, Theme.Brushes.GitTargetRepo, TextTrimming.None));
        var label = new RowStack(Theme.Size.ActionKeyGap, path, new InlineKeycap(Theme.Keys.Worktree))
        {
            Margin = new Thickness(Theme.Size.ActionHPadding, 0, Theme.Size.ActionHPadding, 0),
        };
        return new Grid { Height = Theme.Size.ActionHeight, Children = { label } };
    }
}

/// The pill while git writes: Claude's pulsing spark and "Pushing", "Pulling", "Committing",
/// not pressable. The commit form's Commit pill turns into it too.
public sealed class GitRunningPill : SegmentButton
{
    public GitRunningPill(string title)
        : base(new RowStack(Theme.Size.ActionKeyGap,
                   new SparkleGlyph(Theme.Size.GitPushingGlyph),
                   Kit.Text(title, Theme.Fonts.Action, Theme.Brushes.InkSecondary, TextTrimming.None))
               {
                   Margin = new Thickness(Theme.Size.ActionHPadding, 0, Theme.Size.ActionHPadding, 0),
                   Height = Theme.Size.ActionHeight,
               },
               Theme.Brushes.NeutralActionFill)
    {
        Enabled = false;
        VerticalAlignment = VerticalAlignment.Center;
    }
}

/// The pill while a sync's result holds: the green check drawing itself and "Pushed",
/// "Pulled", "Fetched", not pressable. After the hold it crossfades to the plain pill.
public sealed class GitDonePill : SegmentButton
{
    public GitDonePill(string title)
        : base(new RowStack(Theme.Size.ActionKeyGap,
                   new DoneCheckGlyph(Theme.Size.GitPushingGlyph),
                   Kit.Text(title, Theme.Fonts.Action, Theme.Brushes.InkSecondary, TextTrimming.None))
               {
                   Margin = new Thickness(Theme.Size.ActionHPadding, 0, Theme.Size.ActionHPadding, 0),
                   Height = Theme.Size.ActionHeight,
               },
               Theme.Brushes.NeutralActionFill)
    {
        Enabled = false;
        VerticalAlignment = VerticalAlignment.Center;
    }
}
