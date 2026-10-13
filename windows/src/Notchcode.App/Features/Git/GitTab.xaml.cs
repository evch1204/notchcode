// GitTab.xaml.cs
// Port of Sources/notchcode/Features/Git/GitTab.swift.
// The Git tool, Direction F (Dock and Stage): three fixed regions, header, rail and stage,
// where nothing appears from nowhere; the thing pressed travels to where the next step is.
//
// The header row: the target pill ("notchcode › seadevil ▾  W", the repository dim, the
// worktree in ink), the branch (mono), the status ("not published yet", "up to date with
// origin", "2 behind", "no remote"), which is also the one place every result lands
// ("Committed 3 files", "Pushed 3 commits", git's error in red), and the sync pill with its P
// keycap, GitHub Desktop's order: "Publish 4", "Pull 2", "Push 3", else a dark "Fetch" (the
// tool also fetches quietly when it opens, at most every five minutes).
//
// The rail (left, the Files tree's share): "Uncommitted · 4" (or "3 of 4") with a tri-state
// box and the checked files' totals, one row per changed file (a checkbox, all in by
// default, space toggles the cursor's; name, the five ± cells, the counts), the cursor's fill
// gliding between rows, and at its foot the dock: the commit's summary field, always there.
// No commit list: the sync pill's count is the unpushed count. Ctrl B folds the rail to its
// checkbox column. A branch checked out nowhere shows "Changes vs main · 6": no boxes, no dock.
//
// The stage (right): a header (the Ctrl B pill, then the file, "Commit to main", or nothing
// for a confirm) over one of the reviewer diff, the commit form, the confirm, or the clean
// note, which trade places with a drop and a rise. C or a click on the dock sends the dock's
// field up into the stage, where it becomes the form's summary, the description and the
// co-authors rise under it, and the dock's slot stays empty; esc sends it back with the text
// kept. A commit sends it back as a receipt, "Committed · <subject>" with Undo (U), which
// stays until the commit is pushed; the committed rows fold away. P arms the sync pill where
// it is (it pops, its keycap turns ⏎) and the stage asks the question with "⏎ or Push again"
// and Cancel; ⏎ or the pill runs it and the pill pulses. A fetch runs in place.
//
// W (or the pill) replaces the content with the branch picker: the repository pill
// ("notchcode ▾", R opens the dropdown of repositories), its folder, then one row per local
// branch, newest commit first: the branch in mono, where it lives under it, "session" and
// "current" tags, the counts on the right. Past eight branches a filter field shows (/).
// The target pill stays put and the repository pill takes its place, the branch, status and
// sync pill slide right and fade, the panes drop away, and the rows unfold top down; closing
// is a plain fade and the reverse.

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Git;

public partial class GitTab : UserControl
{
    private readonly AppState state;
    private readonly Grid closedSide = new();
    private readonly GitBranchPicker picker = new();
    /// Over everything in the tool: where the dock's box travels (its ghost), never clipped.
    private readonly Canvas travelLayer = new() { IsHitTestVisible = false, ClipToBounds = false };
    private UIElement? note;
    private string? noteKey;
    private GitContent? content;
    private bool pending;
    private bool? pickerOpenBefore;

    /// AppState properties the tool reads; a change to any re-renders it once per frame.
    private static readonly HashSet<string> Watched =
    [
        nameof(AppState.GitPanel), nameof(AppState.RowCursor), nameof(AppState.Prefs), nameof(AppState.FocusedSessionId),
        nameof(AppState.Sessions), nameof(AppState.SelectedTab), nameof(AppState.IsCardOpen), nameof(AppState.Pending),
    ];

    public GitTab(AppState state)
    {
        this.state = state;
        InitializeComponent();
        Root.Children.Add(closedSide);
        Root.Children.Add(picker);
        Root.Children.Add(travelLayer);
        Loaded += (_, _) =>
        {
            state.PropertyChanged += OnStateChanged;
            Render();
        };
        Unloaded += (_, _) => state.PropertyChanged -= OnStateChanged;
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is null || !Watched.Contains(e.PropertyName) || pending) return;
        pending = true;
        Dispatcher.BeginInvoke(() => { pending = false; Render(); }, DispatcherPriority.Render);
    }

    /// The stage's line when there is no file to show, after the green check.
    public static string EmptyText(GitSnapshot snap)
    {
        if (!snap.CheckedOut) return snap.Base is { } b ? "Nothing ahead of " + b : "Nothing to compare";
        bool upToDate = snap.Upstream is not null && snap.Behind == 0;
        return upToDate ? "Nothing to commit" + Theme.Glyphs.Separator + "up to date" : "Nothing to commit";
    }

    /// The content and the picker both stay in the tree; only their parts come and go, so
    /// each part's transition fires.
    public void Render()
    {
        if (!state.ReadsLocalFiles)
        {
            SetNote("Git reads the real worktree" + Theme.Glyphs.Separator + "off in the demo", animate: false);
            return;
        }
        bool open = state.GitPanel.PickerOpen;
        // The target pill and the repository pill share one frame across the swap: the
        // arriving one starts at the leaving one's width and springs to its own.
        double? morphFrom = null;
        if (pickerOpenBefore is { } before && before != open)
            morphFrom = open ? content?.Header.TargetPill?.ActualWidth : picker.RepoPill?.ActualWidth;
        pickerOpenBefore = open;
        if (state.GitCwd is null)
        {
            DropContent();
            SetNote(open ? null : "No session", animate: true);
        }
        else if (state.FocusedGit is { IsRepo: true } snap)
        {
            SetNote(null, animate: false);
            if (content is null)
            {
                content = new GitContent(state, this, travelLayer);
                closedSide.Children.Add(content);
            }
            content.Update(snap, open);
        }
        else
        {
            DropContent();
            SetNote(open ? null : state.FocusedGit is null ? "Reading git" + Theme.Glyphs.Ellipsis : "Not a git repository", animate: true);
        }
        picker.Update(state, open);
        if (morphFrom is > 0 and var from && !Theme.Motion.ReduceMotion)
            Dispatcher.BeginInvoke(() => MorphPill(open ? picker.RepoPill : content?.Header.TargetPill, from), DispatcherPriority.Loaded);
    }

    /// matchedGeometryEffect(id: pillID, anchor: .leading) on the frame: both pills sit at the
    /// header's leading edge, so the arriving one's width springs from the leaving one's
    /// (`pickerPill`), its content clipped meanwhile; the two crossfade on their own.
    private static void MorphPill(FrameworkElement? arriving, double from)
    {
        if (arriving is null || !arriving.IsVisible || arriving.ActualWidth <= 0) return;
        double to = arriving.ActualWidth;
        if (Math.Abs(to - from) < 1) return;
        arriving.ClipToBounds = true;
        Transitions.Snap(arriving, WidthProperty, from);
        Transitions.Animate(arriving, WidthProperty, Theme.Motion.PickerPill, to,
            () => Transitions.Snap(arriving, WidthProperty, double.NaN));
    }

    private void DropContent()
    {
        if (content is null) return;
        closedSide.Children.Remove(content);
        content = null;
    }

    private void SetNote(string? text, bool animate)
    {
        if (text == noteKey) return;
        noteKey = text;
        if (note is FrameworkElement old)
        {
            if (animate) Transitions.Remove(old, Theme.Motion.PickerHeadTransition, () => closedSide.Children.Remove(old));
            else closedSide.Children.Remove(old);
        }
        note = null;
        if (text is null) return;
        var next = new EmptyNote(text);
        closedSide.Children.Add(next);
        note = next;
        if (animate) Transitions.Insert(next, Theme.Motion.PickerHeadTransition);
    }
}

/// The header over the panes (rail, hairline, stage). The panes drop away while the picker
/// is open; the header keeps its height.
internal sealed class GitContent : ColumnStack
{
    private readonly AppState state;
    private readonly FrameworkElement tab;
    private readonly GitHeader header = new();
    public GitHeader Header => header;
    private readonly Grid panes = new();
    private readonly Grid railBox = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ColumnStack railInner = new() { Spacing = Theme.Size.SpaceXS };
    private readonly GitRailHeader railHeader = new();
    private readonly GitRailRows rows;
    private readonly GitDock dock;
    private readonly GitDiffPane stage = new();
    private bool? openBefore;
    private bool? foldedBefore;
    private bool composingBefore;
    private GitReceipt? receiptBefore;
    private double railWidth;
    private readonly Canvas travelLayer;

    public GitContent(AppState state, FrameworkElement tab, Canvas travelLayer)
    {
        this.state = state;
        this.tab = tab;
        this.travelLayer = travelLayer;
        Spacing = Theme.Size.SpaceS;
        rows = new GitRailRows(state);
        dock = new GitDock(state);
        Children.Add(header);

        // Rail, hairline, stage. The rail takes `fileTreeShare` of the width, or folded (Ctrl B,
        // the Files tree's switch) its checkbox column: its content keeps its width and is
        // clipped, so the boxes stay put while the width springs and everything else fades.
        // The stage draws over the rail, so the dock's box travelling in lands on top.
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        railInner.Children.Add(railHeader);
        railInner.Children.Add(Kit.Flex(rows));
        // The header and rows are clipped to the rail's (springing) width; the dock is not, so
        // its box can leave and land whole.
        railInner.HorizontalAlignment = HorizontalAlignment.Left;
        var railClip = new Grid { ClipToBounds = true, HorizontalAlignment = HorizontalAlignment.Left };
        railClip.SetBinding(WidthProperty, new System.Windows.Data.Binding(nameof(ActualWidth)) { Source = railBox });
        railClip.Children.Add(railInner);
        var rail = new ColumnStack { Spacing = Theme.Size.SpaceXS };
        rail.Children.Add(Kit.Flex(railClip));
        dock.Margin = new Thickness(0, Theme.Size.SpaceS, 0, 0);
        rail.Children.Add(dock);
        railBox.Children.Add(rail);
        railBox.Margin = new Thickness(0, 0, Theme.Size.FilesColumnGap, 0);
        Grid.SetColumn(railBox, 0);
        var divider = Kit.Rule(Theme.Brushes.PaneDivider, width: Theme.Size.Hairline);
        divider.Margin = new Thickness(0, 0, Theme.Size.FilesColumnGap, 0);
        Grid.SetColumn(divider, 1);
        Grid.SetColumn(stage, 2);
        panes.Children.Add(railBox);
        panes.Children.Add(divider);
        panes.Children.Add(stage);
        Children.Add(Kit.Flex(panes));
        panes.SizeChanged += (_, e) =>
        {
            if (!e.WidthChanged) return;
            railWidth = Math.Floor(e.NewSize.Width * Theme.Size.FileTreeShare);
            rail.Width = railWidth;
            railInner.Width = railWidth;
            Transitions.Snap(railBox, WidthProperty, state.GitListCollapsed ? Theme.Size.GitRailFolded : railWidth);
        };
    }

    public void Update(GitSnapshot snap, bool open)
    {
        header.Update(state, snap, open);

        // The panes drop away while the picker shows, and rise back after.
        if (openBefore != open)
        {
            bool animate = openBefore is not null;
            openBefore = open;
            if (!open)
            {
                panes.Visibility = Visibility.Visible;
                if (animate) Transitions.Insert(panes, Theme.Motion.PickerPanesTransition);
            }
            else if (animate)
            {
                Transitions.Remove(panes, Theme.Motion.PickerPanesTransition, () => { if (openBefore == true) panes.Visibility = Visibility.Hidden; });
            }
            else
            {
                panes.Visibility = Visibility.Hidden;
            }
        }

        // Ctrl B: the rail's width springs between its share and the checkbox column.
        bool folded = state.GitListCollapsed;
        if (foldedBefore != folded)
        {
            bool animate = foldedBefore is not null && railWidth > 0;
            foldedBefore = folded;
            double width = folded ? Theme.Size.GitRailFolded : railWidth;
            if (railWidth > 0)
            {
                if (animate) Transitions.Animate(railBox, WidthProperty, Theme.Motion.RailFold, width);
                else Transitions.Snap(railBox, WidthProperty, width);
            }
            dock.IsHitTestVisible = !folded;
            if (animate) Transitions.Animate(dock, OpacityProperty, Theme.Motion.RailFade, folded ? 0 : 1);
            else Transitions.Snap(dock, OpacityProperty, folded ? 0 : 1);
        }

        // The dock's box and the form's summary box are one box: record where it is now, then
        // let it glide to where it lands (`dockTravel`).
        var draft = state.GitDraft;
        bool composing = draft.Composing && !GitConfirm.Shows(state.GitPhase);
        var receipt = state.GitReceipt;
        Rect? from = null;
        FrameworkElement? arriving = null;
        if (composing != composingBefore)
        {
            from = composing ? dock.BoxRect(tab) : RectIn(stage.Form.SummaryBox, tab);
        }

        railHeader.Update(state, snap, folded, rows.TickAll);
        rows.Update(snap, folded);
        dock.Visibility = snap.CheckedOut ? Visibility.Visible : Visibility.Collapsed;
        dock.Update(state, snap);
        stage.Update(state, snap);
        railBox.SetValue(Panel.ZIndexProperty, composing ? 0 : 2);

        if (from is { } source && source.Width > 0 && !Theme.Motion.ReduceMotion)
        {
            arriving = composing ? stage.Form.SummaryBox : dock.Box;
            var target = arriving;
            // The box waits hidden in its slot while its ghost makes the trip.
            if (target is not null) target.Opacity = 0;
            Dispatcher.BeginInvoke(() => Travel(target, source), DispatcherPriority.Loaded);
        }
        else if (receipt is not null && receiptBefore is null && !composing && dock.Box is { } landed)
        {
            // A commit landing: the receipt's check pops in the dock.
            Transitions.FadeIn(landed);
        }
        composingBefore = composing;
        receiptBefore = receipt;
    }

    private static Rect? RectIn(FrameworkElement? element, FrameworkElement root)
    {
        if (element is null || !element.IsVisible || element.ActualWidth <= 0) return null;
        try
        {
            var p = element.TransformToVisual(root).Transform(new Point(0, 0));
            return new Rect(p.X, p.Y, element.ActualWidth, element.ActualHeight);
        }
        catch (InvalidOperationException) { return null; }
    }

    /// The box glides from `source` (where the other end of the travel was) to `box`'s place,
    /// stretching as it goes; it never fades, only its text fades in where it lands. A ghost
    /// of the box (its fill and radius) makes the trip in the tool's top layer, drawn over
    /// both regions and clipped by neither (SwiftUI's matchedGeometryEffect); the real box
    /// shows when it lands.
    private void Travel(FrameworkElement? box, Rect source)
    {
        if (box is null || RectIn(box, tab) is not { } target)
        {
            if (box is not null) box.Opacity = 1;
            return;
        }
        var ghost = new Border
        {
            Width = source.Width,
            Height = target.Height,
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            Background = (box as Border)?.Background ?? Theme.Brushes.FilterFill,
        };
        Canvas.SetLeft(ghost, target.X);
        Canvas.SetTop(ghost, target.Y);
        travelLayer.Children.Add(ghost);
        var translate = Transitions.Translate(ghost);
        Transitions.Snap(translate, TranslateTransform.XProperty, source.X - target.X);
        Transitions.Snap(translate, TranslateTransform.YProperty, source.Y - target.Y);
        var spec = Theme.Motion.DockTravel;
        int left = 3;
        void landed()
        {
            if (--left > 0) return;
            travelLayer.Children.Remove(ghost);
            box.Opacity = 1;
            if (box is Border { Child: UIElement text }) Transitions.FadeIn(text);
        }
        Transitions.Animate(translate, TranslateTransform.XProperty, spec, 0, landed);
        Transitions.Animate(translate, TranslateTransform.YProperty, spec, 0, landed);
        Transitions.Animate(ghost, WidthProperty, spec, target.Width, landed);
    }
}

/// "☑ Uncommitted · 4 ········ +38 −6": the box puts every file in or takes every one out (a
/// dash when some are in), the count reads "3 of 4" when some are left out and rolls as it
/// changes, the totals are the checked files'. A branch page: "Changes vs main · 6", no box,
/// no totals. Folded, only the box stays.
internal sealed class GitRailHeader : Grid
{
    private readonly GitCheckbox box = new();
    private readonly TextBlock title = new() { VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap };
    private readonly RollingText count = new("", Theme.Fonts.GroupHeader, Theme.Brushes.GitSection);
    private readonly RollingText totals = new("", Theme.Fonts.Tiny, Theme.Brushes.GitRailTotals);
    private readonly RowStack words;
    private Action? onToggleAll;
    private string? countBefore;
    private bool? foldedBefore;

    public GitRailHeader()
    {
        Height = Theme.Size.GitRailHeaderHeight;
        Theme.Fonts.GroupHeader.Apply(title);
        title.Foreground = Theme.Brushes.GitSection;
        var label = new RowStack(0, title, count);
        RowStack.SetPriority(label, 1);
        words = new RowStack(Theme.Size.SpaceM, label, Kit.Spacer(Theme.Size.SpaceS), totals);
        box.Toggled += () => onToggleAll?.Invoke();
        var row = new RowStack(Theme.Size.GitCheckboxGap, box, Kit.Flex(words))
        {
            Margin = new Thickness(Theme.Size.TreeRowHPadding, 0, Theme.Size.TreeRowHPadding, 0),
        };
        Children.Add(row);
    }

    public void Update(AppState state, GitSnapshot snap, bool folded, Action tickAll)
    {
        int total = state.GitRows.Count;
        var checkedFiles = state.GitCheckedFiles;
        int n = checkedFiles.Count;
        bool boxed = snap.CheckedOut && total > 0;
        var value = n == total ? CheckValue.All : n == 0 ? CheckValue.None : CheckValue.Mixed;
        onToggleAll = () => { tickAll(); state.ToggleAllGitFiles(); };
        box.Visibility = boxed ? Visibility.Visible : Visibility.Collapsed;
        box.Set(value, 0);
        box.ToolTip = value == CheckValue.All ? "Leave every file out" : "Put every file in";
        var t = snap.CheckedOut ? "Uncommitted" : "Changes vs " + (snap.Base ?? "base");
        string? c = total == 0 ? null : !snap.CheckedOut || n == total ? total.ToString() : $"{n} of {total}";
        title.Text = t + (c is null ? "" : Theme.Glyphs.Separator);
        count.Text = c ?? "";
        if (c != countBefore && countBefore is not null && c is not null) Transitions.CountPop(count);
        countBefore = c;
        totals.Visibility = boxed && n > 0 ? Visibility.Visible : Visibility.Collapsed;
        totals.Text = "+" + checkedFiles.Sum(f => f.Added) + " " + Theme.Glyphs.Minus + checkedFiles.Sum(f => f.Removed);
        if (foldedBefore != folded)
        {
            if (foldedBefore is null) Transitions.Snap(words, OpacityProperty, folded ? 0 : 1);
            else Transitions.Animate(words, OpacityProperty, Theme.Motion.RailFade, folded ? 0 : 1);
            foldedBefore = folded;
        }
    }
}

/// The rows: one per file. A plain stack, not a virtualised one: rows leave (a commit) and
/// come back (an undo) with staggered height transitions. The cursor's fill is one shape
/// behind them that glides from row to row.
internal sealed class GitRailRows : Grid
{
    private readonly AppState state;
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: false);
    private readonly Grid layer = new();
    private readonly Border cursorFill = new()
    {
        Height = Theme.Size.TreeRowHeight,
        VerticalAlignment = VerticalAlignment.Top,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        CornerRadius = new CornerRadius(Theme.Radius.Chip),
        Background = Theme.Brushes.TreeOpened,
        Visibility = Visibility.Hidden,
    };
    private readonly StackPanel stack = new();
    private readonly TextBlock empty;
    private readonly Dictionary<string, GitFileRow> rowsByKey = [];
    private readonly HashSet<GitFileRow> leaving = [];
    private bool first = true;
    private int cursorBefore = -1;
    private bool bulkTick;

    public GitRailRows(AppState state)
    {
        this.state = state;
        empty = Kit.Text("", Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        empty.Margin = new Thickness(Theme.Size.TreeRowHPadding, 0, Theme.Size.TreeRowHPadding, 0);
        empty.HorizontalAlignment = HorizontalAlignment.Left;
        layer.Children.Add(cursorFill);
        layer.Children.Add(stack);
        var column = new StackPanel();
        column.Children.Add(empty);
        column.Children.Add(layer);
        scroll.Content = column;
        Children.Add(scroll);
    }

    /// The header's box ticked every row: for a moment the rows tick one after another.
    public void TickAll()
    {
        bulkTick = true;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Motion.CheckStaggerWindow) };
        timer.Tick += (_, _) => { timer.Stop(); bulkTick = false; };
        timer.Start();
    }

    public void Update(GitSnapshot snap, bool folded)
    {
        var items = state.GitRows;
        var selected = state.GitCursorRowKey;
        var unchecked_ = state.GitDraft.Unchecked;
        empty.Text = snap.CheckedOut ? "No changed files" : "No changes";
        empty.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        empty.Opacity = folded ? 0 : 1;

        // A commit folds the checked rows away top down: each one's place among them.
        var checkedIndex = new Dictionary<string, int>();
        foreach (var item in items) if (!unchecked_.Contains(item.File.Path)) checkedIndex[item.Key] = checkedIndex.Count;
        var keys = items.Select(i => i.Key).ToHashSet();

        foreach (var (key, row) in rowsByKey.ToList())
        {
            if (keys.Contains(key)) continue;
            rowsByKey.Remove(key);
            leaving.Add(row);
            var r = row;
            Transitions.Remove(r, Theme.Motion.RailRowCollapse(row.CheckedIndex, 0), () => { stack.Children.Remove(r); leaving.Remove(r); });
        }

        var ordered = new List<UIElement>();
        for (int index = 0; index < items.Count; index++)
        {
            var item = items[index];
            bool? isChecked = snap.CheckedOut ? !unchecked_.Contains(item.File.Path) : null;
            double tickDelay = bulkTick ? Theme.Motion.CheckStagger * Math.Min(index, Theme.Motion.RowStaggerCap) : 0;
            if (!rowsByKey.TryGetValue(item.Key, out var row))
            {
                var key = item.Key;
                var path = item.File.Path;
                row = new GitFileRow(() => state.ToggleGitFile(path), () => state.SelectGitRow(key))
                {
                    Margin = new Thickness(0, 0, 0, Theme.Size.SpaceXS),
                };
                rowsByKey[item.Key] = row;
                row.Update(item.File, isChecked, folded, tickDelay, animate: false);
                // An undo brings rows back bottom up; the first read just shows them.
                if (!first) Transitions.Insert(row, Theme.Motion.RailRowCollapse(0, items.Count - 1 - index));
            }
            else
            {
                row.Update(item.File, isChecked, folded, tickDelay, animate: true);
            }
            row.CheckedIndex = checkedIndex.GetValueOrDefault(item.Key);
            ordered.Add(row);
        }
        // Leaving rows keep their place while they fold.
        var current = stack.Children.Cast<UIElement>().ToList();
        foreach (var row in leaving)
        {
            int at = Math.Min(current.IndexOf(row), ordered.Count);
            ordered.Insert(at < 0 ? ordered.Count : at, row);
        }
        if (!current.SequenceEqual(ordered))
        {
            stack.Children.Clear();
            foreach (var e in ordered) stack.Children.Add(e);
        }
        first = false;

        // The cursor's fill glides to the selected row (folded: the checkbox column only).
        int cursor = selected is null ? -1 : items.FindIndex(i => i.Key == selected);
        cursorFill.Visibility = cursor >= 0 ? Visibility.Visible : Visibility.Hidden;
        cursorFill.HorizontalAlignment = folded ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        cursorFill.Width = folded ? Theme.Size.GitRailFolded : double.NaN;
        if (cursor >= 0)
        {
            double y = cursor * (Theme.Size.TreeRowHeight + Theme.Size.SpaceXS);
            var t = Transitions.Translate(cursorFill);
            if (cursorBefore < 0) Transitions.Snap(t, TranslateTransform.YProperty, y);
            else if (cursor != cursorBefore) Transitions.Animate(t, TranslateTransform.YProperty, Theme.Motion.PickerPill, y);
            if (cursor != cursorBefore)
            {
                double top = y, bottom = y + Theme.Size.TreeRowHeight;
                Dispatcher.BeginInvoke(() =>
                {
                    if (top < scroll.VerticalOffset) ScrollExtras.GlideTo(scroll, top);
                    else if (bottom > scroll.VerticalOffset + scroll.ViewportHeight) ScrollExtras.GlideTo(scroll, bottom - scroll.ViewportHeight);
                }, DispatcherPriority.Loaded);
            }
        }
        cursorBefore = cursor;
    }
}

/// "☑ GitPanel.swift     ▮▮▮▮▮ +12 −3": the box that puts the file in the commit (a checkout
/// only), the file's name (full path on hover; dim when left out, its cells too), the five
/// cells, then the counts. A click on the box toggles it without moving the cursor; anywhere
/// else selects the row. Folded, only the box (and the fill under it) shows.
internal sealed class GitFileRow : Grid
{
    private readonly GitCheckbox box = new();
    private readonly Border button = new() { Background = Kit.HitFill };
    private PathLabel? name;
    private FrameworkElement? cells;
    private string? fileKey;
    private bool? checkedBefore;
    private bool? foldedBefore;

    /// This row's place among the checked rows, for the fold-away stagger.
    public int CheckedIndex { get; set; }

    public GitFileRow(Action onToggle, Action onSelect)
    {
        Height = Theme.Size.TreeRowHeight;
        box.Toggled += onToggle;
        Kit.OnClick(button, onSelect);
        var row = new RowStack(Theme.Size.GitCheckboxGap, box, Kit.Flex(button))
        {
            Margin = new Thickness(Theme.Size.TreeRowHPadding, 0, Theme.Size.TreeRowHPadding, 0),
        };
        Children.Add(row);
    }

    /// `isChecked`: null on a branch page, where nothing is committed.
    public void Update(FileChange file, bool? isChecked, bool folded, double tickDelay, bool animate)
    {
        var key = file.Path + "|" + file.Added + "|" + file.Removed;
        if (key != fileKey)
        {
            fileKey = key;
            name = new PathLabel(file.Path);
            cells = new RowStack(Theme.Size.SpaceS, new DiffCells(file.Added, file.Removed), new DiffCounts(file.Added, file.Removed));
            RowStack.SetPriority(cells, 1);
            button.Child = new RowStack(Theme.Size.SpaceM, Kit.Flex(name), cells);
            checkedBefore = null;
        }
        box.Visibility = isChecked is null ? Visibility.Collapsed : Visibility.Visible;
        box.ToolTip = isChecked == true
            ? $"In the commit ({Theme.Keys.Toggle} leaves it out)"
            : $"Left out of the commit ({Theme.Keys.Toggle} puts it in)";
        if (isChecked is { } on) box.Set(on ? CheckValue.All : CheckValue.None, tickDelay, animate && checkedBefore is not null);
        // An unchecked file's name and cells dim.
        if (checkedBefore != isChecked)
        {
            bool dim = isChecked == false;
            var brush = dim ? Theme.Brushes.GitUnchecked : Theme.Brushes.Ink;
            name!.Foreground = brush;
            double cellsOpacity = dim ? Theme.Opacity.GitUncheckedCells : 1;
            if (animate && checkedBefore is not null) Transitions.Animate(cells!, OpacityProperty, Theme.Motion.CheckDim, cellsOpacity);
            else Transitions.Snap(cells!, OpacityProperty, cellsOpacity);
            checkedBefore = isChecked;
        }
        if (foldedBefore != folded)
        {
            button.IsHitTestVisible = !folded;
            if (animate && foldedBefore is not null) Transitions.Animate(button, OpacityProperty, Theme.Motion.RailFade, folded ? 0 : 1);
            else Transitions.Snap(button, OpacityProperty, folded ? 0 : 1);
            foldedBefore = folded;
        }
    }
}

public enum CheckValue { All, None, Mixed }

/// A commit checkbox: empty with a tertiary edge, or white with a dark check drawn as a
/// stroke (all in) or a dash (some in, the header's). Unticking shrinks the fill as it fades.
public sealed class GitCheckbox : Grid
{
    private readonly Border edge;
    private readonly Border fill;
    private readonly Path check;
    private readonly Border dash;
    private readonly double checkLength;
    private CheckValue? value;
    public event Action? Toggled;

    public GitCheckbox()
    {
        Width = Height = Theme.Size.GitCheckbox;
        VerticalAlignment = VerticalAlignment.Center;
        Background = Kit.HitFill;
        var radius = new CornerRadius(Theme.Radius.GitCheckbox);
        edge = new Border { CornerRadius = radius, BorderBrush = Theme.Brushes.GitCheckStroke, BorderThickness = new Thickness(Theme.Size.GitCheckboxStroke) };
        fill = new Border { CornerRadius = radius, Background = Theme.Brushes.GitCheckFill, RenderTransformOrigin = new Point(0.5, 0.5) };
        var markBox = new Rect(0, 0, Theme.Size.GitCheckMark, Theme.Size.GitCheckMark);
        checkLength = GlyphShapes.CheckLength(markBox) / Theme.Size.GitCheckLine;
        check = new Path
        {
            Data = GlyphShapes.Check(markBox),
            Stroke = Theme.Brushes.GitCheckMark,
            StrokeThickness = Theme.Size.GitCheckLine,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Width = Theme.Size.GitCheckMark,
            Height = Theme.Size.GitCheckMark,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            StrokeDashArray = [checkLength, checkLength],
            StrokeDashCap = PenLineCap.Round,
        };
        dash = new Border
        {
            Width = Theme.Size.GitCheckDash,
            Height = Theme.Size.GitCheckLine,
            CornerRadius = new CornerRadius(Theme.Size.GitCheckLine / 2),
            Background = Theme.Brushes.GitCheckMark,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Children.Add(edge);
        Children.Add(fill);
        Children.Add(check);
        Children.Add(dash);
        Kit.OnClick(this, () => Toggled?.Invoke());
    }

    /// Shows `next`; ticking draws the check as a 90 ms stroke after `delay`, unticking shrinks
    /// the fill to 60 % as it fades in 80 ms.
    public void Set(CheckValue next, double delay, bool animate = true)
    {
        if (value == next) return;
        bool firstSet = value is null;
        value = next;
        bool on = next != CheckValue.None;
        var scale = Transitions.Scale(fill);
        if (firstSet || !animate || Theme.Motion.ReduceMotion)
        {
            Transitions.Snap(edge, OpacityProperty, on ? 0 : 1);
            Transitions.Snap(fill, OpacityProperty, on ? 1 : 0);
            Transitions.Snap(scale, ScaleTransform.ScaleXProperty, on ? 1 : Theme.Size.GitUntickScale);
            Transitions.Snap(scale, ScaleTransform.ScaleYProperty, on ? 1 : Theme.Size.GitUntickScale);
            Transitions.Snap(check, Shape.StrokeDashOffsetProperty, next == CheckValue.All ? 0 : checkLength);
            check.Opacity = next == CheckValue.Mixed ? 0 : 1;
            dash.Opacity = next == CheckValue.Mixed ? 1 : 0;
            return;
        }
        var fillSpec = (on ? Theme.Motion.CheckStroke : Theme.Motion.CheckUntick).WithDelay(delay);
        Transitions.Animate(edge, OpacityProperty, fillSpec, on ? 0 : 1);
        Transitions.Animate(fill, OpacityProperty, fillSpec, on ? 1 : 0);
        Transitions.Animate(scale, ScaleTransform.ScaleXProperty, fillSpec, on ? 1 : Theme.Size.GitUntickScale);
        Transitions.Animate(scale, ScaleTransform.ScaleYProperty, fillSpec, on ? 1 : Theme.Size.GitUntickScale);
        Transitions.Animate(check, Shape.StrokeDashOffsetProperty, Theme.Motion.CheckStroke.WithDelay(delay), next == CheckValue.All ? 0 : checkLength);
        check.Opacity = next == CheckValue.Mixed ? 0 : 1;
        dash.Opacity = next == CheckValue.Mixed ? 1 : 0;
    }
}

/// The dock at the rail's foot, one 26 pt box in three looks. The field: a pen, the draft's
/// summary (or its prompt), C; a press sends it up into the stage as the form's summary.
/// Nothing while the form is up (the slot keeps its height). The receipt after a card commit,
/// while that commit is the newest and unpushed: a check, "Committed · <subject>", Undo (U).
internal sealed class GitDock : Grid
{
    private readonly AppState state;
    private string? lookKey;

    /// The box on show (the field or the receipt), null while the form is up.
    public FrameworkElement? Box { get; private set; }

    public GitDock(AppState state)
    {
        this.state = state;
        Height = Theme.Size.GitDockHeight;
    }

    public Rect? BoxRect(FrameworkElement root)
    {
        if (Box is null || !Box.IsVisible || Box.ActualWidth <= 0) return null;
        var p = Box.TransformToVisual(root).Transform(new Point(0, 0));
        return new Rect(p.X, p.Y, Box.ActualWidth, Box.ActualHeight);
    }

    public void Update(AppState state, GitSnapshot snap)
    {
        var draft = state.GitDraft;
        var receipt = state.GitReceipt;
        bool composing = draft.Composing;
        bool enabled = snap.Files.Count > 0;
        var typed = draft.Summary.Trim();
        string key = composing ? "away"
            : receipt is not null ? "receipt|" + receipt.Sha + "|" + receipt.Subject + "|" + state.GitCanUndo
            : "field|" + enabled + "|" + typed + "|" + state.GitSummaryPlaceholder;
        if (key == lookKey) return;
        lookKey = key;
        Children.Clear();
        Box = null;
        // The box is away in the stage: the slot stays empty.
        if (composing) return;
        Box = receipt is not null ? ReceiptBox(receipt) : Field(enabled, typed);
        Children.Add(Box);
    }

    private FrameworkElement Field(bool enabled, string typed)
    {
        var text = !enabled ? "Nothing to commit" : typed.Length == 0 ? state.GitSummaryPlaceholder : typed;
        var row = new RowStack(Theme.Size.SpaceS,
            Theme.Symbols.GitPen.ToPath(Theme.Fonts.CaptionSize, Theme.Brushes.GitRailTotals),
            Kit.Flex(Kit.Text(text, Theme.Fonts.Caption, enabled && typed.Length > 0 ? Theme.Brushes.Ink : Theme.Brushes.FilterPlaceholder)));
        if (enabled) row.Children.Add(new InlineKeycap(Theme.Keys.Commit));
        var box = new Border
        {
            Child = row,
            Padding = new Thickness(Theme.Size.GitFieldHPadding, 0, Theme.Size.GitFieldHPadding, 0),
            Height = Theme.Size.GitDockHeight,
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            Background = Theme.Brushes.FilterFill,
            IsEnabled = enabled,
            Opacity = enabled ? 1 : Theme.Opacity.Disabled,
            ToolTip = enabled ? $"Write the commit message ({Theme.Keys.Commit})" : "Nothing to commit",
        };
        // A hover darkens it: it is pressable.
        box.MouseEnter += (_, _) => { if (enabled) box.Background = Theme.Brushes.QuietFill; };
        box.MouseLeave += (_, _) => box.Background = Theme.Brushes.FilterFill;
        Kit.OnClick(box, state.OpenGitCommitForm);
        Transitions.FadeIn(row);
        return box;
    }

    private FrameworkElement ReceiptBox(GitReceipt receipt)
    {
        bool canUndo = state.GitCanUndo;
        var subject = Kit.Text("Committed" + Theme.Glyphs.Separator + receipt.Subject, Theme.Fonts.Caption, Theme.Brushes.InkSecondary);
        subject.ToolTip = receipt.Sha + "  " + receipt.Subject;
        var undo = new ActionSegment("Undo", Theme.Keys.Undo, ActionRole.Neutral, state.RunGitUndo)
        {
            Enabled = canUndo,
            Opacity = canUndo ? 1 : Theme.Opacity.Disabled,
            ToolTip = "Undo this commit: its changes come back to the rail and its message to the form",
        };
        var check = new DoneCheckGlyph(Theme.Size.GitPushingGlyph);
        var row = new RowStack(Theme.Size.SpaceS, check, Kit.Flex(subject), undo);
        Transitions.FadeIn(row);
        return new Border
        {
            Child = row,
            Padding = new Thickness(Theme.Size.GitFieldHPadding, 0, Theme.Size.GitDockPillInset, 0),
            Height = Theme.Size.GitDockHeight,
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            Background = Theme.Brushes.GitReceiptFill,
        };
    }
}
