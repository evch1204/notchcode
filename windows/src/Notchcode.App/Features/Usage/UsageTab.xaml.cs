// UsageTab.xaml.cs
// Port of Sources/notchcode/Features/Usage/UsageTab.swift.
// One fixed page, never scrolls, never changes shape with data. Row 1: the limit tiles,
// 5-hour, Week, one per model week ("Fable week") and Spend behind a gateway (percent, bar,
// reset). Row 2: context, with what the last call cached. Row 3: This session (tokens, cost,
// time, lines), Today (tokens, cost, Fable share), This week (where it went). Row 4: what's
// using your limits. Footer: where the numbers come from and how old they are. Unknown
// values show "—" in the same place; numbers are never invented.
//
// Sources: Claude Code's status line (limits, context, cost, time, lines, model), its usage
// cache in %USERPROFILE%\.claude.json (model weeks, the week breakdown; refreshed by a headless
// `claude -p /usage` run, see AppState.PlanUsage) and the transcripts (tokens, today).

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.Features.StandIns;
using Notchcode.UI.Diff;


namespace Notchcode.Features.Usage;

public partial class UsageTab : UserControl
{
    private AppState? state;
    private StateWatcher? watcher;
    /// Bars start empty and fill once the pane has landed; after that they follow at once.
    private bool filled;
    /// What fills when the pane lands: each bar and its fraction.
    private readonly List<Action<MotionSpec?>> bars = [];
    private readonly DispatcherTimer footTimer = new() { Interval = TimeSpan.FromSeconds(Theme.Timing.LimitsFootnoteTick) };
    private TextLine? foot;

    public UsageTab()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            FillBars();
            footTimer.Start();
        };
        Unloaded += (_, _) => footTimer.Stop();
        footTimer.Tick += (_, _) => { if (foot is not null) foot.Text = Footnote(DateTime.UtcNow); };
    }

    public UsageTab(AppState state) : this() => State = state;

    public AppState? State
    {
        get => state;
        set
        {
            state = value;
            if (value is null) return;
            watcher = new StateWatcher(this, value,
                [nameof(AppState.Usage), nameof(AppState.Statusline), nameof(AppState.FocusedSessionId), nameof(AppState.Sessions),
                 nameof(AppState.UsageBehaviors), nameof(AppState.PlanUsageNote), nameof(AppState.PlanUsageRefreshing),
                 nameof(AppState.PlanUsage), nameof(AppState.LimitsUpdatedAt), nameof(AppState.Prefs), nameof(AppState.TurnsBySession)],
                Rebuild);
            Rebuild();
        }
    }

    /// Runs any pending rebuild now (the harness renders without a dispatcher turn).
    public void Flush() => watcher?.Flush();

    /// The bars fill on `BarFill` (after the pane's slide); Reduce Motion: at once.
    private void FillBars()
    {
        if (filled) return;
        filled = true;
        foreach (var fill in bars) fill(Theme.Motion.ReduceMotion ? null : Theme.Motion.BarFill);
    }

    private void Rebuild()
    {
        if (state is null) return;
        bars.Clear();
        Root.Children.Clear();
        Root.RowDefinitions.Clear();
        var usage = state.Usage;
        double[] heights =
        [
            Theme.Size.UsageLimitsRowHeight, Theme.Size.UsageRowSpacing,
            Theme.Size.UsageContextRowHeight, Theme.Size.UsageRowSpacing,
            Theme.Size.UsageSessionRowHeight, Theme.Size.UsageRowSpacing,
            Theme.Size.UsageBehaviorsRowHeight, Theme.Size.UsageRowSpacing,
            Theme.Size.UsageFootnoteHeight,
        ];
        foreach (var h in heights) Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(h) });

        Place(LimitsRow(usage), 0);
        Place(ContextTile(state.ContextPercent, usage.ContextUsed, usage.ContextLimit ?? AppState.StandardContextLimit,
            state.FocusedStatusline, ModelName), 2);
        Place(SessionRow(usage), 4);
        Place(BehaviorsTile(state.UsageBehaviors, state.PlanUsageNote), 6);
        // "updated 3m ago" has to age on its own while the status line is quiet.
        foot = new TextLine(Footnote(DateTime.UtcNow), Theme.Fonts.Tiny, Theme.Brushes.InkTertiary, Truncation.Middle)
        {
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Place(foot, 8);
    }

    private void Place(FrameworkElement element, int row)
    {
        Grid.SetRow(element, row);
        Root.Children.Add(element);
    }


    // MARK: Rows

    /// 5-hour, Week, one tile per model week (a "Fable week" placeholder until the usage
    /// cache has been read), then Spend when the status line reports one.
    private FrameworkElement LimitsRow(UsageSnapshot usage)
    {
        var tiles = new List<FrameworkElement>
        {
            LimitTile("5-hour", usage.FiveHourPercent, usage.FiveHourResetsAt, "connect the status line"),
            LimitTile("Week", usage.WeekPercent, usage.WeekResetsAt, "connect the status line"),
        };
        if (usage.ModelWeeks.Count == 0)
            tiles.Add(LimitTile("Fable week", null, null, "from /usage"));
        else
            tiles.AddRange(usage.ModelWeeks.Select(w => LimitTile(w.Name + " week", w.Percent, w.ResetsAt, "from /usage")));
        if (usage.SpendLimit is { } spend)
        {
            string? detail = spend.UsedUSD is double used && spend.LimitUSD is double limit ? Format.Spend(used, limit) : null;
            tiles.Add(LimitTile("Spend", spend.Percent, spend.ResetsAt, " ", detail));
        }
        return Tiles(tiles);
    }

    /// Tiles sharing the row's width equally, `UsageTileSpacing` apart (the gaps are their own
    /// columns, so the end tiles are no wider than the middle ones).
    private static Grid Tiles(IReadOnlyList<FrameworkElement> tiles)
    {
        var grid = new Grid();
        for (int i = 0; i < tiles.Count; i++)
        {
            if (i > 0) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.UsageTileSpacing) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(tiles[i], 2 * i);
            grid.Children.Add(tiles[i]);
        }
        return grid;
    }

    private FrameworkElement SessionRow(UsageSnapshot usage) => Tiles(
    [
        SmallTile("This session", usage.SessionTokens is { } st ? Format.Tokens(st.Total) : null, SessionDetail(usage),
            usage.SessionTokens ?? new TokenUsage(), showsBar: true),
        SmallTile("Today", usage.TodayTokens is { } tt ? Format.Tokens(tt.Total) : null, TodayDetail(usage)),
        SmallTile("This week", usage.WeekBreakdown.Count > 0 ? Share(usage.WeekBreakdown[0]) : null,
            usage.WeekBreakdown.Count == 0 ? "from /usage" : WeekRest(usage)),
    ]);

    /// "Fable 5.1" from the status line, else "Fable" from the model id.
    private string? ModelName
    {
        get
        {
            if (state!.FocusedStatusline?.DisplayName is { } name) return name;
            if (state.FocusedSession?.Id is not { } id || state.ModelShortName(id) is not { } shortName) return null;
            return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(shortName);
        }
    }

    /// "$1.42 · 3h 27m · +2351 −147", unknown parts left out.
    private string? SessionDetail(UsageSnapshot usage)
    {
        var facts = state!.FocusedStatusline;
        var parts = new List<string>();
        if (usage.SessionCostUSD is double cost) parts.Add(Cost(Format.Money(cost), estimated: !state.SessionCostIsReported));
        if (facts?.DurationMs is long ms) parts.Add(Format.Duration(ms / 1000.0));
        var lines = new[] { facts?.LinesAdded is long a ? Format.Added((int)a) : null, facts?.LinesRemoved is long r ? Format.Removed((int)r) : null }
            .OfType<string>().ToList();
        if (lines.Count > 0) parts.Add(string.Join(" ", lines));
        return parts.Count == 0 ? null : string.Join(Theme.Glyphs.Separator, parts);
    }

    /// "~$12.40 · Fable 78%": today's cost, then today's Fable share of tokens (left out at zero).
    private static string? TodayDetail(UsageSnapshot usage)
    {
        var parts = new List<string>();
        if (usage.TodayCostUSD is double cost) parts.Add(Cost(Format.Money(cost), usage.CostIsEstimate));
        if (usage.TodayFableTokens?.Total is long fable && usage.TodayTokens?.Total is long total && fable > 0 && total > 0)
            parts.Add("Fable " + Format.Percent((double)fable / total * 100));
        return parts.Count == 0 ? null : string.Join(Theme.Glyphs.Separator, parts);
    }

    /// "Claude Code 98%".
    private static string Share(NamedShare row) => row.Name + " " + Format.Percent(row.Percent);

    /// "Chats 2%": the breakdown after its first row, the ones above zero.
    private static string? WeekRest(UsageSnapshot usage)
    {
        var rest = usage.WeekBreakdown.Skip(1).Where(r => r.Percent > 0).ToList();
        return rest.Count == 0 ? null : string.Join(Theme.Glyphs.Separator, rest.Select(Share));
    }

    /// "cost from Claude Code · limits updated 3m ago · plan usage 8m ago".
    private string Footnote(DateTime now)
    {
        if (state is null) return "";
        var costPart = state.SessionCostIsReported ? "cost from Claude Code" : "cost estimated from tokens";
        var limits = state.LimitsUpdatedAt is DateTime at ? Format.LimitsAsOf(at, now) : "limits from Claude Code's status line";
        string plan;
        if (state.PlanUsageRefreshing) plan = "plan usage refreshing" + Theme.Glyphs.Ellipsis;
        else if (state.PlanUsageNote is { } note) plan = note;
        else if (!state.Prefs.PlanUsageRefresh) plan = "plan usage off in Settings";
        else if (state.PlanUsage?.FetchedAt is DateTime fetched) plan = "plan usage " + Format.Ago(fetched, now);
        else plan = "plan usage from /usage";
        return string.Join(Theme.Glyphs.Separator, costPart, limits, plan);
    }

    /// "~$1.42" when estimated from tokens, "$1.42" when Claude Code reported it.
    private static string Cost(string text, bool estimated) => estimated ? Theme.Glyphs.Estimate + text : text;

    // MARK: Tiles

    private static TextBlock Line(string text, FontSpec font, Brush brush, double lineHeight)
    {
        var block = Ui.Block(text, font, brush);
        block.TextTrimming = TextTrimming.CharacterEllipsis;
        block.LineHeight = lineHeight;
        block.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        return block;
    }

    /// A tile's lines top to bottom: `top` items, then the flexible gap, then `bottom` items,
    /// `UsageLineSpacing` between the items of each part.
    private static Grid Stack(IReadOnlyList<FrameworkElement> top, IReadOnlyList<FrameworkElement> bottom)
    {
        var grid = new Grid();
        int row = 0;
        void Add(FrameworkElement e, bool gapBefore)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            e.Margin = new Thickness(0, gapBefore ? Theme.Size.UsageLineSpacing : 0, 0, 0);
            Grid.SetRow(e, row++);
            grid.Children.Add(e);
        }
        for (int i = 0; i < top.Count; i++) Add(top[i], i > 0);
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        row++;
        for (int i = 0; i < bottom.Count; i++) Add(bottom[i], i > 0);
        return grid;
    }

    /// "5-hour", "61%" large, a bar, "resets in 1h 52m". Before any limit has arrived: "—",
    /// an empty bar and `emptyNote`, in the same places. When the window has rolled over since
    /// the last report, the old percent dims and the line says when it reset. The bar turns clay
    /// at `Theme.Limits.LimitWarnPercent`.
    private FrameworkElement LimitTile(string title, double? percent, DateTime? resetsAt, string emptyNote, string? detail = null)
    {
        bool hasReset = AppState.LimitWindowHasReset(resetsAt);
        var number = Line(percent is double p ? Format.Percent(Math.Min(100, p)) : Theme.Glyphs.EmDash, Theme.Fonts.BigNumber,
            percent is null || hasReset ? Theme.Brushes.InkTertiary : Theme.Brushes.Ink, Theme.Size.UsageBigNumberLineHeight);
        var bar = new UsageBar(0, (percent ?? 0) >= Theme.Limits.LimitWarnPercent ? Theme.Brushes.LimitBarHigh : Theme.Brushes.LimitBar);
        double fraction = (percent ?? 0) / 100;
        BarFill.Set(bar, filled ? fraction : 0);
        bars.Add(spec => BarFill.Set(bar, fraction, spec));

        string footnote;
        if (percent is null) footnote = emptyNote;
        else if (hasReset && resetsAt is DateTime r) footnote = Format.ResetAt(r);
        else if (detail is not null) footnote = detail;
        // A blank line keeps the tile's layout identical when no reset time is known.
        else footnote = resetsAt is DateTime at ? Format.Resets(at) : " ";

        var stack = Stack(
            [Line(title, Theme.Fonts.CaptionMedium, Theme.Brushes.InkSecondary, Theme.Size.UsageCaptionLineHeight)],
            [number, bar, Line(footnote, Theme.Fonts.Caption, Theme.Brushes.InkTertiary, Theme.Size.UsageCaptionLineHeight)]);
        return new InsetGroup(stack, Theme.Radius.Tile, fillsHeight: true);
    }

    private sealed record TokenSegment(string Label, long Count, Brush Color);

    /// "Context · Fable 5.1 · effort high · thinking · past 200k" with "36% · 357k of 1M" at the
    /// right; an 8 pt bar filled to the percent, split by the last call's input side (cached, new
    /// to cache, fresh) when the status line sent it; the legend and "643k free".
    private FrameworkElement ContextTile(double? percent, long? used, long limit, Features.Usage.StatuslineFacts? facts, string? modelName)
    {
        List<TokenSegment>? segments = facts?.CurrentUsage is { } current
            ?
            [
                new("cached", current.CacheRead, Theme.Brushes.TokenCacheRead),
                new("new to cache", current.CacheWrite, Theme.Brushes.TokenCacheWrite),
                new("fresh", current.Input, Theme.Brushes.TokenInput),
            ]
            : null;

        // The headline: "Context" then the model and its modes, "past 200k" in clay.
        var headline = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };
        headline.LineHeight = Theme.Size.UsageCaptionLineHeight;
        headline.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        Theme.Fonts.Caption.Apply(headline);
        var contextRun = new Run("Context") { Foreground = Theme.Brushes.InkSecondary };
        Theme.Fonts.CaptionMedium.Apply(contextRun);
        headline.Inlines.Add(contextRun);
        var details = new List<string>();
        if (modelName is not null) details.Add(modelName);
        if (facts?.Effort is { } effort) details.Add("effort " + effort);
        if (facts?.ThinkingEnabled == true) details.Add("thinking");
        if (facts?.FastMode == true) details.Add("fast");
        if (details.Count > 0)
            headline.Inlines.Add(new Run(Theme.Glyphs.Separator + string.Join(Theme.Glyphs.Separator, details)) { Foreground = Theme.Brushes.InkTertiary });
        if (facts?.Exceeds200k == true)
        {
            headline.Inlines.Add(new Run(Theme.Glyphs.Separator) { Foreground = Theme.Brushes.InkTertiary });
            headline.Inlines.Add(new Run("past 200k") { Foreground = Theme.Brushes.LimitBarHigh });
        }

        // "36% · 357k of 1M", or "36% of 1M" without a token count.
        string? amount = null;
        if (percent is double pc)
        {
            var of = " of " + Format.Tokens(limit);
            amount = used is long u ? Format.Percent(pc) + Theme.Glyphs.Separator + Format.Tokens(u) + of : Format.Percent(pc) + of;
        }
        var amountText = Line(amount ?? Theme.Glyphs.EmDash, Theme.Fonts.CaptionMedium,
            amount is null ? Theme.Brushes.InkTertiary : Theme.Brushes.Ink, Theme.Size.UsageCaptionLineHeight);
        amountText.TextTrimming = TextTrimming.None;
        var top = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(amountText, Dock.Right);
        amountText.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
        top.Children.Add(amountText);
        top.Children.Add(headline);

        var bar = ContextBar(Math.Min(Math.Max((percent ?? 0) / 100, 0), 1), segments);

        // The legend, then "643k free" (a blank line keeps the height when nothing is known).
        var legend = new DockPanel { LastChildFill = false };
        var free = Line(used is long inUse ? Format.Tokens(Math.Max(0, limit - inUse)) + " free" : " ", Theme.Fonts.Tiny,
            Theme.Brushes.InkTertiary, Theme.Size.UsageTinyLineHeight);
        DockPanel.SetDock(free, Dock.Right);
        legend.Children.Add(free);
        if (segments is not null)
        {
            foreach (var segment in segments)
            {
                var dot = new Border
                {
                    Width = Theme.Size.LegendDot,
                    Height = Theme.Size.LegendDot,
                    CornerRadius = new CornerRadius(Theme.Size.LegendDot / 2),
                    Background = segment.Color,
                };
                var chip = new HStack(Theme.Size.SpaceS, dot,
                    Line(segment.Label, Theme.Fonts.Tiny, Theme.Brushes.InkTertiary, Theme.Size.UsageTinyLineHeight),
                    Line(Format.Tokens(segment.Count), Theme.Fonts.Tiny, Theme.Brushes.InkSecondary, Theme.Size.UsageTinyLineHeight));
                chip.Margin = new Thickness(0, 0, Theme.Size.UsageLegendSpacing, 0);
                legend.Children.Add(chip);
            }
        }

        var stack = new StackPanel();
        stack.Children.Add(top);
        bar.Margin = new Thickness(0, Theme.Size.UsageLineSpacing, 0, 0);
        stack.Children.Add(bar);
        legend.Margin = new Thickness(0, Theme.Size.UsageLineSpacing, 0, 0);
        stack.Children.Add(legend);
        return new InsetGroup(stack, Theme.Radius.Tile, fillsHeight: true);
    }

    /// The 8 pt context bar: the track, then the fill to `fraction`, split into the segments
    /// (or clay when the split is unknown). The fill grows from the left when the pane lands.
    private FrameworkElement ContextBar(double fraction, List<TokenSegment>? segments)
    {
        var track = new Grid { Height = Theme.Size.TokenBarHeight, Background = Theme.Brushes.Track };
        Boxes.ClipToRounded(track, Theme.Size.TokenBarHeight / 2);
        var fill = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        var scale = new ScaleTransform(filled ? 1 : 0, 1);
        fill.RenderTransform = scale;
        track.Children.Add(fill);
        long total = segments?.Sum(s => s.Count) ?? 0;
        track.SizeChanged += (_, _) =>
        {
            double width = track.ActualWidth * fraction;
            fill.Width = width;
            fill.Children.Clear();
            fill.ColumnDefinitions.Clear();
            if (segments is not null && total > 0)
            {
                for (int i = 0; i < segments.Count; i++)
                {
                    fill.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width * segments[i].Count / total) });
                    var part = new Border { Background = segments[i].Color };
                    Grid.SetColumn(part, i);
                    fill.Children.Add(part);
                }
            }
            else
            {
                fill.Children.Add(new Border { Background = Theme.Brushes.ContextBar });
            }
        };
        bars.Add(spec =>
        {
            if (spec is MotionSpec s) Transitions.Animate(scale, ScaleTransform.ScaleXProperty, s, 1);
            else Transitions.Snap(scale, ScaleTransform.ScaleXProperty, 1);
        });
        return track;
    }

    /// "This session", "357k" (semibold), an optional 6 pt four-part token bar, a caption.
    /// The bar's slot is kept empty in tiles without one, so the row's lines line up.
    private FrameworkElement SmallTile(string title, string? value, string? detail, TokenUsage? tokens = null, bool showsBar = false)
    {
        var valueText = Line(value ?? Theme.Glyphs.EmDash, Theme.Fonts.BodySemibold,
            value is null ? Theme.Brushes.InkTertiary : Theme.Brushes.Ink, Theme.Size.UsageValueLineHeight);
        FrameworkElement slot = showsBar && tokens is not null ? TokenBar(tokens) : new Border();
        slot.Height = Theme.Size.UsageMiniBarHeight;
        var stack = Stack(
            [Line(title, Theme.Fonts.CaptionMedium, Theme.Brushes.InkSecondary, Theme.Size.UsageCaptionLineHeight)],
            [valueText, slot, Line(detail ?? " ", Theme.Fonts.Caption, Theme.Brushes.InkTertiary, Theme.Size.UsageCaptionLineHeight)]);
        return new InsetGroup(stack, Theme.Radius.Tile, fillsHeight: true, verticalPadding: Theme.Size.UsageCompactPadding);
    }

    /// Input, output, cache read, cache write in proportion, growing from the left.
    private FrameworkElement TokenBar(TokenUsage tokens)
    {
        var track = new Grid { Background = Theme.Brushes.Track };
        Boxes.ClipToRounded(track, Theme.Size.UsageMiniBarHeight / 2);
        var fill = new Grid();
        var scale = new ScaleTransform(filled ? 1 : 0, 1);
        fill.RenderTransform = scale;
        track.Children.Add(fill);
        long total = tokens.Total;
        if (total > 0)
        {
            (long Count, Brush Color)[] parts =
            [
                (tokens.Input, Theme.Brushes.TokenInput),
                (tokens.Output, Theme.Brushes.TokenOutput),
                (tokens.CacheRead, Theme.Brushes.TokenCacheRead),
                (tokens.CacheWrite, Theme.Brushes.TokenCacheWrite),
            ];
            for (int i = 0; i < parts.Length; i++)
            {
                fill.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(parts[i].Count, GridUnitType.Star) });
                var part = new Border { Background = parts[i].Color };
                Grid.SetColumn(part, i);
                fill.Children.Add(part);
            }
        }
        bars.Add(spec =>
        {
            if (spec is MotionSpec s) Transitions.Animate(scale, ScaleTransform.ScaleXProperty, s, 1);
            else Transitions.Snap(scale, ScaleTransform.ScaleXProperty, 1);
        });
        return track;
    }

    /// "Last 24h · 155 requests · 2 sessions" with the week's counts at the right, then the
    /// day's behaviours on one line ("94% from subagent-heavy sessions · 82% at >150k context").
    private static FrameworkElement BehaviorsTile(UsageBehaviors? behaviors, string? note)
    {
        var day = behaviors?.Day;
        var lines = (day ?? behaviors?.Week)?.Lines ?? [];
        var head = new DockPanel { LastChildFill = true };
        if (behaviors?.Week is { } week)
        {
            var weekText = Line(BehaviorPeriod(week), Theme.Fonts.Caption, Theme.Brushes.InkTertiary, Theme.Size.UsageCaptionLineHeight);
            weekText.Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0);
            DockPanel.SetDock(weekText, Dock.Right);
            head.Children.Add(weekText);
        }
        head.Children.Add(Line(day is null ? "What's using your limits" : BehaviorPeriod(day), Theme.Fonts.CaptionMedium,
            Theme.Brushes.InkSecondary, Theme.Size.UsageCaptionLineHeight));
        var body = Line(lines.Count == 0 ? note ?? "from /usage" : string.Join(Theme.Glyphs.Separator, lines.Select(Behavior)),
            Theme.Fonts.Caption, Theme.Brushes.InkTertiary, Theme.Size.UsageCaptionLineHeight);
        var stack = Stack([head], [body]);
        return new InsetGroup(stack, Theme.Radius.Tile, fillsHeight: true, verticalPadding: Theme.Size.UsageCompactPadding);
    }

    /// One "What's contributing" line in fewer words: "94% from subagent-heavy sessions",
    /// "82% at >150k context", "subagents general-purpose 34%, fork 5%".
    private static string Behavior(string line)
    {
        (string From, string To)[] replacements =
        [
            ("% of your usage came from ", "% from "),
            ("% of your usage was ", "% "),
            ("% of your usage hit ", "% hit "),
            ("Top subagents: ", "subagents "),
            ("Top skills: ", "skills "),
            ("Top plugins: ", "plugins "),
            ("Top MCP servers: ", "MCP "),
        ];
        return replacements.Aggregate(line, (text, r) => text.Replace(r.From, r.To, StringComparison.Ordinal));
    }

    /// "Last 24h · 155 requests · 2 sessions".
    private static string BehaviorPeriod(UsageBehaviorPeriod period)
        => string.Join(Theme.Glyphs.Separator, period.Title, period.Requests + " requests", Format.Sessions(period.Sessions));
}
