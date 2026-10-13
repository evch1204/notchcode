// FilesTab.xaml.cs
// Port of Sources/notchcode/Features/Files/FilesTab.swift.
// An IDE side panel for the selected session's repository. Left (40%): a filter field and
// the tree, folders with a disclosure chevron (top level open, deeper closed), files this
// session changed with a small ±badge. Right: the chosen file, mono, line numbers, no
// wrapping; lines this session added tinted green, a red mark where lines were removed.
//
// Keys: ↑↓ move, → opens a folder, ← closes it, ⏎ opens the file, / filters (esc clears),
// y copies path:line of the first changed line, Alt ⏎ teleports. All in AppState.HandleFilesKey.
// Ctrl B collapses the tree so the preview takes the whole well; P flips a Markdown file between
// its rendered Preview and its Code. Both through HandleFilesKey.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.Features.StandIns;
using Notchcode.UI.Diff;


namespace Notchcode.Features.Files;

public partial class FilesTab : UserControl
{
    private AppState? state;
    private StateWatcher? watcher;

    private readonly Grid layout = new();
    /// The tree keeps its width and slides out to the left behind a clip.
    private readonly Border treeClip = new() { ClipToBounds = true };
    private readonly Grid treeColumn = new() { HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Border divider = new() { Background = Theme.Brushes.PaneDivider, Width = Theme.Size.Hairline };
    private readonly Grid previewPane = new();
    private readonly Border filterBox = new();
    private readonly TextBox filterText = new();
    private readonly TextBlock filterPrompt = Ui.Block("Filter", Theme.Fonts.MonoCaption, Theme.Brushes.FilterPlaceholder);
    private readonly InlineKeycap filterKeycap = new(Theme.Keys.Slash);
    private readonly ContentControl treeHost = new() { Focusable = false };
    private readonly ScrollViewer treeScroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    private readonly StackPanel treeRows = new();
    private readonly ContentControl previewHeader = new() { Focusable = false };
    private readonly ContentControl previewBody = new() { Focusable = false };

    /// Row id -> its row and whether it was open, from the last build.
    private readonly Dictionary<string, (Border Row, TreeRow Model, RowChevron? Chevron)> shownRows = [];
    private string treeSignature = "";
    private string? lastFilter;
    private object? shownPreview;
    private string? shownPath;
    private bool? shownCode;
    private string shownMarks = "";
    private bool? collapsedBefore;
    private double treeWidth;

    public FilesTab()
    {
        InitializeComponent();
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        treeColumn.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        treeColumn.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceM) });
        treeColumn.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        treeColumn.Children.Add(BuildFilterField());
        Grid.SetRow(treeHost, 2);
        treeColumn.Children.Add(treeHost);
        treeScroll.Content = treeRows;
        treeClip.Child = treeColumn;
        layout.Children.Add(treeClip);

        Grid.SetColumn(divider, 1);
        layout.Children.Add(divider);

        previewPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        previewPane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceS) });
        previewPane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        previewHeader.Margin = new Thickness(Theme.Size.PreviewHPadding, 0, Theme.Size.PreviewHPadding, 0);
        previewPane.Children.Add(previewHeader);
        Grid.SetRow(previewBody, 2);
        previewPane.Children.Add(previewBody);
        Transitions.SetParallaxGroup(previewPane, true);
        Grid.SetColumn(previewPane, 2);
        layout.Children.Add(previewPane);

        Root.Children.Add(layout);
        Root.SizeChanged += (_, _) => LayoutColumns(animated: false);
        Loaded += (_, _) => state?.LoadRepoTree();
    }

    public FilesTab(AppState state) : this() => State = state;

    public AppState? State
    {
        get => state;
        set
        {
            state = value;
            if (value is null) return;
            watcher = new StateWatcher(this, value,
                [nameof(AppState.FilesTool), nameof(AppState.FocusedSessionId), nameof(AppState.Sessions),
                 nameof(AppState.TurnsBySession), nameof(AppState.ShellFiles), nameof(AppState.Prefs)],
                Rebuild);
            Rebuild();
        }
    }

    /// Runs any pending rebuild now (the harness renders without a dispatcher turn).
    public void Flush() => watcher?.Flush();

    private void Rebuild()
    {
        if (state is null) return;
        SyncFilter();
        RebuildTree();
        RebuildPreview();
        LayoutColumns(animated: IsLoaded);
    }

    // MARK: Columns

    private void LayoutColumns(bool animated)
    {
        if (state is null || Root.ActualWidth <= 0) return;
        treeWidth = Math.Floor(Root.ActualWidth * Theme.Size.FileTreeShare);
        treeColumn.Width = treeWidth;
        treeColumn.Margin = new Thickness(0, 0, Theme.Size.FilesColumnGap, 0);
        bool collapsed = state.FilesTreeCollapsed;
        double target = collapsed ? 0 : treeWidth + Theme.Size.FilesColumnGap;
        if (collapsedBefore is null || !animated || collapsedBefore == collapsed)
        {
            Transitions.Snap(treeClip, WidthProperty, target);
            Transitions.Snap(treeClip, OpacityProperty, collapsed ? 0 : 1);
        }
        else
        {
            Transitions.Animate(treeClip, WidthProperty, Theme.Motion.TreeCollapse, target);
            Transitions.Animate(treeClip, OpacityProperty, Theme.Motion.TreeCollapse, collapsed ? 0 : 1);
        }
        collapsedBefore = collapsed;
        treeClip.IsHitTestVisible = !collapsed;
        divider.Width = collapsed ? 0 : Theme.Size.Hairline;
        divider.Margin = new Thickness(0, 0, collapsed ? 0 : Theme.Size.FilesColumnGap, 0);
    }

    // MARK: Filter

    private FrameworkElement BuildFilterField()
    {
        var glyph = GlyphShapes.FilterLines.ToPath(Theme.Fonts.TinySize, Theme.Brushes.FilterPlaceholder);
        glyph.Margin = new Thickness(0, 0, Theme.Size.SpaceS, 0);
        filterText.Background = System.Windows.Media.Brushes.Transparent;
        filterText.BorderThickness = new Thickness(0);
        filterText.Foreground = Theme.Brushes.Ink;
        filterText.CaretBrush = Theme.Brushes.Ink;
        filterText.Padding = new Thickness(0);
        filterText.VerticalContentAlignment = VerticalAlignment.Center;
        Theme.Fonts.MonoCaption.Apply(filterText);
        filterPrompt.IsHitTestVisible = false;
        filterText.TextChanged += (_, _) =>
        {
            filterPrompt.Visibility = filterText.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateFilterKeycap();
            if (state is not null && state.FilesTool.Filter != filterText.Text)
                state.FilesTool = state.FilesTool with { Filter = filterText.Text };
        };
        filterText.GotKeyboardFocus += (_, _) =>
        {
            UpdateFilterKeycap();
            if (state is not null && !state.FilesTool.FilterFocused) state.FilesTool = state.FilesTool with { FilterFocused = true };
        };
        filterText.LostKeyboardFocus += (_, _) =>
        {
            UpdateFilterKeycap();
            if (state is not null && state.FilesTool.FilterFocused) state.FilesTool = state.FilesTool with { FilterFocused = false };
        };

        var field = new Grid();
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        field.Children.Add(glyph);
        Grid.SetColumn(filterText, 1);
        Grid.SetColumn(filterPrompt, 1);
        field.Children.Add(filterText);
        field.Children.Add(filterPrompt);
        Grid.SetColumn(filterKeycap, 2);
        field.Children.Add(filterKeycap);

        filterBox.Child = field;
        filterBox.Padding = new Thickness(Theme.Size.FilterHPadding, 0, Theme.Size.FilterHPadding, 0);
        filterBox.Height = Theme.Size.FilterHeight;
        filterBox.CornerRadius = new CornerRadius(Theme.Radius.Chip);
        filterBox.Background = Theme.Brushes.FilterFill;
        return filterBox;
    }

    private void UpdateFilterKeycap()
        => filterKeycap.Visibility = filterText.Text.Length == 0 && !filterText.IsKeyboardFocused && InlineKeycap.GetInlineKeycaps(filterKeycap)
            ? Visibility.Visible : Visibility.Collapsed;

    /// The field follows `FilesTool.Filter` and `FilterFocused` (esc clears and blurs it from the card).
    private void SyncFilter()
    {
        var tool = state!.FilesTool;
        if (filterText.Text != tool.Filter) filterText.Text = tool.Filter;
        if (tool.FilterFocused && !filterText.IsKeyboardFocused) filterText.Dispatcher.BeginInvoke(() => Keyboard.Focus(filterText));
        else if (!tool.FilterFocused && filterText.IsKeyboardFocused) Keyboard.ClearFocus();
        UpdateFilterKeycap();
    }

    // MARK: Tree

    private void RebuildTree()
    {
        if (state!.FocusedSession is null)
        {
            SetTreeHost(new EmptyNote("No session", Theme.Fonts.Caption));
            return;
        }
        if (state.FocusedTree is not { } nodes)
        {
            SetTreeHost(new EmptyNote("Reading files" + Theme.Glyphs.Ellipsis, Theme.Fonts.Caption));
            return;
        }
        if (nodes.Count == 0)
        {
            SetTreeHost(new EmptyNote("No files here", Theme.Fonts.Caption));
            return;
        }
        var rows = state.VisibleTreeRows();
        if (rows.Count == 0)
        {
            SetTreeHost(new EmptyNote("No matches", Theme.Fonts.Caption));
            treeSignature = "";
            return;
        }
        SetTreeHost(treeScroll);

        var counts = state.SessionChangeCounts;
        var cursor = state.TreeCursorPath;
        var opened = state.OpenedFilePath;
        var signature = string.Join("\n", rows.Select(r => r.Id + (r.IsOpen ? "+" : "") + (counts.TryGetValue(r.Id, out var c) ? c.ToString() : "")));
        if (signature != treeSignature)
        {
            bool filterChanged = lastFilter is not null && lastFilter != state.FilesTool.Filter;
            var before = shownRows.ToDictionary(kv => kv.Key, kv => kv.Value.Model);
            bool first = treeSignature.Length == 0;
            treeRows.Children.Clear();
            shownRows.Clear();
            foreach (var row in rows)
            {
                var view = TreeRowView(row, row.Node.IsDirectory ? null : counts.TryGetValue(row.Id, out var count) ? count : null,
                    out var chevron, before.TryGetValue(row.Id, out var was) ? was.IsOpen : row.IsOpen);
                shownRows[row.Id] = (view, row, chevron);
                treeRows.Children.Add(view);
                var current = row;
                view.OnTap(() => state.ClickTreeRow(current));
                // Children rise in under a folder that just opened, one row-stagger apart.
                if (!first && !filterChanged && !before.ContainsKey(row.Id))
                    Transitions.Insert(view, Theme.Motion.ChildTransition(row.ChildIndex));
            }
            treeSignature = signature;
        }
        lastFilter = state.FilesTool.Filter;

        foreach (var (id, (row, model, chevron)) in shownRows)
        {
            bool isCursor = cursor == id;
            bool isOpened = opened == id;
            row.Background = isOpened ? Theme.Brushes.TreeOpened : isCursor ? Theme.Brushes.RowCursor : System.Windows.Media.Brushes.Transparent;
            row.BorderBrush = isCursor && isOpened ? Theme.Brushes.Hairline : null;
            if (chevron is not null) ChevronTurn.Set(chevron, model.IsOpen);
        }
        if (cursor is not null && shownRows.TryGetValue(cursor, out var at))
            Dispatcher.BeginInvoke(() => at.Row.BringIntoView(), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private void SetTreeHost(UIElement content)
    {
        if (!ReferenceEquals(treeHost.Content, content)) treeHost.Content = content;
    }

    /// One tree row: indent, chevron for folders, the name in mono, and a ±badge for changed files.
    private static Border TreeRowView(TreeRow row, FileChangeCount? count, out RowChevron? chevron, bool wasOpen)
    {
        var grid = new Grid();
        // The indent, then `spaceS`: SwiftUI spaces even a zero-width indent from the chevron.
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(row.Depth * Theme.Size.TreeIndent + Theme.Size.SpaceS) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.TreeChevronWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        chevron = null;
        if (row.Node.IsDirectory)
        {
            chevron = new RowChevron(wasOpen, width: null, color: Theme.Brushes.TreeChevron, size: Theme.Fonts.TreeChevron.Size, animated: false);
            Grid.SetColumn(chevron, 1);
            grid.Children.Add(chevron);
        }
        var name = new TextLine(row.Node.Name, Theme.Fonts.MonoCaption, row.Node.IsDirectory ? Theme.Brushes.TreeFolder : Theme.Brushes.TreeFile, Truncation.Middle)
        {
            // SwiftUI: spacing, then `Spacer(minLength: spaceS)`, then spacing before a badge.
            Margin = new Thickness(Theme.Size.SpaceS, 0, (count is null ? 2 : 3) * Theme.Size.SpaceS, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Grid.SetColumn(name, 2);
        grid.Children.Add(name);
        if (count is { } c)
        {
            var badge = ChangeBadge(c);
            Grid.SetColumn(badge, 3);
            grid.Children.Add(badge);
        }
        return new Border
        {
            Child = grid,
            Padding = new Thickness(Theme.Size.TreeRowHPadding, 0, Theme.Size.TreeRowHPadding, 0),
            Height = Theme.Size.TreeRowHeight,
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            BorderThickness = new Thickness(Theme.Size.Hairline),
            Background = System.Windows.Media.Brushes.Transparent,
        };
    }

    /// "+12 −3" in small mono inside a capsule.
    private static FrameworkElement ChangeBadge(FileChangeCount count)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        void Add(string text, System.Windows.Media.Brush brush)
        {
            var t = Ui.Text(text, Theme.Fonts.Badge, brush).Fixed();
            if (row.Children.Count > 0) t.Margin = new Thickness(Theme.Size.SpaceXS, 0, 0, 0);
            row.Children.Add(t);
        }
        if (count.Added > 0) Add(Format.Added(count.Added), Theme.Brushes.Green);
        if (count.Removed > 0) Add(Format.Removed(count.Removed), Theme.Brushes.Red);
        if (count.Added == 0 && count.Removed == 0) Add(Format.Added(0), Theme.Brushes.InkTertiary);
        return Boxes.CapsuleTag(row, Theme.Brushes.BadgeFill, Theme.Size.BadgeHPadding, Theme.Size.BadgeHeight);
    }

    // MARK: Preview

    /// The right column: a header row (the collapse pill, then the file's name, the Markdown
    /// switch and its ±counts), and below it the file. Both crossfade 0.2 s from file to file.
    private void RebuildPreview()
    {
        var path = state!.OpenedFilePath;
        var loaded = path is null ? null : state.OpenedPreview;
        bool code = state.MarkdownShowsCode;
        var marks = path is null ? null : state.ChangeMarksFor(path);
        var counts = state.SessionChangeCounts;
        FileChangeCount? count = path is not null && counts.TryGetValue(path, out var c) ? c : null;

        // The header: always rebuilt (cheap), so the pill and the switch follow the state.
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new TreeTogglePill(state.FilesTreeCollapsed, path is not null, state.ToggleFilesTree));
        if (path is not null)
        {
            var info = PreviewHeader(path, count, code);
            info.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
            Grid.SetColumn(info, 1);
            header.Children.Add(info);
            if (path != shownPath && IsLoaded) Transitions.FadeIn(info);
        }
        previewHeader.Content = header;

        // The body: rebuilt only when what it shows changed, so its scroll position stays put.
        object identity = (object?)loaded ?? (object?)path ?? "none";
        string marksKey = marks is null ? "" : string.Join(",", marks.Added.Order()) + "|" + string.Join(",", marks.RemovedAt.Order());
        if (ReferenceEquals(identity, shownPreview) && code == shownCode && path == shownPath && marksKey == shownMarks) return;
        bool pathChanged = path != shownPath;
        // The same file, reread or with new tints after a turn: the lines redraw in place, the
        // scroll kept and no crossfade (SwiftUI keeps the view, its identity is the path).
        if (!pathChanged && code == shownCode && loaded is not null && previewBody.Content is CodeLinesView open
            && !(AppState.IsMarkdown(path!) && !code) && !loaded.Preview.IsBinary && loaded.Preview.Lines.Count > 0)
        {
            open.Update(PreviewRows(loaded.Preview.Lines, marks ?? new ChangeMarks()), PreviewFooter(loaded));
            shownPreview = identity;
            shownMarks = marksKey;
            return;
        }
        // Only the tints moved, and nothing on screen shows them (rendered Markdown, a note).
        if (!pathChanged && code == shownCode && ReferenceEquals(identity, shownPreview))
        {
            shownMarks = marksKey;
            return;
        }
        shownPreview = identity;
        shownCode = code;
        shownPath = path;
        shownMarks = marksKey;

        UIElement body;
        if (path is null) body = new EmptyNote("Select a file");
        else if (loaded is null) body = new EmptyNote(Theme.Glyphs.Ellipsis);
        else body = PreviewBody(loaded, marks ?? new ChangeMarks(), AppState.IsMarkdown(path) && !code);
        previewBody.Content = body;
        if (IsLoaded && body is FrameworkElement fe && (pathChanged || loaded is not null))
        {
            Transitions.Snap(fe, OpacityProperty, 0);
            Transitions.Animate(fe, OpacityProperty, Theme.Motion.PreviewFade, 1);
        }
    }

    /// "FilesTab.cs   Preview · Code  P   +12 −3". The switch shows only for Markdown files.
    private FrameworkElement PreviewHeader(string path, FileChangeCount? count, bool showsCode)
    {
        var dock = new DockPanel { LastChildFill = true };
        if (count is { } c)
        {
            var counts = new DiffCounts(c.Added, c.Removed) { Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0) };
            DockPanel.SetDock(counts, Dock.Right);
            dock.Children.Add(counts);
        }
        if (AppState.IsMarkdown(path))
        {
            var pills = new SegmentedPills<bool>(showsCode, [(false, "Preview"), (true, "Code")], value => state!.MarkdownShowsCode = value);
            var mode = new HStack(Theme.Size.SpaceS, pills, new InlineKeycap(Theme.Keys.MarkdownMode));
            mode.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
            DockPanel.SetDock(mode, Dock.Right);
            dock.Children.Add(mode);
        }
        var label = new PathLabel(path) { HorizontalAlignment = HorizontalAlignment.Left };
        dock.Children.Add(label);
        return dock;
    }

    private static UIElement PreviewBody(LoadedPreview loaded, ChangeMarks marks, bool rendersMarkdown)
    {
        if (loaded.Preview.IsBinary) return new EmptyNote("Binary file");
        if (loaded.Preview.Lines.Count == 0) return new EmptyNote(loaded.Preview.Truncated ? "Too large to preview" : "Empty file");
        string? footer = PreviewFooter(loaded);
        if (rendersMarkdown)
        {
            var view = new MarkdownView { Footer = footer };
            view.Lines = loaded.Preview.Lines;
            return view;
        }
        return PreviewLines(loaded.Preview.Lines, marks, footer);
    }

    /// "… 212 more lines" when RepoFiles capped the file.
    private static string? PreviewFooter(LoadedPreview loaded)
        => loaded.Preview.Truncated ? Format.MoreLines(loaded.TotalLines - loaded.Preview.Lines.Count) : null;

    /// The file's lines, scrollable both ways, never wrapped. Opens scrolled to the first change.
    private static UIElement PreviewLines(IReadOnlyList<string> lines, ChangeMarks marks, string? footer)
    {
        var view = new CodeLinesView(PreviewRows(lines, marks), Theme.Size.PreviewNumberWidth, Theme.Size.PreviewLineHeight, footer);
        if (marks.FirstLine is int first && first > 1) view.ScrollToLine(first);
        return view;
    }

    /// Each line with its number, the green tint where this session added it and the red mark
    /// where it removed lines.
    private static List<CodeLine> PreviewRows(IReadOnlyList<string> lines, ChangeMarks marks)
    {
        var rows = new List<CodeLine>(lines.Count);
        for (int i = 0; i < lines.Count; i++)
        {
            int number = i + 1;
            bool added = marks.Added.Contains(number);
            bool removedHere = marks.RemovedAt.Contains(number);
            rows.Add(new CodeLine(
                [number],
                lines[i],
                added ? Theme.Brushes.Ink : Theme.Brushes.PreviewText,
                added ? Theme.Brushes.PreviewAddedNumber : removedHere ? Theme.Brushes.PreviewRemovedMark : Theme.Brushes.PreviewLineNumber,
                added ? Theme.Brushes.PreviewAddedBackground : null,
                removedHere));
        }
        return rows;
    }
}
