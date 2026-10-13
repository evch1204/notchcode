// MarkdownView.cs
// Port of Sources/notchcode/Features/Files/MarkdownView.swift.
// The Files tool's Preview for .md, .markdown and .mdx files: a small block renderer in WPF.
// Blocks: ATX (# to ####) and setext headings, paragraphs, bullet and numbered lists (nested
// by indent), fenced code, block quotes, horizontal rules, pipe tables, and YAML front matter
// as a code block. Inline bold, italic, code, strikethrough and links (MarkdownParser.Inline).
// No HTML, images, footnotes or indented code blocks: those show as plain text.
//
// It fills the same box the Files preview does (inset fill, snippet radius) and scrolls
// vertically; wide code blocks and tables scroll sideways on their own. A plan request's
// card renders its plan with it too (wave 1d), where ↑↓ move it by blocks:
//
//   var view = MarkdownView.Render(plan, scrollDriven: true);   // a FrameworkElement
//   view.ApplyScroll(state.RequestDiffScroll);                   // on every Seq change
//
// `BlockTops()` gives each block's top in the box, `ScrollByBlocks(delta)` moves by blocks the
// way the Swift view does (the target picked from the block at the edge), and `Note` is
// "more below · scroll" or "end of plan" while scroll-driven content does not fit.

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.Features.StandIns;
using Notchcode.UI.Diff;


namespace Notchcode.Features.Files;

public sealed class MarkdownView : UserControl
{
    public static readonly DependencyProperty MarkdownProperty = DependencyProperty.Register(
        nameof(Markdown), typeof(string), typeof(MarkdownView),
        new PropertyMetadata("", (d, e) => ((MarkdownView)d).Lines = ((string?)e.NewValue ?? "").FileLines()));

    /// The Markdown source as one string (the plan card); setting it sets `Lines`.
    public string Markdown
    {
        get => (string)GetValue(MarkdownProperty);
        set => SetValue(MarkdownProperty, value);
    }

    private IReadOnlyList<string> lines = [];
    private string? footer;
    private List<MarkdownBlock> blocks = [];
    private readonly List<FrameworkElement> blockViews = [];
    private readonly ScrollViewer scroll;
    private readonly StackPanel content;
    private readonly TextBlock noteText;
    private int lastScrollSeq = -1;

    /// Where a scrolled-to block's top sits: one content margin below the box's edge.
    private const double Edge = Theme.Size.MarkdownPadding;

    /// Inside a plan card: ↑↓ arrive as block steps, the content keeps a margin top and bottom,
    /// and the box's foot says whether more is below. The Files tool leaves it off.
    public bool ScrollDriven { get; }

    public MarkdownView() : this(false) { }

    public MarkdownView(bool scrollDriven)
    {
        ScrollDriven = scrollDriven;
        content = new StackPanel
        {
            Margin = scrollDriven
                ? new Thickness(Theme.Size.MarkdownPadding, Edge, Theme.Size.MarkdownPadding, Edge)
                : new Thickness(Theme.Size.MarkdownPadding),
        };
        scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = content,
            Focusable = false,
        };
        noteText = Ui.Block("", Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        noteText.TextTrimming = TextTrimming.CharacterEllipsis;
        noteText.Height = Theme.Size.DiffLineHeight;
        noteText.Margin = new Thickness(Edge, 0, Edge, Theme.Size.PreviewVPadding);
        noteText.Visibility = Visibility.Collapsed;

        var dock = new DockPanel { LastChildFill = true };
        if (scrollDriven)
        {
            DockPanel.SetDock(noteText, Dock.Bottom);
            dock.Children.Add(noteText);
            scroll.ScrollChanged += (_, _) => UpdateNote();
        }
        dock.Children.Add(scroll);
        Content = Boxes.SnippetBox(dock);
    }

    /// A rendered view of `markdown`: the plan card's and anyone else's entry point.
    public static MarkdownView Render(string markdown, string? footer = null, bool scrollDriven = false)
        => new(scrollDriven) { Footer = footer, Markdown = markdown };

    /// The file's lines (the Files tool); the blocks are parsed again when they change.
    public IReadOnlyList<string> Lines
    {
        get => lines;
        set
        {
            if (lines.SequenceEqual(value)) return;
            lines = value;
            blocks = MarkdownParser.Parse(value);
            Rebuild();
        }
    }

    /// "… 212 more lines" when the file was capped.
    public string? Footer
    {
        get => footer;
        set { footer = value; Rebuild(); }
    }

    public IReadOnlyList<MarkdownBlock> Blocks => blocks;

    /// "more below · scroll" while the content runs past the box, "end of plan" once scrolled
    /// to the bottom of content that did not fit, null when it all fits (scroll-driven only).
    public string? Note { get; private set; }

    // MARK: Scrolling by blocks

    /// Each block's top, in the box's coordinates (0 is the top of the visible area).
    public IReadOnlyDictionary<int, double> BlockTops()
    {
        var tops = new Dictionary<int, double>();
        for (int i = 0; i < blockViews.Count && i < blocks.Count; i++)
        {
            if (!blockViews[i].IsArrangeValid) continue;
            tops[blocks[i].Id] = blockViews[i].TranslatePoint(new Point(0, 0), scroll).Y;
        }
        return tops;
    }

    /// One plan-card scroll command: moves only when its `Seq` is new.
    public void ApplyScroll(RequestDiffScroll command)
    {
        if (command.Seq == lastScrollSeq) return;
        lastScrollSeq = command.Seq;
        if (command.Delta != 0) ScrollByBlocks(command.Delta);
    }

    /// ↓: the `delta`-th block whose top is below the edge (the last block when fewer), nothing
    /// once the content's bottom is in view. ↑: the `|delta|`-th block above the edge (the first
    /// when fewer). Lands the target's top one margin below the box's edge. False when nothing moved.
    public bool ScrollByBlocks(int delta)
    {
        if (Target(delta) is not int next || next < 0 || next >= blockViews.Count) return false;
        double top = blockViews[next].TranslatePoint(new Point(0, 0), scroll).Y;
        double offset = Math.Max(0, Math.Min(scroll.ScrollableHeight, scroll.VerticalOffset + top - Edge));
        scroll.ScrollToVerticalOffset(offset);
        return true;
    }

    private int? Target(int delta)
    {
        var tops = BlockTops();
        if (tops.Count == 0) return null;
        // The first block whose top is at or below the edge; every block before it is above.
        var below = tops.Where(kv => kv.Value > Edge - 1).Select(kv => kv.Key).ToList();
        int first = below.Count > 0 ? below.Min() : tops.Keys.Max() + 1;
        if (delta > 0)
        {
            if (scroll.VerticalOffset >= scroll.ScrollableHeight - 1) return null;
            bool atEdge = tops.TryGetValue(first, out var t) && t <= Edge + 1;
            return Math.Min(blocks.Count - 1, first + delta - (atEdge ? 0 : 1));
        }
        return first > 0 ? Math.Max(0, first + delta) : null;
    }

    private void UpdateNote()
    {
        string? note = null;
        if (scroll.ViewportHeight > 0 && scroll.ExtentHeight > scroll.ViewportHeight + 1)
            note = scroll.VerticalOffset < scroll.ScrollableHeight - 1
                ? "more below" + Theme.Glyphs.Separator + "scroll"
                : "end of plan";
        Note = note;
        noteText.Text = note ?? "";
        noteText.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: Building

    private void Rebuild()
    {
        content.Children.Clear();
        blockViews.Clear();
        foreach (var block in blocks)
        {
            var view = BlockView(block);
            view.Margin = new Thickness(0, content.Children.Count == 0 ? 0 : Theme.Size.MarkdownBlockSpacing, 0, 0);
            blockViews.Add(view);
            content.Children.Add(view);
        }
        if (footer is not null)
        {
            var note = Ui.Block(footer, Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
            note.Margin = new Thickness(0, content.Children.Count == 0 ? 0 : Theme.Size.MarkdownBlockSpacing, 0, 0);
            content.Children.Add(note);
        }
        scroll.ScrollToTop();
    }

    private static FrameworkElement BlockView(MarkdownBlock block)
    {
        switch (block.Kind)
        {
            case MarkdownBlockKind.Heading heading:
            {
                var font = heading.Level switch
                {
                    1 => Theme.Fonts.Title,
                    2 or 3 => Theme.Fonts.BodySemibold,
                    _ => Theme.Fonts.CaptionSemibold,
                };
                var color = heading.Level <= 2 ? Theme.Brushes.MarkdownHeading : Theme.Brushes.MarkdownText;
                var text = Prose(heading.Text, font, color);
                return new Border
                {
                    Child = text,
                    Padding = new Thickness(0, block.Id == 0 ? 0 : Theme.Size.MarkdownHeadingTopSpacing, 0, 0),
                };
            }
            case MarkdownBlockKind.Paragraph paragraph:
                return Prose(paragraph.Text);
            case MarkdownBlockKind.List list:
            {
                var stack = new StackPanel();
                foreach (var item in list.Items)
                {
                    var grid = new Grid { Margin = new Thickness(item.Depth * Theme.Size.MarkdownListIndent, stack.Children.Count == 0 ? 0 : Theme.Size.SpaceS, 0, 0) };
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    var marker = new TextBlock
                    {
                        Text = item.Marker,
                        Foreground = Theme.Brushes.MarkdownMarker,
                        LineHeight = Theme.Size.MarkdownLineHeight,
                        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
                        Margin = new Thickness(0, 0, Theme.Size.MarkdownMarkerGap, 0),
                    };
                    Theme.Fonts.Body.Apply(marker);
                    var prose = Prose(item.Text);
                    Grid.SetColumn(prose, 1);
                    grid.Children.Add(marker);
                    grid.Children.Add(prose);
                    stack.Children.Add(grid);
                }
                return stack;
            }
            case MarkdownBlockKind.Code code:
            {
                var lines = new StackPanel { Margin = new Thickness(Theme.Size.MarkdownCodePadding) };
                foreach (var line in code.Lines)
                {
                    var text = Ui.Block(line.Length == 0 ? " " : line, Theme.Fonts.MonoSmall, Theme.Brushes.PreviewText);
                    text.Height = Theme.Size.PreviewLineHeight;
                    lines.Children.Add(text);
                }
                return new Border
                {
                    Background = Theme.Brushes.MarkdownCodeFill,
                    CornerRadius = new CornerRadius(Theme.Radius.Snippet),
                    Child = new ScrollViewer
                    {
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                        Content = lines,
                        Focusable = false,
                    },
                };
            }
            case MarkdownBlockKind.Quote quote:
            {
                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                grid.Children.Add(new VRule(Theme.Brushes.MarkdownQuoteRule, Theme.Size.MarkdownQuoteRule)
                {
                    Margin = new Thickness(0, 0, Theme.Size.MarkdownQuoteGap, 0),
                });
                var prose = Prose(quote.Text);
                Grid.SetColumn(prose, 1);
                grid.Children.Add(prose);
                return grid;
            }
            case MarkdownBlockKind.Rule:
                return new Border { Height = Theme.Size.Hairline, Background = Theme.Brushes.MarkdownRule };
            case MarkdownBlockKind.Table table:
                return Table(table);
            default:
                return new Border();
        }
    }

    private static FrameworkElement Table(MarkdownBlockKind.Table table)
    {
        var grid = new Grid();
        int columns = Math.Max(table.Header.Count, table.Rows.Count == 0 ? 0 : table.Rows.Max(r => r.Count));
        for (int c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        void AddRow(IReadOnlyList<InlineText> cells, FontSpec font, Brush color, Brush? fill)
        {
            int row = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            if (fill is not null)
            {
                var background = new Border { Background = fill };
                Grid.SetRow(background, row);
                Grid.SetColumnSpan(background, Math.Max(1, columns));
                grid.Children.Add(background);
            }
            for (int c = 0; c < cells.Count; c++)
            {
                var text = Prose(cells[c], font, color, wrap: false);
                text.Margin = new Thickness(Theme.Size.MarkdownCellHPadding, Theme.Size.MarkdownCellVPadding,
                    Theme.Size.MarkdownCellHPadding, Theme.Size.MarkdownCellVPadding);
                Grid.SetRow(text, row);
                Grid.SetColumn(text, c);
                grid.Children.Add(text);
            }
        }

        AddRow(table.Header, Theme.Fonts.CaptionSemibold, Theme.Brushes.MarkdownHeading, Theme.Brushes.MarkdownTableHeader);
        foreach (var row in table.Rows)
        {
            int index = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var rule = new Border { Height = Theme.Size.Hairline, Background = Theme.Brushes.MarkdownRule };
            Grid.SetRow(rule, index);
            Grid.SetColumnSpan(rule, Math.Max(1, columns));
            grid.Children.Add(rule);
            AddRow(row, Theme.Fonts.Caption, Theme.Brushes.MarkdownText, null);
        }

        var frame = new Border
        {
            Child = grid,
            BorderBrush = Theme.Brushes.MarkdownRule,
            BorderThickness = new Thickness(Theme.Size.Hairline),
            CornerRadius = new CornerRadius(Theme.Radius.Chip),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Boxes.ClipToRounded(frame, Theme.Radius.Chip);
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = frame,
            Focusable = false,
        };
    }

    /// Inline text in a TextBlock: body prose by default, wrapped, with the Markdown line spacing.
    private static TextBlock Prose(InlineText text, FontSpec? font = null, Brush? color = null, bool wrap = true)
    {
        var f = font ?? Theme.Fonts.Body;
        var block = new TextBlock
        {
            Foreground = color ?? Theme.Brushes.MarkdownText,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        };
        f.Apply(block);
        if (wrap && f.Size <= Theme.Fonts.BodySize)
        {
            block.LineHeight = f.Size >= Theme.Fonts.BodySize ? Theme.Size.MarkdownLineHeight : Theme.Size.CaptionLineHeight + Theme.Size.MarkdownLineSpacing;
            block.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        }
        foreach (var run in text.Runs) block.Inlines.Add(Inline(run, f));
        return block;
    }

    /// One run as a WPF inline: code in the small mono on the code fill, links in the link colour.
    private static Inline Inline(InlineRun run, FontSpec font)
    {
        var parts = run.Text.Split('\n');
        System.Windows.Documents.Span span = new();
        for (int i = 0; i < parts.Length; i++)
        {
            if (i > 0) span.Inlines.Add(new LineBreak());
            var r = new Run(parts[i]);
            if (run.Style.HasFlag(InlineStyle.Code))
            {
                Theme.Fonts.MonoSmall.Apply(r);
                r.Background = Theme.Brushes.MarkdownCodeFill;
            }
            if (run.Style.HasFlag(InlineStyle.Bold)) r.FontWeight = FontWeights.Bold;
            if (run.Style.HasFlag(InlineStyle.Italic)) r.FontStyle = FontStyles.Italic;
            if (run.Style.HasFlag(InlineStyle.Strike)) r.TextDecorations = TextDecorations.Strikethrough;
            span.Inlines.Add(r);
        }
        if (run.Link is not { } target) return span;
        var link = new Hyperlink(span)
        {
            Foreground = Theme.Brushes.MarkdownLink,
            TextDecorations = null,
            Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = target,
        };
        // Web links open in the browser; relative links in a repo lead nowhere from here.
        link.Click += (_, _) =>
        {
            if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)) return;
            try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        };
        return link;
    }
}
