// GitBranchPicker.cs
// Port of Sources/notchcode/Features/Git/GitBranchPicker.swift.
// The Git tool's branch picker (W): the repository pill and its dropdown (R), the filter,
// and one row per local branch saying where it lives.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Git;

// MARK: - Branch picker

/// The branch picker: the repository pill with its folder and the branch count, the filter
/// past eight branches, one row per local branch. The repository dropdown hangs under the
/// pill over the rows. Closed, it stays in the tree with nothing in it, so its parts can
/// transition.
public sealed class GitBranchPicker : Grid
{
    private readonly ColumnStack column = new() { Spacing = Theme.Size.SpaceM };
    private readonly Grid header = new() { Height = Theme.Size.GitHeaderHeight };
    private readonly Grid filterHost = new();
    private readonly ScrollViewer rowsScroll = ScrollExtras.Make(horizontal: false);
    private readonly StackPanel rowsStack = new();
    private readonly Grid noteHost = new();
    private readonly Grid menuHost = new();
    private FormField? filterField;
    private readonly RowStack filterTrail = new() { Spacing = Theme.Size.SpaceS };
    private string? headerKey, rowsKey, menuKey, filterKey;
    private bool? openBefore;
    private AppState? state;
    private bool updating;

    /// The repository pill on show, which takes the target pill's frame (GitTab morphs them).
    public FrameworkElement? RepoPill { get; private set; }

    public GitBranchPicker()
    {
        column.Children.Add(header);
        column.Children.Add(filterHost);
        rowsScroll.Content = rowsStack;
        column.Children.Add(Kit.Flex(rowsScroll));
        Children.Add(column);
        Children.Add(noteHost);
        Children.Add(menuHost);
    }

    public void Update(AppState state, bool open)
    {
        this.state = state;
        updating = true;
        try { Apply(state, open); }
        finally { updating = false; }
    }

    private void Apply(AppState state, bool open)
    {
        var group = state.GitPickerGroup;
        bool first = openBefore is null;
        bool opening = open && openBefore != true;
        bool closing = !open && openBefore == true;
        openBefore = open;
        IsHitTestVisible = open;

        if (closing)
        {
            // Closing: the rows fade, the header slides back, then all goes.
            foreach (var part in new FrameworkElement[] { header, filterHost, rowsScroll, noteHost, menuHost })
            {
                var p = part;
                if (first) { p.Visibility = Visibility.Hidden; continue; }
                Transitions.Remove(p, Theme.Motion.PickerRowsTransition, () => { if (openBefore == false) p.Visibility = Visibility.Hidden; });
            }
            headerKey = rowsKey = menuKey = filterKey = null;
            return;
        }
        if (!open)
        {
            foreach (var part in new FrameworkElement[] { header, filterHost, rowsScroll, noteHost, menuHost }) part.Visibility = Visibility.Hidden;
            return;
        }
        foreach (var part in new FrameworkElement[] { header, filterHost, rowsScroll, noteHost, menuHost }) part.Visibility = Visibility.Visible;

        // "No git repository in any session" or "Reading branches…".
        noteHost.Children.Clear();
        if (group is null)
        {
            noteHost.Children.Add(new EmptyNote(state.GitPanel.Listing ? "Reading branches" + Theme.Glyphs.Ellipsis : "No git repository in any session"));
            if (opening) Transitions.Insert(noteHost, Theme.Motion.PickerHeadTransition);
        }

        Header(state, group, opening);
        Filter(state, group, opening);
        Rows(state, group, opening);
        Menu(state, group);
    }

    /// "notchcode ▾ R   ~\Desktop\notchcode                    8 branches". The pill takes the
    /// target pill's place as it arrives; the rest rises in after it.
    private void Header(AppState state, GitRepoGroup? group, bool opening)
    {
        bool multiple = state.GitPanel.Repos.Count > 1;
        var key = group is null ? "" : group.Id + "|" + group.Name + "|" + group.Branches.Count + "|" + multiple + "|" + state.GitPanel.RepoMenuOpen;
        if (key == headerKey && !opening) return;
        headerKey = key;
        header.Children.Clear();
        RepoPill = null;
        if (group is null) return;
        var pill = new GitRepoPill(group.Name, multiple, state.GitPanel.RepoMenuOpen, state.OpenGitRepoMenu);
        RepoPill = pill;
        var path = new TrimText(Abbreviated(group.Id), Theme.Fonts.MonoSmall, Theme.Brushes.GitPickerPath, TrimMode.Middle)
        {
            MaxWidth = Theme.Size.GitPickerPathMaxWidth,
            ToolTip = group.Id,
        };
        var count = Kit.Text(group.Branches.Count == 1 ? "1 branch" : $"{group.Branches.Count} branches", Theme.Fonts.Caption, Theme.Brushes.GroupHeaderCount, TextTrimming.None);
        var rest = new RowStack(Theme.Size.SpaceM, path, Kit.Spacer(Theme.Size.SpaceM), count);
        var row = new RowStack(Theme.Size.SpaceM, pill, Kit.Flex(rest))
        {
            Margin = new Thickness(Theme.Size.RowHPadding, 0, Theme.Size.RowHPadding, 0),
        };
        header.Children.Add(row);
        if (opening)
        {
            Transitions.Insert(pill, TransitionSpec.Opacity(Theme.Motion.PickerPill, Theme.Motion.PickerPill));
            Transitions.Insert(rest, Theme.Motion.PickerHeadTransition);
        }
    }

    /// "~\Desktop\notchcode": the home folder as "~".
    public static string Abbreviated(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var normal = path.Replace('/', '\\');
        if (home.Length > 0 && normal.StartsWith(home, StringComparison.OrdinalIgnoreCase)
            && (normal.Length == home.Length || normal[home.Length] == '\\'))
            return "~" + normal[home.Length..];
        return normal;
    }

    /// The Files tree's filter field: "/ design     3 of 10  esc clears".
    private void Filter(AppState state, GitRepoGroup? group, bool opening)
    {
        bool shows = group is not null && state.GitPickerShowsFilter;
        if (!shows)
        {
            filterHost.Visibility = Visibility.Collapsed;
            filterKey = null;
            return;
        }
        filterHost.Visibility = Visibility.Visible;
        if (filterField is null)
        {
            filterField = new FormField(Theme.Fonts.MonoCaption) { Prompt = "Filter branches" };
            filterField.Box.TextChanged += (_, _) => { if (!updating) this.state?.SetGitFilter(filterField.Box.Text); };
            filterField.Box.GotKeyboardFocus += (_, _) => { if (!updating && this.state?.GitPanel.FilterFocused == false) this.state.SetGitFilterFocused(true); };
            filterField.Box.LostKeyboardFocus += (_, _) => { if (!updating && this.state?.GitPanel.FilterFocused == true) this.state.SetGitFilterFocused(false); };
            filterField.Box.PreviewKeyDown += (_, e) =>
            {
                if (this.state is null) return;
                // The picker keeps ↑↓ ⏎ esc while the filter has the keys.
                if (e.Key == Key.Escape) { this.state.GitEscape(); e.Handled = true; }
                else if (e.Key is Key.Up or Key.Down) { this.state.HandleGitKey(e.Key == Key.Up ? NotchKey.Up : NotchKey.Down); e.Handled = true; }
                else if (e.Key == Key.Return) { this.state.HandleGitKey(NotchKey.Primary); e.Handled = true; }
            };
            // One box for the picker's life, so typing keeps the keys; only its trailing words change.
            var box = new Border
            {
                Child = new RowStack(Theme.Size.SpaceS, Theme.Symbols.Filter.ToPath(Theme.Size.TinySymbol, Theme.Brushes.FilterPlaceholder),
                    Kit.Flex(filterField), filterTrail),
                Padding = new Thickness(Theme.Size.FilterHPadding, 0, Theme.Size.FilterHPadding, 0),
                Height = Theme.Size.FilterHeight,
                CornerRadius = new CornerRadius(Theme.Radius.Chip),
                Background = Theme.Brushes.FilterFill,
            };
            filterHost.Children.Add(box);
        }
        if (opening || filterKey is null) Transitions.Insert(filterHost, Theme.Motion.PickerHeadTransition);
        filterField.SetText(state.GitPanel.Filter);
        var filter = state.GitPanel.Filter;
        var key = filter + "|" + state.GitPickerRows.Count + "|" + group!.Branches.Count + "|" + state.GitPanel.FilterFocused;
        if (key != filterKey)
        {
            filterKey = key;
            filterTrail.Children.Clear();
            if (filter.Length > 0)
            {
                filterTrail.Children.Add(Kit.Text($"{state.GitPickerRows.Count} of {group.Branches.Count}", Theme.Fonts.Caption, Theme.Brushes.FilterPlaceholder, TextTrimming.None));
                filterTrail.Children.Add(new InlineKeycap(Theme.Keys.Escape));
                filterTrail.Children.Add(Kit.Text("clears", Theme.Fonts.Caption, Theme.Brushes.FilterPlaceholder, TextTrimming.None));
            }
            else if (!state.GitPanel.FilterFocused)
            {
                filterTrail.Children.Add(new InlineKeycap(Theme.Keys.Slash));
            }
        }
        if (state.GitPanel.FilterFocused && !filterField.Box.IsKeyboardFocused)
            Dispatcher.BeginInvoke(() => filterField?.Box.Focus());
    }

    private void Rows(AppState state, GitRepoGroup? group, bool opening)
    {
        if (group is null) { rowsStack.Children.Clear(); rowsKey = null; return; }
        var rows = state.GitPickerRows;
        int cursor = state.GitPanel.PickerCursor;
        var cursorName = cursor >= 0 && cursor < rows.Count ? rows[cursor].Name : null;
        var filter = state.GitPanel.Filter;
        int hidden = group.Branches.Count - rows.Count;
        var key = string.Join("\u001f", rows.Select(b => b.Name + b.Uncommitted + b.Ahead + b.Place + state.GitBranchIsCurrent(b, group.Id)))
                  + "|" + cursorName + "|" + filter + "|" + hidden;
        if (key == rowsKey && !opening) return;
        rowsKey = key;
        rowsStack.Children.Clear();
        FrameworkElement? cursorRow = null;
        for (int index = 0; index < rows.Count; index++)
        {
            var branch = rows[index];
            var row = new GitBranchRow(branch, group.DefaultBranch, filter,
                hasSession: branch.Path is { } p && state.GitSessions(p).Count > 0,
                isCurrent: state.GitBranchIsCurrent(branch, group.Id),
                isCursor: branch.Name == cursorName)
            {
                Margin = new Thickness(0, index == 0 ? 0 : Theme.Size.SpaceXS, 0, 0),
            };
            var b = branch;
            Kit.OnClick(row, () => this.state?.PickGitBranch(b));
            rowsStack.Children.Add(row);
            // Not lazy: every row appears (and rises) with the picker, not later as it scrolls in.
            if (opening) Transitions.RiseIn(row, index, Theme.Motion.RowStaggerCap);
            if (branch.Name == cursorName) cursorRow = row;
        }
        if (filter.Length > 0 && hidden > 0)
        {
            var note = Kit.Text(rows.Count == 0 ? "No branch matches"
                : hidden == 1 ? "1 branch hidden by the filter" : $"{hidden} branches hidden by the filter",
                Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
            note.Margin = new Thickness(Theme.Size.GitBranchRowHPadding, Theme.Size.RowVPadding, Theme.Size.GitBranchRowHPadding, Theme.Size.RowVPadding);
            note.HorizontalAlignment = HorizontalAlignment.Left;
            rowsStack.Children.Add(note);
        }
        if (cursorRow is not null)
            Dispatcher.BeginInvoke(() => cursorRow.BringIntoView(), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// The repository dropdown hangs under the pill over the rows; a click outside closes it.
    private void Menu(AppState state, GitRepoGroup? group)
    {
        bool open = state.GitPanel.RepoMenuOpen && group is not null;
        var key = open ? group!.Id + "|" + state.GitPanel.RepoMenuCursor + "|" + state.GitPanel.Repos.Count : "";
        if (key == menuKey) return;
        bool wasOpen = !string.IsNullOrEmpty(menuKey);
        menuKey = key;
        menuHost.Children.Clear();
        if (!open) return;
        var shade = new Border { Background = Kit.HitFill };
        shade.MouseLeftButtonDown += (_, e) => { this.state?.CloseGitRepoMenu(); e.Handled = true; };
        menuHost.Children.Add(shade);
        var menu = new GitRepoMenu(state, group!.Id)
        {
            Margin = new Thickness(0, Theme.Size.GitHeaderHeight + Theme.Size.SpaceS, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
        };
        menuHost.Children.Add(menu);
        if (!wasOpen) Transitions.Insert(menu, TransitionSpec.Opacity(Theme.Motion.Tap, Theme.Motion.Tap));
    }
}

/// "notchcode ▾  R": the repository the picker lists. With more than one it opens the
/// dropdown; with one it is a static label.
public sealed class GitRepoPill : Border
{
    public GitRepoPill(string name, bool multiple, bool open, Action action)
    {
        var label = new RowStack(Theme.Size.ActionKeyGap, Kit.Text(name, Theme.Fonts.Action, Theme.Brushes.GitTargetPlace, TextTrimming.None))
        {
            Margin = new Thickness(Theme.Size.ActionHPadding, 0, Theme.Size.ActionHPadding, 0),
            Height = Theme.Size.ActionHeight,
        };
        if (multiple)
        {
            label.Children.Add(Kit.Text(Theme.Glyphs.PickerChevron, Theme.Fonts.Tiny, Theme.Brushes.GitTargetRepo, TextTrimming.None));
            label.Children.Add(new InlineKeycap(Theme.Keys.Repository));
            Child = new SegmentButton(label, open ? Theme.Brushes.PickerSelected : Theme.Brushes.NeutralActionFill, click: action)
            {
                ToolTip = $"Choose the repository ({Theme.Keys.Repository})",
                HorizontalAlignment = HorizontalAlignment.Left,
            };
        }
        else
        {
            Child = new Border { Child = label, Background = Theme.Brushes.NeutralActionFill, CornerRadius = new CornerRadius(Theme.Radius.Segment) };
        }
        VerticalAlignment = VerticalAlignment.Center;
    }
}

/// The repository dropdown: one row per repository (name, folder, branch count) drawn over
/// the rows in the well, in the inset style. ↑↓ and ⏎ pick, esc or R closes it.
public sealed class GitRepoMenu : Grid
{
    public GitRepoMenu(AppState state, string current)
    {
        Width = Theme.Size.GitRepoMenuWidth;
        var radius = new CornerRadius(Theme.Radius.Snippet);
        // The well's colour flattened, the inset on top, a hairline edge.
        Children.Add(new Border { Background = Theme.Brushes.GitRepoMenuBase, CornerRadius = radius });
        var stack = new StackPanel();
        var repos = state.GitPanel.Repos;
        for (int i = 0; i < repos.Count; i++)
        {
            var repo = repos[i];
            var row = new RowStack(Theme.Size.SpaceM,
                Kit.Text(repo.Name, Theme.Fonts.CaptionSemibold, repo.Id == current ? Theme.Brushes.GitRepoMenuName : Theme.Brushes.GitRepoMenuOther, TextTrimming.None),
                Kit.Flex(new TrimText(GitBranchPicker.Abbreviated(repo.Id), Theme.Fonts.MonoSmall, Theme.Brushes.GitPickerPath, TrimMode.Middle)));
            if (repo.Id == current) row.Children.Add(new SmallTag("current"));
            row.Children.Add(Kit.Text(repo.Branches.Count.ToString(), Theme.Fonts.Caption, Theme.Brushes.GroupHeaderCount, TextTrimming.None));
            var box = new Border
            {
                Child = row,
                Padding = new Thickness(Theme.Size.RowHPadding, 0, Theme.Size.RowHPadding, 0),
                Height = Theme.Size.GitRepoMenuRowHeight,
                CornerRadius = new CornerRadius(Theme.Radius.Chip),
                Background = i == state.GitPanel.RepoMenuCursor ? Theme.Brushes.RowCursor : Kit.HitFill,
                ToolTip = repo.Id,
            };
            var id = repo.Id;
            Kit.OnClick(box, () => state.ChooseGitRepo(id));
            stack.Children.Add(box);
        }
        Children.Add(new Border
        {
            Child = stack,
            Padding = new Thickness(Theme.Size.GitRepoMenuPadding),
            Background = Theme.Brushes.GitRepoMenuFill,
            BorderBrush = Theme.Brushes.GitRepoMenuStroke,
            BorderThickness = new Thickness(Theme.Size.Hairline),
            CornerRadius = radius,
        });
    }
}

/// One local branch: "design/toolbar" in mono, "not checked out" under it (or "worktree
/// seadevil" with its glyph, or "main checkout"), the session and current tags, then the
/// counts on the right: "33 uncommitted", "clean", "↑3", "↑2 of main".
public sealed class GitBranchRow : Border
{
    public GitBranchRow(GitBranch branch, string? defaultBranch, string match, bool hasSession, bool isCurrent, bool isCursor)
    {
        var counts = Counts(branch, defaultBranch);
        // The name, the filter's match lit.
        var name = new TrimText(branch.Name, Theme.Fonts.Mono, Theme.Brushes.GitPickerBranch, TrimMode.Middle);
        var query = match.Trim(' ', '\t');
        if (query.Length > 0)
        {
            int at = branch.Name.IndexOf(query, StringComparison.CurrentCultureIgnoreCase);
            if (at >= 0) name.Highlight(at, query.Length, Theme.Brushes.GitFilterMatch);
        }
        var placeBrush = branch.Place is GitPlace.Nowhere ? Theme.Brushes.GitPickerNowhere : Theme.Brushes.GitPickerPlace;
        var place = new RowStack { Spacing = Theme.Size.SpaceS };
        if (branch.Place is GitPlace.Worktree) place.Children.Add(Theme.Symbols.GitWorktree.ToPath(Theme.Size.GitPlaceGlyph, placeBrush));
        place.Children.Add(Kit.Text(Place(branch), Theme.Fonts.Caption, placeBrush));
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(name);
        place.Margin = new Thickness(0, Theme.Size.GitBranchLineGap, 0, 0);
        lines.Children.Add(place);
        RowStack.SetPriority(lines, 1);
        var row = new RowStack(Theme.Size.SpaceM, lines);
        if (hasSession) row.Children.Add(new SmallTag("session"));
        if (isCurrent) row.Children.Add(new SmallTag("current"));
        row.Children.Add(Kit.Spacer(Theme.Size.SpaceM));
        row.Children.Add(Kit.Text(counts.Text, Theme.Fonts.Caption, counts.Quiet ? Theme.Brushes.GitPickerClean : Theme.Brushes.GitPickerCount, TextTrimming.None));
        Child = row;
        Padding = new Thickness(Theme.Size.GitBranchRowHPadding, 0, Theme.Size.GitBranchRowHPadding, 0);
        Height = Theme.Size.GitBranchRowHeight;
        CornerRadius = new CornerRadius(Theme.Radius.Row);
        Background = isCursor ? Theme.Brushes.RowCursor : Kit.HitFill;
        BorderBrush = isCursor ? Theme.Brushes.GitPickerCursorStroke : null;
        BorderThickness = new Thickness(isCursor ? Theme.Size.Hairline : 0);
        ToolTip = branch.Path ?? branch.Name;
        Cursor = Cursors.Hand;
    }

    private static string Place(GitBranch branch) => branch.Place switch
    {
        GitPlace.Main => "main checkout",
        GitPlace.Worktree w => "worktree " + Path.GetFileName(w.Path.TrimEnd('/', '\\')),
        _ => "not checked out",
    };

    /// "33 uncommitted · ↑2", "clean", "↑3", "↑2 of main", "in main". Quiet (tertiary) when
    /// nothing is uncommitted or ahead.
    public static (string Text, bool Quiet) Counts(GitBranch branch, string? defaultBranch)
    {
        var parts = new List<string>();
        if (branch.Uncommitted is { } n) parts.Add(n == 0 ? "clean" : $"{n} uncommitted");
        int ahead = branch.Ahead ?? 0;
        if (ahead > 0)
        {
            var of = branch.Upstream is null ? " of " + (defaultBranch ?? "main") : "";
            parts.Add(Theme.Glyphs.Ahead + ahead + of);
        }
        else if (branch.Place is GitPlace.Nowhere && branch.Ahead is not null)
        {
            parts.Add(branch.Upstream is null ? "in " + (defaultBranch ?? "main") : "up to date");
        }
        bool quiet = (branch.Uncommitted ?? 0) == 0 && ahead == 0;
        return (string.Join(Theme.Glyphs.Separator, parts), quiet);
    }
}
