// StripView.cs
// Port of Sources/notchcode/Notch/StripView.swift: the toolbar pieces. In the open card the
// strip stays on top: the status segment left of the camera, the tools, a rule and the gear
// right of it (or, while a request waits, the action strip). In the collapsed strip, hover
// swaps the right wing for the tools. The two-row attention state carries the action strip
// on its second row. The segments themselves are UI/Segments.cs.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using Notchcode.Features.Requests;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

// MARK: - Tools

public static class ToolIcons
{
    /// A tool's canvas outline (the gear for Settings).
    public static ToolGlyph For(CardTab tab) => tab switch
    {
        CardTab.Sessions => new ToolGlyph(ToolShapes.Sessions),
        CardTab.Changes => new ToolGlyph(ToolShapes.Changes),
        CardTab.Files => new ToolGlyph(ToolShapes.Files),
        CardTab.Usage => new ToolGlyph(ToolShapes.Usage, ToolShapes.UsageHub),
        CardTab.Git => new ToolGlyph(ToolShapes.Git),
        _ => new ToolGlyph(ToolShapes.Settings, gear: true),
    };
}

/// One tool: its icon in a segment. The selected tool's fill and focus ring belong to the
/// strip (they glide); the button only brightens its icon. Hovering reports to the state so
/// the name caption shows.
public sealed class ToolButton : SegmentButton
{
    private readonly ToolGlyph glyph;
    private readonly Border badgeBox;
    private readonly TextLine badgeText;

    public CardTab Tab { get; }

    public ToolButton(AppState state, CardTab tab, double width, Action action)
        : this(state, tab, width, BuildLabel(tab, width), action) { }

    private ToolButton(AppState state, CardTab tab, double width, (Grid Root, ToolGlyph Glyph, Border Badge, TextLine BadgeText) parts, Action action)
        : base(parts.Root, click: action)
    {
        Tab = tab;
        glyph = parts.Glyph;
        badgeBox = parts.Badge;
        badgeText = parts.BadgeText;
        Width = width;
        Height = Theme.Size.ToolHeight;
        // The name shows as a caption under the strip, not a tooltip: tooltips are slow on a
        // window that never activates.
        MouseEnter += (_, _) => state.HoverTool(tab, true);
        MouseLeave += (_, _) => state.HoverTool(tab, false);
    }

    private static (Grid, ToolGlyph, Border, TextLine) BuildLabel(CardTab tab, double width)
    {
        var root = new Grid { Width = width, Height = Theme.Size.ToolHeight };
        var glyph = ToolIcons.For(tab);
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        root.Children.Add(glyph);
        var text = Ui.Text("", Theme.Fonts.ToolBadge, Theme.Brushes.ToolBadgeText).Fixed();
        text.HorizontalAlignment = HorizontalAlignment.Center;
        var badge = new Border
        {
            Child = text,
            Background = Theme.Brushes.ToolBadgeFill,
            CornerRadius = new CornerRadius(Theme.Radius.ToolBadge),
            Padding = new Thickness(Theme.Size.ToolBadgeHPadding, 0, Theme.Size.ToolBadgeHPadding, 0),
            Height = Theme.Size.ToolBadgeHeight,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, Theme.Size.SpaceXS, Theme.Size.ToolBadgeOffset, 0),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        root.Children.Add(badge);
        return (root, glyph, badge, text);
    }

    public bool Selected
    {
        set => glyph.Foreground = value ? Theme.Brushes.SegmentIconSelected : Theme.Brushes.SegmentIcon;
    }

    /// The Sessions tool's session count; shown above one.
    public int? Badge
    {
        set
        {
            bool show = value is > 1;
            badgeBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            if (show) badgeText.Text = value!.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}

/// A thin vertical rule between the tools and the gear.
public sealed class ToolRule : Border
{
    public ToolRule()
    {
        Child = new Rectangle
        {
            Fill = Theme.Brushes.ToolGroupRule,
            Width = Theme.Size.ToolRuleWidth,
            Height = Theme.Size.ToolGroupRuleHeight,
        };
        Padding = new Thickness(Theme.Size.ToolGroupGap, 0, Theme.Size.ToolGroupGap, 0);
        VerticalAlignment = VerticalAlignment.Center;
    }
}

/// The right wing's tools. `selected` is null in the collapsed strip. With `settings` (the
/// open card), a rule and the gear follow the tools. `compact` narrows the tools so all of
/// them fit a collapsed wing of `available` points. The selection fill and the focus ring are
/// one shape each that glides between tools (`matchedGeometryEffect` on macOS).
public sealed class ToolStrip : Grid
{
    private readonly Canvas underlay = new() { IsHitTestVisible = false };
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private readonly HStack row;
    private readonly Border fill;
    private readonly Border ring;
    private readonly Dictionary<CardTab, ToolButton> buttons = [];
    private readonly bool focusRing;
    private CardTab? selected;
    private bool placed;

    public ToolStrip(AppState state, CardTab? selected, Action<CardTab> onSelect, bool focusRing = false,
        bool settings = false, bool compact = false, double available = double.PositiveInfinity)
    {
        this.focusRing = focusRing;
        double count = CardTabs.Browsable.Count;
        double gap = compact ? Theme.Size.CompactToolGap : Theme.Size.ToolGap;
        double width = compact
            ? Math.Max(0, Math.Min(Theme.Size.CompactToolWidth, (available - (count - 1) * gap) / count))
            : Theme.Size.ToolWidth;
        VerticalAlignment = VerticalAlignment.Center;

        fill = new Border
        {
            Background = Theme.Brushes.ToolSelected,
            CornerRadius = new CornerRadius(Theme.Radius.Segment),
            Height = Theme.Size.ToolHeight,
            Visibility = Visibility.Collapsed,
        };
        ring = new Border
        {
            BorderBrush = Theme.Brushes.ToolFocusRing,
            BorderThickness = new Thickness(Theme.Size.ToolFocusLine),
            CornerRadius = new CornerRadius(Theme.Radius.ToolFocus),
            Height = Theme.Size.ToolHeight + 2 * Theme.Size.ToolFocusOutset,
            Visibility = Visibility.Collapsed,
        };
        underlay.Children.Add(fill);
        overlay.Children.Add(ring);

        row = new HStack { Spacing = gap };
        int index = 0;
        foreach (var tab in CardTabs.Browsable)
        {
            var button = new ToolButton(state, tab, width, () => onSelect(tab));
            if (!compact && tab == CardTab.Sessions) button.Badge = state.Sessions.Count;
            buttons[tab] = button;
            row.Children.Add(Unfolding(button, index++));
        }
        if (settings)
        {
            row.Children.Add(Unfolding(new ToolRule(), CardTabs.Browsable.Count));
            var gear = new ToolButton(state, CardTab.Settings, Theme.Size.GearWidth, () => onSelect(CardTab.Settings));
            buttons[CardTab.Settings] = gear;
            row.Children.Add(Unfolding(gear, CardTabs.Browsable.Count + 1));
        }
        Children.Add(underlay);
        Children.Add(row);
        Children.Add(overlay);
        this.selected = selected;
        foreach (var (tab, button) in buttons) button.Selected = tab == selected;
        LayoutUpdated += (_, _) => PlaceSelection();
    }

    private static UIElement Unfolding(UIElement element, int index)
    {
        if (element is FrameworkElement fe) fe.Loaded += (_, _) => Transitions.UnfoldRight(fe, index);
        return element;
    }

    /// Moves the selection (and the focus ring) to `tab`, gliding on `ToolSelect`.
    public void SetSelected(CardTab? tab)
    {
        if (selected == tab) return;
        selected = tab;
        foreach (var (t, button) in buttons) button.Selected = t == tab;
        PlaceSelection(animated: true);
    }

    /// The Sessions tool's count.
    public void SetBadge(int sessions)
    {
        if (buttons.TryGetValue(CardTab.Sessions, out var b)) b.Badge = sessions;
    }

    /// `tab`'s horizontal centre in `relativeTo`'s coordinates, once laid out.
    public double? CentreOf(CardTab tab, Visual relativeTo)
    {
        if (!buttons.TryGetValue(tab, out var button) || !button.IsLoaded || button.ActualWidth <= 0) return null;
        try
        {
            // Measured without the unfold's offset: where the tool comes to rest.
            var origin = row.TransformToAncestor(relativeTo).Transform(new Point(0, 0));
            var slot = LayoutInformation.GetLayoutSlot(button);
            return origin.X + slot.X + slot.Width / 2;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private void PlaceSelection() => PlaceSelection(animated: placed);

    private void PlaceSelection(bool animated)
    {
        if (selected is not { } tab || !buttons.TryGetValue(tab, out var button) || button.ActualWidth <= 0)
        {
            fill.Visibility = Visibility.Collapsed;
            ring.Visibility = Visibility.Collapsed;
            return;
        }
        // The button's slot inside the row; the row fills this grid, so the same coordinates.
        var slot = LayoutInformation.GetLayoutSlot(button);
        double x = slot.X;
        double w = slot.Width;
        double y = (ActualHeight - Theme.Size.ToolHeight) / 2;
        double outset = Theme.Size.ToolFocusOutset;
        fill.Visibility = Visibility.Visible;
        ring.Visibility = focusRing ? Visibility.Visible : Visibility.Collapsed;
        Canvas.SetTop(fill, y);
        Canvas.SetTop(ring, y - outset);
        if (!placed || !animated)
        {
            Transitions.Snap(fill, Canvas.LeftProperty, x);
            Transitions.Snap(fill, WidthProperty, w);
            Transitions.Snap(ring, Canvas.LeftProperty, x - outset);
            Transitions.Snap(ring, WidthProperty, w + 2 * outset);
            placed = true;
            targetLeft = x;
            targetWidth = w;
            return;
        }
        if (targetLeft == x && targetWidth == w) return;
        targetLeft = x;
        targetWidth = w;
        var spec = Theme.Motion.ToolSelect;
        Transitions.Animate(fill, Canvas.LeftProperty, spec, x);
        Transitions.Animate(fill, WidthProperty, spec, w);
        Transitions.Animate(ring, Canvas.LeftProperty, spec, x - outset);
        Transitions.Animate(ring, WidthProperty, spec, w + 2 * outset);
    }

    private double targetLeft = double.NaN;
    private double targetWidth = double.NaN;
}

/// A collapsed strip's right wing. For click-to-open owners, after the rim's hover dwell the
/// wing crossfades from its usual content to the tools, which unfold from behind the camera;
/// a press opens the card on that tool. Leaving crossfades back. The shape never changes size.
public sealed class HoverToolsWing : StateView
{
    private readonly double bodyWidth;
    private UIElement content;
    private ToolStrip? tools;
    private bool reveal;

    public HoverToolsWing(AppState state, double bodyWidth, UIElement content) : base(state)
    {
        this.bodyWidth = bodyWidth;
        this.content = content;
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(content);
        if (content is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Right;
    }

    /// Swaps the usual content in place (no animation).
    public void SetContent(UIElement next)
    {
        Children.Remove(content);
        content = next;
        if (next is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Right;
        Children.Insert(0, next);
        next.Opacity = reveal ? 0 : 1;
        next.IsHitTestVisible = !reveal;
    }

    protected override void Update()
    {
        bool next = State.Hovering && State.Prefs.OpenGesture == OpenGesture.Click;
        if (next == reveal) return;
        reveal = next;
        var spec = reveal ? Theme.Motion.HoverIn : Theme.Motion.HoverOut;
        if (reveal)
        {
            var old = tools;
            if (old is not null) Children.Remove(old);
            tools = new ToolStrip(State, null, tab => State.OpenCard(tab), compact: true,
                available: State.Layout.WingContentWidth(bodyWidth))
            {
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            Children.Add(tools);
            Transitions.Snap(tools, OpacityProperty, 0);
            Transitions.Animate(tools, OpacityProperty, spec, 1);
            content.IsHitTestVisible = false;
            Transitions.Animate(content, OpacityProperty, spec, 0);
        }
        else
        {
            var leaving = tools;
            tools = null;
            if (leaving is not null)
            {
                leaving.IsHitTestVisible = false;
                Transitions.Animate(leaving, OpacityProperty, spec, 0, () => Children.Remove(leaving));
            }
            content.IsHitTestVisible = true;
            Transitions.Animate(content, OpacityProperty, spec, 1);
        }
    }
}

/// A collapsed strip's left wing. While the tools show in the right wing and one is named,
/// the wing crossfades from its usual content to that tool's name: below the collapsed strip
/// is outside the black, and the right wing has no room left beside the tools.
public sealed class HoverToolsNameWing : StateView
{
    private UIElement content;
    private TextLine? name;
    private CardTab? shown;

    public HoverToolsNameWing(AppState state, UIElement content) : base(state)
    {
        this.content = content;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(content);
    }

    public void SetContent(UIElement next)
    {
        Children.Remove(content);
        content = next;
        Children.Insert(0, next);
        next.Opacity = shown is null ? 1 : 0;
    }

    protected override void Update()
    {
        bool reveal = State.Hovering && State.Prefs.OpenGesture == OpenGesture.Click;
        CardTab? next = reveal ? State.ToolLabel : null;
        if (next == shown) return;
        shown = next;
        var fade = Theme.Motion.ToolLabelFade;
        void To(UIElement element, double opacity, Action? done = null)
        {
            if (fade is { } spec) Transitions.Animate(element, OpacityProperty, spec, opacity, done);
            else { Transitions.Snap(element, OpacityProperty, opacity); done?.Invoke(); }
        }
        if (name is { } old)
        {
            name = null;
            To(old, 0, () => Children.Remove(old));
        }
        if (next is { } tab)
        {
            name = Ui.Text(tab.Label, Theme.Fonts.CaptionMedium, Theme.Brushes.WingsName);
            name.HorizontalAlignment = HorizontalAlignment.Left;
            Children.Add(name);
            Transitions.Snap(name, OpacityProperty, 0);
            To(name, 1);
            To(content, 0);
        }
        else
        {
            To(content, 1);
        }
    }
}

/// The open card's tool name: a small caption pill centred on the tool, hung just below the
/// strip's hairline. Never moves anything; it glides to the next tool. Reduce Motion: it
/// appears, moves and leaves without a fade.
public sealed class ToolLabelPill : Border
{
    private readonly TextLine text;

    public ToolLabelPill()
    {
        text = Ui.Text("", Theme.Fonts.ToolLabel, Theme.Brushes.ToolLabelText).Fixed();
        Child = text;
        Padding = new Thickness(Theme.Size.ToolLabelHPadding, 0, Theme.Size.ToolLabelHPadding, 0);
        Height = Theme.Size.ToolLabelHeight;
        Background = Theme.Brushes.ToolLabelFill;
        BorderBrush = Theme.Brushes.ToolLabelStroke;
        BorderThickness = new Thickness(Theme.Size.Hairline);
        CornerRadius = new CornerRadius(Theme.Radius.ToolLabel);
        IsHitTestVisible = false;
        Opacity = 0;
    }

    private CardTab? tab;
    private double centre = double.NaN;

    /// Shows `next` centred on `x` (canvas coordinates), at `top`; null hides it.
    public void Show(CardTab? next, double? x, double top)
    {
        var fade = Theme.Motion.ToolLabelFade;
        Canvas.SetTop(this, top);
        if (next is null || x is null)
        {
            if (tab is null) return;
            tab = null;
            if (fade is { } f) Transitions.Animate(this, OpacityProperty, f, 0);
            else Transitions.Snap(this, OpacityProperty, 0);
            return;
        }
        bool appearing = tab is null;
        if (tab != next) text.Text = next.Value.Label;
        tab = next;
        Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double left = x.Value - DesiredSize.Width / 2;
        if (appearing || fade is null || double.IsNaN(centre)) Transitions.Snap(this, Canvas.LeftProperty, left);
        else if (Math.Abs(centre - x.Value) > 0.01) Transitions.Animate(this, Canvas.LeftProperty, fade.Value, left);
        centre = x.Value;
        if (appearing)
        {
            if (fade is { } f) Transitions.Animate(this, OpacityProperty, f, 1);
            else Transitions.Snap(this, OpacityProperty, 1);
        }
    }
}

// MARK: - Status segment

/// The open card's left wing: the state glyph in a circle, the worktree name over
/// "branch · model · verb · ■ agents".
public sealed class StatusSegment : HStack
{
    public StatusSegment(AppState state, Session? session, SessionState shown)
    {
        Spacing = Theme.Size.StatusSpacing;
        var glyph = new StateGlyph(shown, circled: true);
        glyph.Loaded += (_, _) => Transitions.UnfoldLeft(glyph, 0);
        Children.Add(glyph.Fixed());

        var lines = new StackPanel { Orientation = Orientation.Vertical, VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(Ui.Text(session.DisplayOrApp(), Theme.Fonts.BodySemibold, Theme.Brushes.Ink, Truncation.Middle));
        if (session is not null && Subtitle(state, session) is { } subtitle) lines.Children.Add(subtitle);
        lines.Loaded += (_, _) => Transitions.UnfoldLeft(lines, 1);
        Children.Add(lines.Priority(0));
    }

    /// "main · opus · Editing · bypass · ■ Explore ■ general-purpose": branch, model, verb, the
    /// permission mode when not default ("bypass" in clay, "plan" in blue), then one coloured
    /// square per running agent. With a second session in the same folder the start time
    /// follows the model.
    private static UIElement? Subtitle(AppState state, Session session)
    {
        var running = state.RunningAgents(session.Id);
        var shownAgents = running.Take(Theme.Limits.MaxStatusAgents).ToList();
        string text = Format.StatusSubtitle(
            session,
            model: state.ModelShortName(session.Id),
            started: state.IsAmbiguous(session) ? state.StartTime(session) : null,
            verb: state.ShownState(session) == SessionState.Working ? session.Verb : null);
        string? mode = Format.PermissionModeLabel(session.PermissionMode);
        string sep = Theme.Glyphs.Separator;
        var font = Theme.Fonts.MonoSmall;
        var row = new HStack { Spacing = Theme.Size.SpaceS, HorizontalAlignment = HorizontalAlignment.Left };
        bool hasLine = text.Length > 0 || mode is not null;
        if (hasLine)
        {
            var line = new HStack { Spacing = 0 };
            string lead = text + (mode is not null && text.Length > 0 ? sep : "");
            if (lead.Length > 0) line.Children.Add(Ui.Text(lead, font, Theme.Brushes.InkTertiary, Truncation.Middle).Priority(0));
            if (mode is not null) line.Children.Add(Ui.Text(mode, font, Theme.Brushes.PermissionMode(session.PermissionMode)).Fixed());
            if (running.Count > 0) line.Children.Add(Ui.Text(sep, font, Theme.Brushes.InkTertiary).Fixed());
            row.Children.Add(line.Priority(0));
        }
        foreach (var agent in shownAgents)
        {
            var item = new HStack(Theme.Size.AgentSquareSpacing,
                new AgentSquare(state.AgentColorIndex(agent)),
                Ui.Text(agent.Type, font, Theme.Brushes.InkTertiary));
            row.Children.Add(item.Priority(1));
        }
        if (running.Count > shownAgents.Count)
            row.Children.Add(Ui.Text($"+{running.Count - shownAgents.Count}", font, Theme.Brushes.InkTertiary).Fixed());
        return row.Children.Count == 0 ? null : row;
    }
}

// MARK: - Action segments

/// Deny · Always · Allow (or Skip · Edit · Commit, Revise · Auto-accept · Approve). Deny sits
/// nearest the camera; Allow, the primary, at the outer end. `allKeys`: the middle segment and
/// a plan's deny show their keycaps too (the attention row shows all three; the open card's
/// strip drops the ones that do not fit, and the footer carries them).
public sealed class ActionStrip : HStack
{
    public ActionStrip(AppState state, PendingRequest request, bool allKeys = false)
    {
        Spacing = Theme.Size.ActionGap;
        VerticalAlignment = VerticalAlignment.Center;
        var actions = request.Kind.Actions;
        // A plan's titles fill the open card's wing, so its ⌫ keycap stays in the footer there.
        string? denyKey = allKeys || request.Kind != PendingRequestKind.Plan ? actions.Deny.Key : null;

        var deny = new ActionSegment(actions.Deny.Title, denyKey, actions.Deny.Role,
            () => state.Answer(RequestAnswer.Deny, request)).Help(actions.Deny.Help);
        var middle = new ActionSegment(actions.Middle.Title, allKeys ? actions.Middle.Key : null, actions.Middle.Role,
            () => state.Answer(request.Kind == PendingRequestKind.Commit ? RequestAnswer.Edit : RequestAnswer.Always, request))
            .Help(actions.Middle.Help);
        var allow = new ActionSegment(actions.Allow.Title, actions.Allow.Key, actions.Allow.Role,
            () => state.Answer(RequestAnswer.Allow, request), countdown: request).Help(actions.Allow.Help);
        PopIn.Apply(allow);

        int index = 0;
        foreach (var segment in new FrameworkElement[] { deny, middle, allow })
        {
            int i = index++;
            segment.Loaded += (_, _) => Transitions.UnfoldRight(segment, i);
            Children.Add(segment.Fixed());
        }
    }
}

// MARK: - The open card's right wing

/// The tools with the selected one filled, a rule, the gear; or the action segments while a
/// request waits; or one "Answer in <terminal>" segment for a question. The well never
/// repeats these: the strip is where things are done.
public sealed class StripRightWing : StateView
{
    private string key = "";
    private ToolStrip? tools;

    public StripRightWing(AppState state) : base(state)
    {
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Center;
    }

    /// The tool strip while tools show (the card hangs the bridge and the caption from it).
    public ToolStrip? Tools => tools;

    protected override void Update()
    {
        var content = State.CardContent;
        string next = content switch
        {
            CardContent.Request r => "request:" + r.Value.Id,
            CardContent.Question q => "question:" + q.Value.SessionId,
            _ => "tools",
        };
        if (next == key)
        {
            tools?.SetSelected(State.SelectedTab);
            tools?.SetBadge(State.Sessions.Count);
            return;
        }
        key = next;
        Children.Clear();
        tools = null;
        switch (content)
        {
            case CardContent.Request r:
                Children.Add(new ActionStrip(State, r.Value) { HorizontalAlignment = HorizontalAlignment.Right });
                break;
            case CardContent.Question q:
            {
                // A question can only be answered in the terminal: one segment, the teleport.
                var session = State.Session(q.Value.SessionId);
                var segment = new ActionSegment("Answer in " + State.TerminalName(session), Theme.Keys.Enter, ActionRole.Allow,
                    () => State.Teleport(session)) { HorizontalAlignment = HorizontalAlignment.Right };
                PopIn.Apply(segment);
                segment.Loaded += (_, _) => Transitions.UnfoldRight(segment, 0);
                Children.Add(segment);
                break;
            }
            default:
                tools = new ToolStrip(State, State.SelectedTab, tab =>
                {
                    if (tab == CardTab.Settings)
                    {
                        if (State.SelectedTab == CardTab.Settings) State.CloseSettings();
                        else State.OpenSettings();
                    }
                    else
                    {
                        State.SelectTab(tab);
                    }
                }, focusRing: true, settings: true)
                { HorizontalAlignment = HorizontalAlignment.Right };
                Children.Add(tools);
                break;
        }
    }
}
