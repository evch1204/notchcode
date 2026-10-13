// SessionsTab.xaml.cs
// Port of Sources/notchcode/Features/Sessions/SessionsTab.swift.
// Every session at a glance, grouped by repository: a slim header per repo
// ("notchcode · 2 worktrees") that sticks while its rows scroll, then one row per
// session: state dot, the worktree name bold, branch in mono, model, state word and
// clock on the right, the current prompt dimmed below. A plain checkout is its own
// group with one row named after its folder. Groups with someone waiting come first.
// Two sessions in one folder also show their start time, and the newest gets a tag.
// A session not in the default permission mode carries its mode as a tag ("bypass" in clay).
// Clicking a row (or ⏎) selects the session and shows its Changes; the chevron (or Alt ⏎)
// teleports to its terminal. Each subagent gets a lane with its own colour square, the
// running ones with a slow shimmer; finished ones collapse into "N done", which opens on
// click. The keyboard cursor's fill is one shape that glides from row to row. Counts live
// in the footer.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.Features.StandIns;
using Notchcode.UI.Diff;


namespace Notchcode.Features.Sessions;

public partial class SessionsTab : UserControl
{
    private AppState? state;
    private StateWatcher? watcher;
    /// Sessions whose finished agents are expanded.
    private readonly HashSet<string> expandedDone = [];
    /// The session whose "N done" was just clicked: its chevron turns and its lanes rise in.
    private string? turnedDone;

    private readonly ScrollViewer scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    private readonly Grid layers = new();
    private readonly Canvas cursorLayer = new() { IsHitTestVisible = false };
    private readonly StackPanel list = new();
    private readonly Border cursorFill = new()
    {
        CornerRadius = new CornerRadius(Theme.Radius.Row),
        Background = Theme.Brushes.Selection,
        Visibility = Visibility.Collapsed,
    };
    private readonly Border sticky = new() { VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    /// Session id -> its row, and each group's header with its group.
    private readonly Dictionary<string, FrameworkElement> rows = [];
    private readonly List<(FrameworkElement Header, SessionGroup Group)> headers = [];
    private bool cursorPlaced;

    public SessionsTab()
    {
        InitializeComponent();
        layers.Children.Add(cursorLayer);
        layers.Children.Add(list);
        cursorLayer.Children.Add(cursorFill);
        scroll.Content = layers;
        scroll.ScrollChanged += (_, _) => UpdateSticky();
        Root.Children.Add(scroll);
        Root.Children.Add(sticky);
    }

    public SessionsTab(AppState state) : this() => State = state;

    public AppState? State
    {
        get => state;
        set
        {
            state = value;
            if (value is null) return;
            watcher = new StateWatcher(this, value,
                [nameof(AppState.Sessions), nameof(AppState.Pending), nameof(AppState.Agents), nameof(AppState.TurnTitles),
                 nameof(AppState.TurnStarts), nameof(AppState.FocusedSessionId), nameof(AppState.Statusline),
                 nameof(AppState.TurnsBySession), nameof(AppState.NewestSessionByCwd), nameof(AppState.ShellFiles)],
                Rebuild,
                new Dictionary<string, Action> { [nameof(AppState.SessionCursor)] = () => MoveCursor(scrollTo: true) });
            Rebuild();
        }
    }

    /// Runs any pending rebuild now (the harness renders without a dispatcher turn).
    public void Flush() => watcher?.Flush();

    private void Rebuild()
    {
        if (state is null) return;
        list.Children.Clear();
        rows.Clear();
        headers.Clear();
        var pendingIds = state.Pending.Select(p => p.SessionId).ToHashSet();
        var groups = state.SessionGroups;
        var ordered = groups.SelectMany(g => g.Sessions).ToList();
        if (ordered.Count == 0)
        {
            scroll.Visibility = Visibility.Collapsed;
            sticky.Visibility = Visibility.Collapsed;
            if (Root.Children.OfType<EmptyNote>().FirstOrDefault() is null)
                Root.Children.Add(new EmptyNote("No Claude Code sessions in the last few hours"));
            return;
        }
        foreach (var note in Root.Children.OfType<EmptyNote>().ToList()) Root.Children.Remove(note);
        scroll.Visibility = Visibility.Visible;

        foreach (var group in groups)
        {
            var header = RepoHeader(group);
            headers.Add((header, group));
            Add(header);
            foreach (var session in group.Sessions)
            {
                int index = ordered.FindIndex(s => s.Id == session.Id);
                Add(SessionBlock(session, Math.Max(0, index), pendingIds.Contains(session.Id)));
            }
        }
        turnedDone = null;
        Dispatcher.BeginInvoke(() => { MoveCursor(scrollTo: false); UpdateSticky(); }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// LazyVStack(spacing: spaceXS).
    private void Add(FrameworkElement element)
    {
        element.Margin = new Thickness(0, list.Children.Count == 0 ? 0 : Theme.Size.SpaceXS, 0, 0);
        list.Children.Add(element);
    }

    // MARK: The cursor

    /// The fill glides to the cursor's row on the selection spring; the first placement snaps.
    private void MoveCursor(bool scrollTo)
    {
        if (state is null) return;
        var ordered = state.OrderedSessions;
        int cursor = state.SessionCursor;
        if (cursor < 0 || cursor >= ordered.Count || !rows.TryGetValue(ordered[cursor].Id, out var row) || !row.IsArrangeValid
            || state.Pending.Any(p => p.SessionId == ordered[cursor].Id))
        {
            cursorFill.Visibility = Visibility.Collapsed;
            return;
        }
        layers.UpdateLayout();
        var at = row.TranslatePoint(new Point(0, 0), layers);
        cursorFill.Visibility = Visibility.Visible;
        if (!cursorPlaced || Theme.Motion.ReduceMotion)
        {
            Transitions.Snap(cursorFill, Canvas.TopProperty, at.Y);
            Transitions.Snap(cursorFill, HeightProperty, row.ActualHeight);
            cursorPlaced = true;
        }
        else
        {
            Transitions.Animate(cursorFill, Canvas.TopProperty, Theme.Motion.SessionCursor, at.Y);
            Transitions.Animate(cursorFill, HeightProperty, Theme.Motion.SessionCursor, row.ActualHeight);
        }
        cursorFill.Width = row.ActualWidth;
        if (scrollTo) row.BringIntoView();
    }

    // MARK: Sticky header

    /// The header of the group under the top edge sticks there; the next group's header pushes it up.
    private void UpdateSticky()
    {
        if (headers.Count == 0 || !list.IsArrangeValid)
        {
            sticky.Visibility = Visibility.Collapsed;
            return;
        }
        double offset = scroll.VerticalOffset;
        if (offset <= 0)
        {
            sticky.Visibility = Visibility.Collapsed;
            return;
        }
        int current = 0;
        for (int i = 0; i < headers.Count; i++)
            if (headers[i].Header.TranslatePoint(new Point(0, 0), list).Y <= offset) current = i;
        double push = 0;
        if (current + 1 < headers.Count)
        {
            double next = headers[current + 1].Header.TranslatePoint(new Point(0, 0), list).Y - offset;
            push = Math.Min(0, next - Theme.Size.RepoHeaderHeight);
        }
        if (sticky.Tag as string != headers[current].Group.Id)
        {
            sticky.Child = RepoHeader(headers[current].Group);
            sticky.Tag = headers[current].Group.Id;
        }
        sticky.RenderTransform = new TranslateTransform(0, push);
        sticky.Visibility = Visibility.Visible;
    }

    // MARK: Pieces

    /// "notchcode · 2 worktrees": slim, pinned while its rows scroll. Carries the well's colour
    /// flattened so rows pass cleanly beneath it.
    private static FrameworkElement RepoHeader(SessionGroup group)
    {
        var parts = new List<string>();
        if (group.HasWorktrees) parts.Add(Format.Worktrees(group.WorktreeCount));
        if (group.Sessions.Count > group.WorktreeCount) parts.Add(Format.Sessions(group.Sessions.Count));
        var row = new HStack(0, Ui.Text(group.Name, Theme.Fonts.GroupHeader, Theme.Brushes.GroupHeaderName, Truncation.Middle))
        {
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        if (parts.Count > 0)
            row.Children.Add(Ui.Text(Theme.Glyphs.Separator + string.Join(Theme.Glyphs.Separator, parts), Theme.Fonts.Caption,
                Theme.Brushes.GroupHeaderCount).Fixed());
        return new Border
        {
            Child = row,
            Padding = new Thickness(Theme.Size.RowHPadding, 0, Theme.Size.RowHPadding, 0),
            Height = Theme.Size.RepoHeaderHeight,
            Background = Theme.Brushes.GroupHeaderBackground,
        };
    }

    private FrameworkElement SessionBlock(Session session, int index, bool isPending)
    {
        var all = state!.AgentsFor(session.Id);
        var running = all.Select((a, i) => (Agent: a, Index: i)).Where(x => x.Agent.IsRunning).ToList();
        var finished = all.Select((a, i) => (Agent: a, Index: i)).Where(x => !x.Agent.IsRunning).ToList();
        bool expanded = expandedDone.Contains(session.Id);
        bool isFocused = state.FocusedSession?.Id == session.Id;

        var block = new StackPanel();

        // The row's own fill: pending wins over the cursor (the gliding fill is hidden then).
        var rowGrid = new Grid { Background = Theme.Brushes.HitTarget };
        var rowBorder = new Border
        {
            CornerRadius = new CornerRadius(Theme.Radius.Row),
            Background = isPending ? Theme.Brushes.AttentionHighlight : Theme.Brushes.HitTarget,
            Child = rowGrid,
        };
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var row = SessionRow(session, isPending, isFocused);
        row.OnTap(() => state.SelectSession(session));
        rowGrid.Children.Add(row);

        var chevron = new Border
        {
            Width = Theme.Size.ChevronColumn + Theme.Size.RowHPadding,
            Height = Theme.Size.ChevronHitHeight,
            Background = Theme.Brushes.HitTarget,
            Child = new RowChevron(false, width: null, color: Theme.Brushes.InkSecondary, animated: false),
            ToolTip = "Open in " + state.TerminalName(session) + " (" + Theme.Keys.OptionEnter + ")",
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(chevron, 1);
        chevron.OnTap(() =>
        {
            state.SessionCursor = index;
            state.Teleport(session);
        });
        rowGrid.Children.Add(chevron);
        rows[session.Id] = rowBorder;
        block.Children.Add(rowBorder);

        foreach (var (agent, colorIndex) in running) block.Children.Add(AgentLane(agent, colorIndex));
        if (finished.Count > 0)
        {
            var done = DoneLane(finished.Count, expanded, out var doneChevron);
            done.OnTap(() =>
            {
                if (!expandedDone.Remove(session.Id)) expandedDone.Add(session.Id);
                turnedDone = session.Id;
                Rebuild();
            });
            // The chevron turns from where it was (the lanes were just shown or hidden).
            if (turnedDone == session.Id)
            {
                ChevronTurn.Set(doneChevron, !expanded, animated: false);
                doneChevron.Loaded += (_, _) => ChevronTurn.Set(doneChevron, expanded);
            }
            block.Children.Add(done);
            if (expanded)
                for (int i = 0; i < finished.Count; i++)
                {
                    var lane = AgentLane(finished[i].Agent, finished[i].Index);
                    block.Children.Add(lane);
                    if (turnedDone == session.Id) Transitions.RiseIn(lane, i, Theme.Limits.MaxStaggeredChildren);
                }
        }
        return block;
    }

    private FrameworkElement SessionRow(Session session, bool isPending, bool isFocused)
    {
        var shown = isPending ? SessionState.NeedsYou : session.State;
        var grid = new Grid
        {
            Margin = new Thickness(Theme.Size.RowHPadding, Theme.Size.RowVPadding, 0, Theme.Size.RowVPadding),
            Background = Theme.Brushes.HitTarget,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.Glyph) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = new StatusDot(shown) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(dot);

        // Line 1, on the first baseline: the worktree (it keeps its room), its branch (which
        // gives way first, cut in the middle), the model, the tags.
        var line1 = new BaselineRow(Theme.Size.SpaceM) { HorizontalAlignment = HorizontalAlignment.Left };
        line1.Children.Add(Ui.Text(session.RowName, Theme.Fonts.BodySemibold, Theme.Brushes.Ink).Priority(2));
        if (session.Branch is { } branch)
            line1.Children.Add(Ui.Text(branch, Theme.Fonts.MonoSmall, Theme.Brushes.InkSecondary, Truncation.Middle));
        if (state!.ModelShortName(session.Id) is { } model)
            line1.Children.Add(Ui.Text(model, Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed());
        if (Format.PermissionModeLabel(session.PermissionMode) is { } mode)
            line1.Children.Add(new SmallTag(mode, Theme.Brushes.PermissionMode(session.PermissionMode)));
        bool twin = state.IsAmbiguous(session);
        if (twin && state.IsNewest(session)) line1.Children.Add(new SmallTag("newest"));
        if (isFocused) line1.Children.Add(new SmallTag("Showing"));

        var prompt = state.CurrentPrompt(session.Id) ?? "";
        string second = twin
            ? Format.Started(state.StartTime(session)) + (prompt.Length == 0 ? "" : Theme.Glyphs.Separator + prompt)
            : prompt.Length == 0 ? " " : prompt;
        var line2 = Ui.Text(second.ReplaceLineEndings(" "), Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        line2.HorizontalAlignment = HorizontalAlignment.Left;
        line2.Margin = new Thickness(0, Theme.Size.SpaceXS, 0, 0);

        // SwiftUI: spacing, `Spacer(minLength: spaceM)`, spacing before the state and clock.
        var texts = new StackPanel { Margin = new Thickness(Theme.Size.SpaceM, 0, 3 * Theme.Size.SpaceM, 0), VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(line1);
        texts.Children.Add(line2);
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        FrameworkElement clock = shown == SessionState.Working && state.TurnStart(session) is DateTime start
            ? new ElapsedText(start)
            : Ui.Text(Format.Ago(session.LastEventAt), Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed();
        var right = new HStack(Theme.Size.SpaceM,
            Ui.Text(Format.StateText(shown, session.Verb), Theme.Fonts.CaptionMedium, Theme.Brushes.StateText(shown)).Fixed(),
            clock);
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        return grid;
    }

    /// One subagent under its session: colour square, type, description, elapsed (or how long it ran).
    /// A running lane carries the shimmer: an 8% white sweep every 2.4 s. The lane's vertical
    /// padding sits outside its line, as in SwiftUI, so stacked lanes show a short gap.
    private static FrameworkElement AgentLane(Agent agent, int colorIndex)
    {
        var grid = new Grid
        {
            Margin = new Thickness(Theme.Size.LaneIndent, Theme.Size.LaneVPadding, Theme.Size.RowHPadding + Theme.Size.ChevronColumn,
                Theme.Size.LaneVPadding),
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new VRule(Theme.Brushes.LaneLine, Theme.Size.LaneLineWidth));
        var square = new AgentSquare(colorIndex, finished: !agent.IsRunning) { Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0) };
        Grid.SetColumn(square, 1);
        grid.Children.Add(square);
        var type = Ui.Text(agent.Type, Theme.Fonts.CaptionSemibold, agent.IsRunning ? Theme.Brushes.Ink : Theme.Brushes.InkSecondary).Fixed();
        type.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
        Grid.SetColumn(type, 2);
        grid.Children.Add(type);
        if (agent.Description is { Length: > 0 } description)
        {
            var desc = Ui.Text(description.ReplaceLineEndings(" "), Theme.Fonts.Caption,
                agent.IsRunning ? Theme.Brushes.InkSecondary : Theme.Brushes.InkTertiary);
            desc.HorizontalAlignment = HorizontalAlignment.Left;
            // SwiftUI: spacing, `Spacer(minLength: spaceM)`, spacing: the time keeps three gaps clear.
            desc.Margin = new Thickness(Theme.Size.SpaceM, 0, 2 * Theme.Size.SpaceM, 0);
            Grid.SetColumn(desc, 3);
            grid.Children.Add(desc);
        }
        FrameworkElement time = agent.EndedAt is DateTime ended
            ? Ui.Text(Format.Duration((ended - agent.StartedAt).TotalSeconds), Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed()
            : new ElapsedText(agent.StartedAt);
        time.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
        Grid.SetColumn(time, 4);
        grid.Children.Add(time);

        if (!agent.IsRunning || Theme.Motion.LaneShimmer is not MotionSpec shimmer) return grid;
        var host = new Grid();
        host.Children.Add(grid);
        host.Children.Add(Shimmer(shimmer));
        return host;
    }

    /// The sweep: a soft band of `LaneShimmer` crossing the lane, left to right, forever.
    private static FrameworkElement Shimmer(MotionSpec spec)
    {
        var band = new Border
        {
            Width = Theme.Size.LaneShimmerWidth,
            Background = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0.5),
                EndPoint = new Point(1, 0.5),
                GradientStops =
                {
                    new GradientStop(Colors.Transparent, 0),
                    new GradientStop(Theme.Colors.LaneShimmer, 0.5),
                    new GradientStop(Colors.Transparent, 1),
                },
            },
            HorizontalAlignment = HorizontalAlignment.Left,
            IsHitTestVisible = false,
        };
        var move = new TranslateTransform();
        band.RenderTransform = move;
        var canvas = new Grid { ClipToBounds = true, IsHitTestVisible = false };
        canvas.Children.Add(band);
        canvas.SizeChanged += (_, _) =>
            move.BeginAnimation(TranslateTransform.XProperty, spec.ToTimeline(-Theme.Size.LaneShimmerWidth, canvas.ActualWidth));
        return canvas;
    }

    /// "▸ 3 done": finished agents, collapsed. Click to show their lanes.
    private static FrameworkElement DoneLane(int count, bool expanded, out RowChevron chevron)
    {
        var grid = new Grid
        {
            Margin = new Thickness(Theme.Size.LaneIndent, Theme.Size.LaneVPadding, 0, Theme.Size.LaneVPadding),
            Background = Theme.Brushes.HitTarget,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new VRule(Theme.Brushes.LaneLine, Theme.Size.LaneLineWidth));
        chevron = new RowChevron(expanded, width: null, animated: false);
        var tag = Boxes.CapsuleTag(new HStack(Theme.Size.SpaceS,
            chevron,
            Ui.Text(count + " done", Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed()));
        tag.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
        tag.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(tag, 1);
        grid.Children.Add(tag);
        return grid;
    }

    /// SwiftUI's `HStack(alignment: .firstTextBaseline)`: the shared HStack's widths (the
    /// highest layout priority keeps its room, the rest give way), with every child placed so
    /// the baseline of its first line of text lines up. A child's baseline is read from the
    /// first `TextLine` inside it, centred in the child as the capsule tags centre theirs.
    private sealed class BaselineRow : HStack
    {
        public BaselineRow(double spacing) => Spacing = spacing;

        private static TextLine? FirstText(DependencyObject node)
        {
            if (node is TextLine line) return line;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
                if (FirstText(VisualTreeHelper.GetChild(node, i)) is { } found) return found;
            return null;
        }

        /// The child's baseline, from its top.
        private static double Baseline(UIElement child)
        {
            double height = child.DesiredSize.Height;
            if (FirstText(child) is not { } text) return height;
            var font = text.Font;
            var probe = new System.Windows.Media.FormattedText("Ag", System.Globalization.CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, font.Typeface, font.Size, Theme.Brushes.Ink, 1.0);
            return (height - probe.Height) / 2 + probe.Baseline;
        }

        private IEnumerable<UIElement> Shown => Children.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed);

        protected override Size MeasureOverride(Size available)
        {
            var size = base.MeasureOverride(available);
            double ascent = 0, descent = 0;
            foreach (var child in Shown)
            {
                double b = Baseline(child);
                ascent = Math.Max(ascent, b);
                descent = Math.Max(descent, child.DesiredSize.Height - b);
            }
            return new Size(size.Width, ascent + descent);
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            double ascent = Shown.Select(Baseline).DefaultIfEmpty(0).Max();
            double x = 0;
            bool first = true;
            foreach (var child in Shown)
            {
                if (!first) x += Spacing;
                first = false;
                double w = Math.Max(0, Math.Min(child.DesiredSize.Width, finalSize.Width - x));
                child.Arrange(new Rect(x, ascent - Baseline(child), w, child.DesiredSize.Height));
                x += w;
            }
            return finalSize;
        }
    }
}
