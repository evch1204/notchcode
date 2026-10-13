// CardView.cs
// Port of Sources/notchcode/Notch/CardView.swift.
// The open panel. The strip stays on top as the toolbar (status on the left, the tools with
// the selected one filled on the right, the gear after a rule). Under it, a hairline with a
// short bridge beneath the selected tool, then the content well: a request, a question,
// Settings, or the selected tool's pane (CardPanes). The footer under the well carries the
// keys for that tool. Switching tools glides the fill, slides the bridge, re-targets the
// panel's height (NotchRootView), and slides the pane toward its new anchor with parallax.
// What shows is `AppState.CardContent`, one switch per place.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Shapes;
using Notchcode.Features.Git;
using Notchcode.Features.Requests;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class CardView : StateView
{
    private readonly WingRow strip;
    private readonly StripRightWing rightWing;
    private readonly Grid paneHost = new() { ClipToBounds = true };
    private readonly Border well;
    private readonly Grid footer = new() { Height = Theme.Size.CardFooterHeight };
    private readonly Canvas hangers = new() { IsHitTestVisible = false };
    private readonly Border bridge;
    private readonly ToolLabelPill label = new();
    private string statusKey = "";
    private string paneKey = "";
    private string footerKey = "";
    private FrameworkElement? pane;
    private double bridgeX = double.NaN;

    public CardView(AppState state, Size bodySize) : base(state)
    {
        Width = bodySize.Width;
        VerticalAlignment = VerticalAlignment.Stretch;
        double notch = state.Layout.NotchHeight;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(notch) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // The strip. A click on it (outside a segment) closes the card.
        rightWing = new StripRightWing(state);
        strip = new WingRow(state.Layout, bodySize.Width, null, rightWing);
        strip.OnTap(state.CloseCard);
        Children.Add(strip);
        Transitions.RiseIn(strip, 0);

        // Hairline, well, footer, `SpaceM` apart, with the side and bottom padding.
        var body = new Grid
        {
            Margin = new Thickness(Theme.Size.SidePadding, 0, Theme.Size.SidePadding, Theme.Size.SidePadding),
        };
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.BridgeHeight) });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceM) });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceM) });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.CardFooterHeight) });
        SetRow(body, 1);
        Children.Add(body);

        var hairline = new Rectangle
        {
            Fill = Theme.Brushes.StripDivider,
            Height = Theme.Size.Hairline,
            VerticalAlignment = VerticalAlignment.Top,
        };
        body.Children.Add(hairline);
        Transitions.RiseIn(hairline, 0);

        well = new Border
        {
            Background = Theme.Brushes.Well,
            BorderBrush = Theme.Brushes.WellStroke,
            BorderThickness = new Thickness(Theme.Size.Hairline),
            CornerRadius = new CornerRadius(Theme.Radius.Well),
            Padding = new Thickness(Theme.Size.WellPadding),
            Child = paneHost,
        };
        Boxes.ClipToRounded(well, Theme.Radius.Well);
        SetRow(well, 2);
        body.Children.Add(well);
        Transitions.RiseIn(well, 1);

        SetRow(footer, 4);
        body.Children.Add(footer);
        Transitions.RiseIn(footer, 2);

        // What hangs from the strip into the divider: the bridge and the tool name caption.
        bridge = new Border
        {
            Width = Theme.Size.BridgeWidth,
            Height = Theme.Size.BridgeHeight,
            Background = Theme.Brushes.Bridge,
            CornerRadius = new CornerRadius(Theme.Radius.Bridge),
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetTop(bridge, notch - Theme.Size.BridgeHeight / 2);
        hangers.Children.Add(bridge);
        hangers.Children.Add(label);
        SetRowSpan(hangers, 2);
        Children.Add(hangers);

        LayoutUpdated += (_, _) => PlaceHangers();
    }

    protected override void Update()
    {
        // The inline keycaps follow Settings' switch.
        InlineKeycap.SetInlineKeycaps(well, State.Prefs.KeycapsBesideButtons);
        UpdateStatus();
        UpdateWell();
        UpdateFooter();
        PlaceHangers();
    }

    // MARK: Strip

    private void UpdateStatus()
    {
        var session = State.FocusedSession;
        var shown = State.CurrentPending is not null
            ? SessionState.NeedsYou
            : session is null ? SessionState.Idle : State.ShownState(session);
        string key = session is null
            ? $"none|{shown}"
            : $"{session.Id}|{shown}|{session.DisplayFull}|{session.Branch}|{session.Verb}|{session.PermissionMode}|{State.RunningAgents(session.Id).Count}|{State.IsAmbiguous(session)}|{State.ModelShortName(session.Id)}";
        if (key == statusKey) return;
        statusKey = key;
        strip.LeftWing.Child = new StatusSegment(State, session, shown) { HorizontalAlignment = HorizontalAlignment.Left };
    }

    // MARK: Well

    private void UpdateWell()
    {
        var content = State.CardContent;
        // A tool's pane trails the selection by one dispatcher turn (`PaneTab`), so the
        // outgoing pane knows which way to slide.
        if (content is CardContent.Tool) content = new CardContent.Tool(State.PaneTab);
        string key = CardPanes.KeyOf(content);
        if (key == paneKey) return;
        bool slide = paneKey.StartsWith("tool:", StringComparison.Ordinal) && key.StartsWith("tool:", StringComparison.Ordinal);
        paneKey = key;

        var old = pane;
        pane = CardPanes.Resolve(State, content);
        pane.HorizontalAlignment = HorizontalAlignment.Stretch;
        pane.VerticalAlignment = VerticalAlignment.Stretch;
        paneHost.Children.Add(pane);
        if (old is null) return;

        if (!slide)
        {
            paneHost.Children.Remove(old);
            return;
        }
        old.IsHitTestVisible = false;
        if (Theme.Motion.ReduceMotion)
        {
            var fade = TransitionSpec.Opacity(Theme.Motion.Reduced, Theme.Motion.Reduced);
            Transitions.Insert(pane, fade);
            Transitions.Remove(old, fade, () => paneHost.Children.Remove(old));
            return;
        }
        // The pane re-anchors a short way toward its tool: in from the side it moves to,
        // the old one out the other way, inset groups a little further (parallax).
        double dx = State.TabMovedForward ? Theme.Motion.PaneSlide : -Theme.Motion.PaneSlide;
        Transitions.PaneSlide(pane, dx, Theme.Motion.Slide(dx), inserting: true);
        Transitions.PaneSlide(old, -dx, Theme.Motion.Slide(-dx), inserting: false, completed: () => paneHost.Children.Remove(old));
    }

    // MARK: Footer

    private void UpdateFooter()
    {
        var content = State.CardContent;
        var hints = KeyHintsFor(content);
        string counts = content is CardContent.Tool { Tab: CardTab.Sessions } ? FooterCounts() : "";
        var meter = FooterMeterValues();
        string escape = EscapeLabel(content);
        string key = string.Join(",", hints.Select(h => h.Key + h.Label)) + "|" + counts + "|" + State.Hint + "|" + meter + "|" + escape;
        if (key == footerKey) return;
        footerKey = key;

        footer.Children.Clear();
        footer.ColumnDefinitions.Clear();
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new HStack { Spacing = Theme.Size.SpaceM, HorizontalAlignment = HorizontalAlignment.Left };
        if (State.Hint is { } hint)
        {
            left.Children.Add(new HintText(hint));
        }
        else
        {
            left.Children.Add(new KeyHints(hints).Fixed());
            if (counts.Length > 0) left.Children.Add(Ui.Text(counts, Theme.Fonts.Caption, Theme.Brushes.InkTertiary));
        }
        footer.Children.Add(left);

        if (meter is { } m)
        {
            var bar = new UsageBar(m.Percent / 100, m.Tint) { Width = Theme.Size.FooterBarWidth };
            var meterView = new HStack(Theme.Size.SpaceS,
                Ui.Text(m.Label, Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed(),
                bar,
                Ui.Text(Format.Percent(m.Percent), Theme.Fonts.CaptionMedium, Theme.Brushes.InkSecondary).Fixed())
            {
                Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0),
            };
            meterView.Help(m.Help);
            SetColumn(meterView, 1);
            footer.Children.Add(meterView);
        }

        var esc = new KeyHints([new KeyHint(Theme.Keys.Escape, escape)]) { Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0) };
        SetColumn(esc, 2);
        footer.Children.Add(esc);
    }

    /// The keys for what the well shows. The Changes and Git tools' keys depend on their own
    /// state (cursor, pane, picker, form); until their state lands (wave 2) they show the
    /// keys of their resting view.
    private List<KeyHint> KeyHintsFor(CardContent content)
    {
        switch (content)
        {
            case CardContent.Request r:
            {
                // The keys the strip does not show: the middle action's, and a plan's ⌫ and ↑↓.
                var actions = r.Value.Kind.Actions;
                var hints = new List<KeyHint> { new(actions.Middle.Key ?? "", actions.Middle.Title.ToLowerInvariant()) };
                if (r.Value.Kind == PendingRequestKind.Plan)
                {
                    hints.Insert(0, new KeyHint(actions.Deny.Key ?? "", actions.Deny.Title.ToLowerInvariant()));
                    hints.Add(new KeyHint(Theme.Keys.Up + Theme.Keys.Down, "scroll"));
                }
                if (r.Value.Files.Any(f => f.Patch.Count > 0 || f.Snippet.Count > 0)) hints.Add(new KeyHint(Theme.Keys.Diff, "diff"));
                return hints;
            }
            case CardContent.Settings:
                return [new(Theme.Keys.Settings, "toggles this page")];
            case CardContent.Tool { Tab: CardTab.Changes }:
                return ChangesHints();
            case CardContent.Tool { Tab: CardTab.Files }:
                return
                [
                    new(Theme.Keys.Enter, "open"),
                    new(Theme.Keys.Slash, "filter"),
                    new(Theme.Keys.ToggleTree, "tree"),
                    new(Theme.Keys.Copy, "copy path:line"),
                    new(Theme.Keys.OptionEnter, "terminal"),
                ];
            case CardContent.Tool { Tab: CardTab.Sessions }:
                return
                [
                    new(Theme.Keys.Enter, "changes"),
                    new(Theme.Keys.OptionEnter, "terminal"),
                    new(Theme.Keys.Tab, "next tool"),
                ];
            case CardContent.Tool { Tab: CardTab.Git }:
                return GitHints();
            case CardContent.Tool { Tab: CardTab.Usage }:
                return [new(Theme.Keys.Refresh, "refresh"), new(Theme.Keys.Tab, "next tool")];
            default:
                return [new(Theme.Keys.Tab, "next tool")];
        }
    }

    /// The Changes tool's keys: what ⏎ does on the cursor's stop (a chip's diff, a quiet
    /// group's fold), and with the pane up, the terminal and Ctrl B for the timeline.
    private List<KeyHint> ChangesHints()
    {
        var move = new KeyHint(Theme.Keys.Up + Theme.Keys.Down, "move");
        var copy = new KeyHint(Theme.Keys.Copy, "copy path:line");
        if (State.ChangesPaneShown)
            return [move, new(Theme.Keys.Enter, "terminal"), copy, new(Theme.Keys.ToggleTree, "list")];
        var items = State.ChangesCursorItems;
        var hints = new List<KeyHint> { move };
        if (State.RowCursor >= 0 && State.RowCursor < items.Count)
        {
            switch (items[State.RowCursor])
            {
                case Features.Changes.ChangesItem.Chip:
                    hints.Add(new(Theme.Keys.Enter, "diff"));
                    hints.Add(copy);
                    break;
                case Features.Changes.ChangesItem.Group group:
                    hints.Add(new(Theme.Keys.Enter, State.ChangesTool.UnfoldedGroups.Contains(group.GroupId) ? "fold" : "unfold"));
                    break;
            }
        }
        hints.Add(new(Theme.Keys.OptionEnter, "terminal"));
        hints.Add(new(Theme.Keys.Slash, "with edits"));
        hints.Add(new(Theme.Keys.Tab, "next tool"));
        return hints;
    }

    /// The Git tool's keys: the picker's, the commit form's, a confirm's, else the stage's.
    private List<KeyHint> GitHints()
    {
        var panel = State.GitPanel;
        if (panel.PickerOpen)
        {
            if (panel.RepoMenuOpen)
                return [new(Theme.Keys.Up + Theme.Keys.Down, "repository"), new(Theme.Keys.Enter, "choose")];
            var picker = new List<KeyHint> { new(Theme.Keys.Up + Theme.Keys.Down, "branch"), new(Theme.Keys.Enter, "show this branch") };
            if (panel.Repos.Count > 1) picker.Add(new(Theme.Keys.Repository, "repository"));
            if (State.GitPickerShowsFilter && !panel.FilterFocused) picker.Add(new(Theme.Keys.Slash, "filter"));
            return picker;
        }
        var draft = State.GitDraft;
        if (draft.Composing)
        {
            return draft.Focus switch
            {
                Features.Git.GitDraftFocus.Description => draft.CoauthorsShown
                    ? [new(Theme.Keys.CommandEnter, "commit"), new(Theme.Keys.Tab, "co-author")]
                    : [new(Theme.Keys.CommandEnter, "commit")],
                Features.Git.GitDraftFocus.Coauthor =>
                    [new(Theme.Keys.Enter, "add"), new(Theme.Keys.Delete, "remove"), new(Theme.Keys.CommandEnter, "commit")],
                _ => [new(Theme.Keys.Enter, "commit"), new(Theme.Keys.Tab, "description")],
            };
        }
        if (State.GitPhase is Features.Git.GitPhase.Confirming confirming)
            return [new(Theme.Keys.Enter, confirming.Op.Verb.ToLowerInvariant())];
        var hints = new List<KeyHint> { new(Theme.Keys.Up + Theme.Keys.Down, "file") };
        if (State.FocusedGit?.CheckedOut == true && State.GitRows.Count > 0)
        {
            hints.Add(new(Theme.Keys.Toggle, "include"));
            hints.Add(new(Theme.Keys.Commit, "commit"));
        }
        if (State.GitCanUndo) hints.Add(new(Theme.Keys.Undo, "undo"));
        hints.Add(new(Theme.Keys.Worktree, "branch"));
        hints.Add(new(Theme.Keys.ToggleTree, "rail"));
        hints.Add(new(Theme.Keys.Push, State.GitSyncVerb.ToLowerInvariant()));
        // Past six the row would crowd the meter; ⇥ is taught by every other tool.
        if (hints.Count <= Theme.Limits.GitFooterHints) hints.Add(new(Theme.Keys.Tab, "next tool"));
        return hints;
    }

    /// What esc does: "back" out of Settings, the Git tool's dropdown, filter and picker
    /// layers, or the Changes diff pane, else "close".
    private string EscapeLabel(CardContent content)
    {
        if (content is CardContent.Settings) return "back";
        if (content is CardContent.Tool { Tab: CardTab.Git } && State.GitEscapeLabel is { } label) return label;
        if (content is CardContent.Tool { Tab: CardTab.Changes } && State.ChangesPaneShown) return "back";
        return "close";
    }

    /// "2 working · 1 waiting · 3 agents" on the Sessions tool.
    private string FooterCounts()
    {
        var c = State.SessionCounts;
        return Format.SessionCounts(c.Working, c.Waiting, c.Done, c.Idle, State.RunningAgentCount);
    }

    /// The 5-hour limit once the status line has reported it (and its window has not reset
    /// since), else context with "ctx"; null when neither is known.
    private (string Label, double Percent, System.Windows.Media.Brush Tint, string Help)? FooterMeterValues()
    {
        var usage = State.Usage;
        if (usage.FiveHourPercent is double percent && !AppState.LimitWindowHasReset(usage.FiveHourResetsAt))
        {
            string help = State.LimitsUpdatedAt is DateTime updated
                ? "Current session (5h) limit, " + Format.LimitsAsOf(updated)
                : "Current session (5h) limit";
            return ("5h", Math.Min(100, percent), Theme.Brushes.LimitBar, help);
        }
        // The status line's own figure first, then the transcript's (AppState.Usage.cs).
        if (State.ContextPercent is double context)
            return ("ctx", context, Theme.Brushes.ContextBar, "Context window used");
        return null;
    }

    // MARK: Hangers

    /// The bridge under the selected tool and the tool name caption under the tool the mouse
    /// rests on (or `⇥` just moved to). Requests and questions hang from their action segments
    /// instead, so neither shows then.
    private void PlaceHangers()
    {
        var content = State.CardContent;
        bool toolsShown = content is CardContent.Settings or CardContent.Tool;
        var tools = rightWing.Tools;
        double? x = toolsShown && tools is not null ? tools.CentreOf(State.SelectedTab, this) : null;
        if (x is double bx)
        {
            double left = bx - Theme.Size.BridgeWidth / 2;
            if (bridge.Visibility != Visibility.Visible || double.IsNaN(bridgeX))
            {
                bridge.Visibility = Visibility.Visible;
                Transitions.Snap(bridge, Canvas.LeftProperty, left);
            }
            else if (Math.Abs(bridgeX - left) > 0.01)
            {
                Transitions.Animate(bridge, Canvas.LeftProperty, Theme.Motion.ToolSelect, left);
            }
            bridgeX = left;
        }
        else
        {
            bridge.Visibility = Visibility.Collapsed;
            bridgeX = double.NaN;
        }

        CardTab? named = toolsShown ? State.ToolLabel : null;
        double? lx = named is { } tab && tools is not null ? tools.CentreOf(tab, this) : null;
        label.Show(named, lx, State.Layout.NotchHeight + Theme.Size.ToolLabelDrop);
    }
}
