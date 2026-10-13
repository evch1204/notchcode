// ChangesTimeline.cs
// Port of Sources/notchcode/Features/Changes/ChangesTimeline.swift.
// The Changes tool's timeline column. A 1 pt spine at x 10 from the first node down; on it an
// 8 pt node per turn that changed files (ink), the live turn's node in clay with a breathing
// 14 pt halo, a 6 × 1 pt tick per quiet turn and three stacked ticks per quiet group. Titles
// start at 26 pt.
//
// An entry: the prompt in body semibold (two lines at most, cut with a fade, not an
// ellipsis), its clock time at the right of the first line (and its duration when the column
// is wide; on hover when narrow), then its files as 20 pt chips wrapping in rows: the agent
// square when a subagent made the change, the name (mono, middle-truncated, 120 pt at most),
// the five cells and the counts. The live turn: "Working 4:12" in clay instead of the time,
// and "no edits yet" until its first chip pops in. A quiet group: "4 quiet turns · questions
// and decisions" and a chevron; ⏎ or a click unfolds one 20 pt row per turn under it.
// Entries are 12 pt apart; blocks rise in, the rest sliding to make room. The keyboard
// cursor is one mark that glides from stop to stop: a ring on a chip, a row's fill elsewhere.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;
using Ellipse = System.Windows.Shapes.Ellipse;

using Notchcode.Features.StandIns;
using Notchcode.UI.Diff;


namespace Notchcode.Features.Changes;

public sealed class ChangesTimeline : Grid
{
    private readonly AppState state;
    private readonly ScrollViewer scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    private readonly Grid content = new() { VerticalAlignment = VerticalAlignment.Top };
    private readonly StackPanel blocksPanel = new();
    private readonly Border spine = new()
    {
        Background = Theme.Brushes.ChangesSpine,
        Width = Theme.Size.ChangesRing,
        HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Stretch,
        Margin = new Thickness(Theme.Size.ChangesSpineX - Theme.Size.ChangesRing / 2, Theme.Size.ChangesRowHeight / 2, 0, 0),
    };
    private readonly Canvas cursorLayer = new() { IsHitTestVisible = false };
    private readonly Border cursorMark = new() { CornerRadius = new CornerRadius(Theme.Radius.Chip), Visibility = Visibility.Collapsed };
    private readonly SolidColorBrush cursorFill = PaneTint.Live(Colors.Transparent);
    private readonly SolidColorBrush cursorRing = PaneTint.Live(Colors.Transparent);
    private bool cursorPlaced;

    /// Cursor stop id -> the element the cursor marks (a chip, a row).
    private readonly Dictionary<string, FrameworkElement> targets = [];
    /// Block ids and chip ids on screen after the last build: anything new rises or pops in.
    private HashSet<string> shownBlocks = [];
    private HashSet<string> shownChips = [];
    private HashSet<string> shownQuietRows = [];
    private HashSet<string> unfoldedBefore = [];
    /// The entries that were live, and the block ids plus unfolded groups, after the last build.
    private HashSet<string> liveBefore = [];
    private string shownLayoutKey = "";
    /// The views of the last build: each block, and each unfolded quiet row.
    private readonly Dictionary<string, FrameworkElement> blockViews = [];
    private readonly Dictionary<string, FrameworkElement> quietRowViews = [];
    /// Blocks and rows on their way out, drawn where they were while they drop and fade.
    private readonly Canvas ghostLayer = new() { IsHitTestVisible = false };
    private bool built;
    private double width;

    public ChangesTimeline(AppState state)
    {
        this.state = state;
        cursorMark.Background = cursorFill;
        cursorMark.BorderBrush = cursorRing;
        cursorMark.BorderThickness = new Thickness(Theme.Size.ChangesRing);
        cursorLayer.Children.Add(cursorMark);
        content.Children.Add(spine);
        content.Children.Add(blocksPanel);
        content.Children.Add(ghostLayer);
        content.Children.Add(cursorLayer);
        scroll.Content = content;
        Children.Add(scroll);
    }

    /// The column's width: the duration and the quiet groups' tail show past `ChangesWideColumn`.
    public double ColumnWidth
    {
        get => width;
        set
        {
            if (Math.Abs(width - value) < 0.5) return;
            bool wasWide = width >= Theme.Size.ChangesWideColumn;
            width = value;
            Width = value;
            // Text re-wraps at once when the width changes; only the column's edge springs.
            if (built && wasWide != value >= Theme.Size.ChangesWideColumn) Rebuild();
            else Dispatcher.BeginInvoke(() => MoveCursor(false), System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }

    public void Rebuild()
    {
        var blocks = state.ChangesBlocks;
        bool wide = width >= Theme.Size.ChangesWideColumn;
        var selection = state.ChangesPaneShown ? state.ChangesTool.Selection : null;
        // Where every block and unfolded quiet row sits now, so the ones that leave can drop out from there.
        var leaving = new List<(string Id, FrameworkElement View, Point At, double Width, bool QuietRow)>();
        if (built)
        {
            foreach (var (id, view) in blockViews)
                if (view.IsArrangeValid && content.IsAncestorOf(view))
                    leaving.Add((id, view, view.TranslatePoint(new Point(0, 0), content), view.ActualWidth, false));
            foreach (var (id, view) in quietRowViews)
                if (view.IsArrangeValid && content.IsAncestorOf(view))
                    leaving.Add((id, view, view.TranslatePoint(new Point(0, 0), content), view.ActualWidth, true));
        }
        blockViews.Clear();
        quietRowViews.Clear();
        blocksPanel.Children.Clear();
        targets.Clear();
        var blockIds = new HashSet<string>();
        var chipIds = new HashSet<string>();
        var quietIds = new HashSet<string>();
        int quietIndex = 0;
        foreach (var block in blocks)
        {
            FrameworkElement view = block switch
            {
                ChangesBlock.Entry entry => Entry(entry, wide, selection, chipIds),
                ChangesBlock.Quiet quiet => QuietGroup(quiet, wide, quietIds),
                _ => new Border(),
            };
            view.Margin = new Thickness(0, blocksPanel.Children.Count == 0 ? 0 : Theme.Size.ChangesEntryGap, 0, 0);
            blocksPanel.Children.Add(view);
            blockViews[block.Id] = view;
            blockIds.Add(block.Id);
            // Quiet groups come back one after another (the `/` filter); entries at once.
            if (built && !shownBlocks.Contains(block.Id))
                Transitions.Insert(view, Theme.Motion.ChangesRowTransition(block is ChangesBlock.Quiet ? quietIndex : 0));
            if (block is ChangesBlock.Quiet) quietIndex++;
        }
        // What left (a quiet group under With edits, a folded group's rows) drops 6 pt and fades
        // where it was, 40 ms apart, over the new layout.
        int gone = 0;
        foreach (var (id, view, at, w, quietRow) in leaving)
        {
            bool stays = quietRow ? quietIds.Contains(id) : blockIds.Contains(id);
            if (stays) continue;
            if (!quietRow && id.StartsWith("e|", StringComparison.Ordinal)) continue; // entries leave at once
            if (view.Parent is Panel parent) parent.Children.Remove(view);
            view.Margin = new Thickness(0);
            view.Width = w;
            Canvas.SetLeft(view, at.X);
            Canvas.SetTop(view, at.Y);
            ghostLayer.Children.Add(view);
            var ghost = view;
            Transitions.Remove(ghost, Theme.Motion.ChangesRowTransition(gone++), () => ghostLayer.Children.Remove(ghost));
        }
        // The spine runs from the first node's centre to the bottom of the last block.
        spine.Visibility = blocks.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        // Blocks that stayed slide from where they were to where they are on the layout spring
        // (a new turn on top, a group unfolding above them, `/` closing the gaps), as SwiftUI's
        // `.animation(changesLayout, value: blocks.map(\.id))` and `unfoldedGroups` do. A width
        // change re-wraps at once, so it moves nothing.
        var layoutKey = string.Join("\n", blocks.Select(b => b.Id)) + "\n|" + string.Join("\n", state.ChangesTool.UnfoldedGroups.Order());
        if (built && layoutKey != shownLayoutKey && IsLoaded)
        {
            var was = leaving.Where(l => !l.QuietRow).ToDictionary(l => l.Id, l => l.At.Y);
            content.UpdateLayout();
            foreach (var (id, view) in blockViews)
            {
                if (!was.TryGetValue(id, out var oldY) || !view.IsArrangeValid) continue;
                double dy = oldY - view.TranslatePoint(new Point(0, 0), content).Y;
                if (Math.Abs(dy) < 0.5) continue;
                var translate = Transitions.Translate(view);
                Transitions.Snap(translate, TranslateTransform.YProperty, dy);
                Transitions.Animate(translate, TranslateTransform.YProperty, Theme.Motion.ChangesLayout, 0);
            }
        }
        shownLayoutKey = layoutKey;
        shownBlocks = blockIds;
        shownChips = chipIds;
        shownQuietRows = quietIds;
        unfoldedBefore = [.. state.ChangesTool.UnfoldedGroups];
        liveBefore = blocks.OfType<ChangesBlock.Entry>().Where(e => e.Live).Select(e => e.Id).ToHashSet();
        built = true;
        Dispatcher.BeginInvoke(() => MoveCursor(scrollTo: false), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    // MARK: Cursor

    /// The mark glides to the cursor's stop on the Changes layout spring: a ring on a chip, a
    /// row's fill elsewhere (crossfading as it changes). The first placement snaps.
    public void MoveCursor(bool scrollTo)
    {
        var key = state.CursorRowKey;
        if (key is null || !targets.TryGetValue(key, out var target) || !target.IsArrangeValid || !content.IsAncestorOf(target))
        {
            cursorMark.Visibility = Visibility.Collapsed;
            cursorPlaced = false;
            return;
        }
        content.UpdateLayout();
        var at = target.TranslatePoint(new Point(0, 0), content);
        bool onChip = key.StartsWith("c|", StringComparison.Ordinal);
        var hover = Theme.Motion.ChangesHover;
        PaneTint.Tint(cursorFill, onChip ? Colors.Transparent : Theme.Colors.RowCursor, hover);
        PaneTint.Tint(cursorRing, onChip ? Theme.Colors.ChangesChipRing : Colors.Transparent, hover);
        cursorMark.Visibility = Visibility.Visible;
        var spec = Theme.Motion.ChangesLayout;
        if (!cursorPlaced)
        {
            Transitions.Snap(cursorMark, Canvas.LeftProperty, at.X);
            Transitions.Snap(cursorMark, Canvas.TopProperty, at.Y);
            Transitions.Snap(cursorMark, WidthProperty, target.ActualWidth);
            Transitions.Snap(cursorMark, HeightProperty, target.ActualHeight);
            cursorPlaced = true;
        }
        else
        {
            Transitions.Animate(cursorMark, Canvas.LeftProperty, spec, at.X);
            Transitions.Animate(cursorMark, Canvas.TopProperty, spec, at.Y);
            Transitions.Animate(cursorMark, WidthProperty, spec, target.ActualWidth);
            Transitions.Animate(cursorMark, HeightProperty, spec, target.ActualHeight);
        }
        if (scrollTo) target.BringIntoView();
    }

    // MARK: Nodes

    private enum NodeKind { Entry, Live, Tick, Group }

    /// What sits on the spine at a row's centre: a node, the live node with its halo, a tick,
    /// or the quiet group's three ticks. Its frame is twice the spine's x, so it centres on it.
    private static FrameworkElement Node(NodeKind kind)
    {
        var box = new Grid
        {
            Width = 2 * Theme.Size.ChangesSpineX,
            Height = Theme.Size.ChangesRowHeight,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
        };
        switch (kind)
        {
            case NodeKind.Entry:
                box.Children.Add(Circle(Theme.Brushes.ChangesNode, Theme.Size.ChangesNode));
                break;
            case NodeKind.Live:
                box.Children.Add(BreathingHalo());
                box.Children.Add(Circle(Theme.Brushes.ChangesNodeLive, Theme.Size.ChangesNode));
                break;
            case NodeKind.Tick:
                box.Children.Add(Tick());
                break;
            case NodeKind.Group:
                var ticks = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
                for (int i = 0; i < 3; i++)
                {
                    var tick = Tick();
                    tick.Margin = new Thickness(0, i == 0 ? 0 : Theme.Size.ChangesTickGap - Theme.Size.ChangesTickHeight, 0, 0);
                    ticks.Children.Add(tick);
                }
                box.Children.Add(ticks);
                break;
        }
        return box;
    }

    private static Ellipse Circle(Brush fill, double size) => new()
    {
        Fill = fill,
        Width = size,
        Height = size,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static Border Tick() => new()
    {
        Background = Theme.Brushes.ChangesTick,
        Width = Theme.Size.ChangesTickWidth,
        Height = Theme.Size.ChangesTickHeight,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// The live node's halo: out to 1.5× and gone over 1.6 s, again and again. Reduce Motion: still.
    private static FrameworkElement BreathingHalo()
    {
        var halo = Circle(Theme.Brushes.ChangesHalo, Theme.Size.ChangesHalo);
        if (Theme.Motion.ChangesBreath is not MotionSpec breath) return halo;
        var scale = new ScaleTransform(1, 1);
        halo.RenderTransformOrigin = new Point(0.5, 0.5);
        halo.RenderTransform = scale;
        halo.Loaded += (_, _) =>
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, breath.ToTimeline(1, Theme.Size.ChangesHaloScale));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, breath.ToTimeline(1, Theme.Size.ChangesHaloScale));
            halo.BeginAnimation(OpacityProperty, breath.ToTimeline(1, 0));
        };
        return halo;
    }

    // MARK: Entry

    /// A turn that changed files, or the live turn.
    private FrameworkElement Entry(ChangesBlock.Entry entry, bool wide, ChangesChipKey? selection, HashSet<string> chipIds)
    {
        var turn = entry.Turn;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.ChangesTitleInset) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Node(entry.Live ? NodeKind.Live : NodeKind.Entry));
        // The turn just finished (or came back to life): the old node fades out over the new
        // one on the layout spring, and the trailing text crossfades with it.
        bool turned = built && shownBlocks.Contains(entry.Id) && liveBefore.Contains(entry.Id) != entry.Live;
        if (turned)
        {
            var old = Node(entry.Live ? NodeKind.Entry : NodeKind.Live);
            old.IsHitTestVisible = false;
            grid.Children.Add(old);
            Transitions.Animate(old, OpacityProperty, Theme.Motion.ChangesLayout, 0, () => grid.Children.Remove(old));
        }

        var column = new StackPanel();
        Grid.SetColumn(column, 1);
        grid.Children.Add(column);

        var title = new Grid();
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var prompt = new FadeText(turn.Prompt, Theme.Fonts.BodySemibold, Theme.Brushes.Ink, lines: 2)
        {
            Margin = new Thickness(0, Theme.Size.ChangesTitleVPadding, Theme.Size.SpaceM, Theme.Size.ChangesTitleVPadding),
            VerticalAlignment = VerticalAlignment.Top,
        };
        title.Children.Add(prompt);
        var trailing = Trailing(turn, entry.Live, wide);
        Grid.SetColumn(trailing, 1);
        title.Children.Add(trailing);
        if (turned)
        {
            Transitions.Snap(trailing, OpacityProperty, 0);
            Transitions.Animate(trailing, OpacityProperty, Theme.Motion.ChangesLayout, 1);
        }
        column.Children.Add(title);

        if (turn.Files.Count == 0)
        {
            var key = new ChangesItem.Live(turn.Id).Id;
            var none = new Border
            {
                Child = Ui.Text("no edits yet", Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed(),
                Padding = new Thickness(Theme.Size.ChangesChipHPadding, 0, Theme.Size.ChangesChipHPadding, 0),
                Height = Theme.Size.ChangesRowHeight,
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, Theme.Size.ChangesTitleGap, 0, 0),
            };
            targets[key] = none;
            column.Children.Add(none);
        }
        else
        {
            var flow = new ChipFlow { Margin = new Thickness(0, Theme.Size.ChangesTitleGap, 0, 0) };
            bool entryWasShown = shownBlocks.Contains(entry.Id);
            foreach (var file in turn.Files)
            {
                var chipKey = new ChangesChipKey(turn.Id, file.Path);
                var id = ChangesIds.Chip(chipKey);
                int? agentColor = file.AgentId is { } agentId ? AgentColor(agentId) : null;
                var chip = Chip(file, agentColor, selection == chipKey, () => state.SelectChangesChip(chipKey));
                targets[id] = chip;
                chipIds.Add(id);
                flow.Children.Add(chip);
                // A chip landing in a turn already on screen pops in at the end of its row.
                if (built && entryWasShown && !shownChips.Contains(id)) Transitions.Insert(chip, Theme.Motion.ChangesChipTransition);
            }
            column.Children.Add(flow);
        }
        return grid;
    }

    private int AgentColor(string agentId)
    {
        if (state.FocusedSession?.Id is not { } sid) return 0;
        int index = state.AgentsFor(sid).FindIndex(a => a.Id == agentId);
        return Math.Max(0, index);
    }

    /// "14:32  3m 30s" (the duration only when the column is wide, else on hover), or
    /// "Working 4:12" in clay while the turn runs.
    private static HStack Trailing(TranscriptTurn turn, bool live, bool wide)
    {
        HStack row;
        if (live)
        {
            row = new HStack(Theme.Size.SpaceS,
                Ui.Text("Working", Theme.Fonts.CaptionMedium, Theme.Brushes.Clay).Fixed(),
                new ElapsedText(turn.StartedAt, Theme.Brushes.Clay));
        }
        else
        {
            string? duration = turn.EndedAt is DateTime ended ? Format.Duration((ended - turn.StartedAt).TotalSeconds) : null;
            row = new HStack(Theme.Size.SpaceS,
                Ui.Text(Format.TimeOfDay(turn.StartedAt), Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed(),
                wide && duration is not null ? Ui.Text(duration, Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed() : null);
            // Narrow, the duration is on hover (`.help`): the whole slot takes the mouse, not
            // just the glyphs, and the tip shows without the usual wait.
            if (duration is not null)
            {
                row.ToolTip = "took " + duration;
                ToolTipService.SetInitialShowDelay(row, 0);
            }
        }
        row.Background = Theme.Brushes.HitTarget;
        row.Height = Theme.Size.ChangesRowHeight;
        row.VerticalAlignment = VerticalAlignment.Top;
        return row;
    }

    /// "▪ GitTab.swift ▮▮▮▯▯ +53 −19": one file a turn changed. The keyboard cursor rings it; the
    /// selected chip (its diff showing) and the hovered one fill a step brighter.
    private static FrameworkElement Chip(FileChange file, int? agentColor, bool isSelected, Action action)
    {
        var name = new TextLine(Format.FileName(file.Path), Theme.Fonts.MonoCaption, Theme.Brushes.Ink, Truncation.Middle)
        {
            MaxWidth = Theme.Size.ChangesChipMaxWidth,
        };
        var cells = new HStack(Theme.Size.ChangesChipGap, new DiffCells(file.Added, file.Removed), new DiffCounts(file.Added, file.Removed));
        var row = new HStack(Theme.Size.ChangesChipHPadding, agentColor is int color ? new AgentSquare(color) : null, name, cells);
        var rest = isSelected ? Theme.Colors.ChangesChipSelected : Theme.Colors.ChangesChipFill;
        var fill = PaneTint.Live(rest);
        var chip = new Border
        {
            Child = row,
            Padding = new Thickness(Theme.Size.ChangesChipHPadding, 0, Theme.Size.ChangesChipHPadding, 0),
            Height = Theme.Size.ChangesChipHeight,
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            Background = fill,
        };
        chip.MouseEnter += (_, _) => PaneTint.Tint(fill, Theme.Colors.ChangesChipSelected, Theme.Motion.ChangesHover);
        chip.MouseLeave += (_, _) => PaneTint.Tint(fill, rest, Theme.Motion.ChangesHover);
        chip.OnTap(action);

        var help = new List<string> { file.Path };
        if (agentColor is not null) help.Add("edited by an agent");
        if (file.Kind == "shell") help.Add("changed by a shell command, diff against HEAD");
        chip.ToolTip = string.Join(Theme.Glyphs.Separator, help);
        return chip;
    }

    // MARK: Quiet turns

    /// "≡ 4 quiet turns · questions and decisions ▸": a run of turns without files, one row.
    /// Unfolded, one row per turn under it: a tick, the prompt (one line, cut with a fade), the time.
    private FrameworkElement QuietGroup(ChangesBlock.Quiet quiet, bool wide, HashSet<string> quietIds)
    {
        bool unfolded = state.ChangesTool.UnfoldedGroups.Contains(quiet.GroupId);
        var stack = new StackPanel();

        var head = new Grid { Background = Brushes.Transparent };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.ChangesTitleInset) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.Children.Add(Node(NodeKind.Group));
        var label = new DockPanel { LastChildFill = false };
        var chevron = new RowChevron(built ? unfoldedBefore.Contains(quiet.GroupId) : unfolded, width: null, animated: false);
        DockPanel.SetDock(chevron, Dock.Right);
        label.Children.Add(chevron);
        label.Children.Add(Ui.Text(Format.QuietTurns(quiet.Turns.Count), Theme.Fonts.Caption, Theme.Brushes.InkSecondary).Fixed());
        if (wide)
            label.Children.Add(Ui.Text(Theme.Glyphs.Separator + "questions and decisions", Theme.Fonts.Caption, Theme.Brushes.InkTertiary));
        var row = new Border
        {
            Child = label,
            Padding = new Thickness(Theme.Size.ChangesChipHPadding, 0, Theme.Size.ChangesChipHPadding, 0),
            Height = Theme.Size.ChangesRowHeight,
        };
        Grid.SetColumn(row, 1);
        head.Children.Add(row);
        targets[new ChangesItem.Group(quiet.GroupId).Id] = row;
        head.OnTap(() => state.ToggleChangesGroup(quiet.GroupId));
        stack.Children.Add(head);
        // The chevron turns from where it was (the group was just folded or unfolded).
        chevron.Loaded += (_, _) => ChevronTurn.Set(chevron, unfolded);

        if (unfolded)
        {
            for (int i = 0; i < quiet.Turns.Count; i++)
            {
                var turn = quiet.Turns[i];
                var id = new ChangesItem.Quiet(turn.Id).Id;
                var quietRow = QuietRow(turn, id);
                quietIds.Add(id);
                quietRowViews[id] = quietRow;
                stack.Children.Add(quietRow);
                if (built && !shownQuietRows.Contains(id)) Transitions.Insert(quietRow, Theme.Motion.ChangesRowTransition(i));
            }
        }
        return stack;
    }

    private FrameworkElement QuietRow(TranscriptTurn turn, string id)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.ChangesTitleInset) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Node(NodeKind.Tick));
        var inner = new Grid();
        inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inner.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var prompt = new FadeText(turn.Prompt, Theme.Fonts.Caption, Theme.Brushes.InkSecondary)
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, Theme.Size.SpaceM, 0),
        };
        inner.Children.Add(prompt);
        var time = Ui.Text(Format.TimeOfDay(turn.StartedAt), Theme.Fonts.Caption, Theme.Brushes.InkTertiary).Fixed();
        Grid.SetColumn(time, 1);
        inner.Children.Add(time);
        var row = new Border
        {
            Child = inner,
            Padding = new Thickness(Theme.Size.ChangesChipHPadding, 0, Theme.Size.ChangesChipHPadding, 0),
            Height = Theme.Size.ChangesRowHeight,
            ToolTip = turn.Prompt,
        };
        Grid.SetColumn(row, 1);
        grid.Children.Add(row);
        targets[id] = row;
        return grid;
    }
}
