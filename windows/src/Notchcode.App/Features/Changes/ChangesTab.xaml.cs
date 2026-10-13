// ChangesTab.xaml.cs
// Port of Sources/notchcode/Features/Changes/ChangesTab.swift.
// The Changes tool, Direction G (Timeline; owner, 2026-09-30). Inside the well: a 26 pt header
// with the session's totals ("14 turns · 9 files · +607 −0 · 1h 12m", the session's, not the
// view's) and the "With edits /" pill; under it the timeline (ChangesTimeline.cs): a spine
// with one node per turn, newest first, the live turn breathing at the top, each turn that
// changed files as an entry with its files as chips, and every run of quiet turns folded
// into one row. ⏎ or a click on a chip opens the diff pane on the right (ChangesDiffPane.cs),
// the Git tool's split: the column springs from the full width to 236 pt, a hairline, the
// pane. The diff never opens inline, so the timeline never jumps. Esc closes the pane, Ctrl B
// hides the column while it shows, `/` hides the quiet turns.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.UI.Diff;


namespace Notchcode.Features.Changes;

public partial class ChangesTab : UserControl
{
    private AppState? state;
    private StateWatcher? watcher;

    private readonly Grid page = new();
    private readonly Border headerHost = new() { Height = Theme.Size.ChangesHeaderHeight };
    private readonly Grid split = new();
    /// The column's edge springs; the timeline inside keeps the width it is given at once.
    private readonly Border columnHost = new() { ClipToBounds = true, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Grid paneHost = new();
    private readonly Border hairline = new()
    {
        Width = Theme.Size.Hairline,
        Background = Theme.Brushes.PaneDivider,
        Margin = new Thickness(Theme.Size.FilesColumnGap, 0, Theme.Size.FilesColumnGap, 0),
    };
    private ChangesTimeline? timeline;
    private ChangesDiffPane? pane;
    private string? paneKey;
    private bool columnPlaced;
    private bool editsOnlyBefore;
    private DispatcherTimer? spanTimer;

    public ChangesTab()
    {
        InitializeComponent();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceS) });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(headerHost);
        Grid.SetRow(split, 2);
        page.Children.Add(split);
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        split.Children.Add(columnHost);
        paneHost.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        paneHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        paneHost.Children.Add(hairline);
        Grid.SetColumn(paneHost, 1);
        split.Children.Add(paneHost);
        // The split's own width can grow past the well (an Auto column), so the well's width rules.
        Root.SizeChanged += (_, _) => LayoutSplit(animated: false);
        Root.Children.Add(page);
        Unloaded += (_, _) => spanTimer?.Stop();
    }

    public ChangesTab(AppState state) : this() => State = state;

    public AppState? State
    {
        get => state;
        set
        {
            state = value;
            if (value is null) return;
            timeline = new ChangesTimeline(value);
            columnHost.Child = timeline;
            watcher = new StateWatcher(this, value,
                [nameof(AppState.TurnsBySession), nameof(AppState.ShellFiles), nameof(AppState.FocusedSessionId),
                 nameof(AppState.Sessions), nameof(AppState.Agents), nameof(AppState.ChangesTool), nameof(AppState.Pending)],
                Rebuild,
                new Dictionary<string, Action>
                {
                    [nameof(AppState.RowCursor)] = () => timeline?.MoveCursor(scrollTo: true),
                    [nameof(AppState.SelectedTab)] = () => timeline?.MoveCursor(scrollTo: false),
                });
            Rebuild();
        }
    }

    /// Runs any pending rebuild now (the harness renders without a dispatcher turn).
    public void Flush() => watcher?.Flush();

    private void Rebuild()
    {
        if (state is null || timeline is null) return;
        var turns = state.Turns(state.FocusedSession?.Id);
        foreach (var note in Root.Children.OfType<EmptyNote>().ToList()) Root.Children.Remove(note);
        if (turns.Count == 0)
        {
            page.Visibility = Visibility.Collapsed;
            Root.Children.Add(new EmptyNote("Nothing changed yet in this session"));
            return;
        }
        page.Visibility = Visibility.Visible;
        headerHost.Child = Header(turns);
        timeline.Rebuild();
        LayoutSplit(animated: IsLoaded);
    }

    // MARK: The split

    /// The timeline column, then (while a chip's diff shows) gap, hairline, gap and the pane.
    /// Hidden (Ctrl B), the column keeps its width inside and is clipped to nothing, so its text
    /// does not re-wrap while the width springs.
    private void LayoutSplit(bool animated)
    {
        if (state is null || timeline is null || Root.ActualWidth <= 0) return;
        double full = Root.ActualWidth;
        var selected = state.ChangesSelectedFile;
        bool shown = state.ChangesTool.PaneOpen && selected is not null;
        bool hidden = shown && state.ChangesTool.ColumnHidden;
        double contentWidth = shown ? Math.Min(Theme.Size.ChangesColumnWidth, full) : full;
        timeline.ColumnWidth = contentWidth;
        timeline.Height = Math.Max(0, Root.ActualHeight - Theme.Size.ChangesHeaderHeight - Theme.Size.SpaceS);

        double target = hidden ? 0 : contentWidth;
        if (!columnPlaced || !animated)
        {
            Transitions.Snap(columnHost, WidthProperty, target);
            columnPlaced = true;
        }
        else if (Math.Abs(columnHost.Width - target) > 0.5 || double.IsNaN(columnHost.Width))
        {
            Transitions.Animate(columnHost, WidthProperty, Theme.Motion.ChangesLayout, target);
        }

        // The hairline fades in with the pane, and goes with the column.
        hairline.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        hairline.Opacity = hidden ? 0 : 1;
        hairline.Margin = hidden ? new Thickness(0) : new Thickness(Theme.Size.FilesColumnGap, 0, Theme.Size.FilesColumnGap, 0);

        if (shown && selected is { } s)
        {
            var key = ChangesIds.Chip(new ChangesChipKey(s.Turn.Id, s.File.Path));
            if (pane is null || paneKey != key)
            {
                bool arriving = pane is null;
                if (pane is not null) paneHost.Children.Remove(pane);
                pane = new ChangesDiffPane(state, s.Turn, s.File, s.Number, arriving);
                paneKey = key;
                Grid.SetColumn(pane, 1);
                paneHost.Children.Add(pane);
                if (arriving && animated) Transitions.FadeIn(hairline);
            }
        }
        else if (pane is not null)
        {
            // Esc: the pane drops 6 pt and fades, the column springs back.
            var leaving = pane;
            pane = null;
            paneKey = null;
            if (animated) Transitions.Remove(leaving, Theme.Motion.ChangesPaneTransition, () => paneHost.Children.Remove(leaving));
            else paneHost.Children.Remove(leaving);
        }
    }

    // MARK: Header

    /// "14 turns · 9 files · +607 −0 · 1h 12m" on the left (the whole session, whatever the
    /// filter), "· 3 with edits" after it while the filter is on, and the "With edits /" pill on
    /// the right: neutral, white while on; it pops when pressed.
    private FrameworkElement Header(List<TranscriptTurn> turns)
    {
        bool on = state!.ChangesTool.EditsOnly;
        var files = turns.SelectMany(t => t.Files).ToList();
        int paths = files.Select(f => f.Path).Distinct().Count();

        var totals = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        totals.Children.Add(Ui.Text(Format.Turns(turns.Count) + Theme.Glyphs.Separator + Format.Files(paths) + Theme.Glyphs.Separator,
            Theme.Fonts.Caption, Theme.Brushes.InkSecondary).Fixed());
        totals.Children.Add(new DiffCounts(files.Sum(f => f.Added), files.Sum(f => f.Removed)));
        var span = Ui.Text("", Theme.Fonts.Caption, Theme.Brushes.InkSecondary).Fixed();
        totals.Children.Add(span);
        UpdateSpan(span, turns);
        if (on)
        {
            var withEdits = Ui.Text(Theme.Glyphs.Separator + turns.Count(t => t.Files.Count > 0) + " with edits",
                Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed();
            totals.Children.Add(withEdits);
            if (!editsOnlyBefore) Transitions.Insert(withEdits, Theme.Motion.PaneSwapTransition);
        }

        var pill = new ActionSegment("With edits", Theme.Keys.Slash, on ? ActionRole.Allow : ActionRole.Neutral, state.ToggleChangesEditsOnly)
        {
            ToolTip = on ? "Show every turn" : "Show only the turns that changed files",
        };
        if (on != editsOnlyBefore && IsLoaded) pill.Loaded += (_, _) => Transitions.CountPop(pill);
        editsOnlyBefore = on;

        var row = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(pill, Dock.Right);
        // SwiftUI: spacing, `Spacer(minLength: spaceM)`, spacing before the pill.
        pill.Margin = new Thickness(3 * Theme.Size.SpaceM, 0, 0, 0);
        row.Children.Add(pill);
        row.Children.Add(totals);
        totals.ClipToBounds = true;
        return row;
    }

    /// " · 1h 12m": the first turn's start to the last turn's end, or to now while one runs.
    private void UpdateSpan(TextLine span, List<TranscriptTurn> turns)
    {
        spanTimer?.Stop();
        var first = turns.Count > 0 ? turns[^1].StartedAt : DateTime.UtcNow;
        bool live = state!.ChangesLiveTurnId(turns) is not null;
        var end = turns.Select(t => t.EndedAt).OfType<DateTime>().DefaultIfEmpty(first).Max();
        void Tick() => span.Text = Theme.Glyphs.Separator + Format.Duration(((live ? DateTime.UtcNow : end) - first).TotalSeconds);
        Tick();
        if (!live) return;
        spanTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.ClockTick) };
        spanTimer.Tick += (_, _) => Tick();
        spanTimer.Start();
    }
}
