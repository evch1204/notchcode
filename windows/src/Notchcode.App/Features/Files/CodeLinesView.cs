// CodeLinesView.cs
// The Files preview's lines (PreviewLines in FilesTab.swift): a snippet box that scrolls both
// ways, one dim number column, the text in the small mono size, never wrapped, each line's
// tint spanning the content's width, the red mark where lines were removed, an optional
// footer line under the rows. Only the rows on screen are drawn, so a 3000-line file costs
// what its visible rows cost.
//
// Why not the shared `WideLinesScroll` + `CodeLineRow` (UI/Diff/CodeLines.cs): that one builds
// one element per line up front, which is right for a diff (400 lines at most) and slow for a
// 3000-line preview; and `CodeLineRow` has no removed-line mark. The Changes diff pane uses
// the shared `ReviewerDiff`. The sideways wheel is the shared `ScrollExtras`.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Files;

/// One drawn line: its number columns, its text, colours, an optional tint behind it, and
/// the red mark at its left edge where removed lines used to be.
public sealed record CodeLine(IReadOnlyList<int?> Numbers, string Text, Brush TextBrush, Brush NumberBrush,
    Brush? Tint = null, bool RemovedMark = false);

public sealed class CodeLinesView : Border
{
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: true);
    private readonly Surface surface;

    /// `numberWidth` per number column; `reserve` is room kept clear at the right edge.
    public CodeLinesView(IReadOnlyList<CodeLine> lines, double numberWidth, double lineHeight, string? footer = null, double reserve = 0)
    {
        surface = new Surface(numberWidth, lineHeight);
        surface.Set(lines, footer);
        scroll.Content = surface;
        scroll.Padding = new Thickness(0, 0, reserve, 0);
        scroll.ScrollChanged += (_, e) =>
        {
            surface.Window = (scroll.VerticalOffset, scroll.ViewportHeight);
            surface.InvalidateVisual();
        };
        SizeChanged += (_, _) => surface.MinWidth = Math.Max(0, ActualWidth - reserve);
        Child = Boxes.SnippetBox(scroll);
    }

    /// New lines or tints for the same file (a turn changed it): drawn in place, the scroll
    /// position kept, as SwiftUI keeps a view whose identity (the path) did not change.
    public void Update(IReadOnlyList<CodeLine> lines, string? footer)
    {
        surface.Set(lines, footer);
        surface.InvalidateMeasure();
        surface.InvalidateVisual();
    }

    /// Scrolls so line `number` (1-based) sits at the top, once the view is laid out.
    public void ScrollToLine(int number)
    {
        void Go() => scroll.ScrollToVerticalOffset(Math.Max(0, (number - 1) * surface.LineHeight));
        if (IsLoaded) Go();
        else Loaded += (_, _) => Dispatcher.BeginInvoke(Go, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private sealed class Surface(double numberWidth, double lineHeight) : FrameworkElement
    {
        private IReadOnlyList<CodeLine> lines = [];
        private string? footer;
        private int columns = 1;
        private double gutter;
        private double textWidth;

        public double LineHeight { get; } = lineHeight;
        public (double Offset, double Height) Window = (0, 0);

        public void Set(IReadOnlyList<CodeLine> newLines, string? newFooter)
        {
            lines = newLines;
            footer = newFooter;
            columns = lines.Count == 0 ? 1 : lines.Max(l => l.Numbers.Count);
            gutter = columns * (numberWidth + Theme.Size.PreviewGutterSpacing);
            int longest = lines.Count == 0 ? 0 : lines.Max(l => l.Text.Length + 3 * l.Text.Count(c => c == '\t'));
            textWidth = Math.Ceiling(Theme.Size.PreviewHPadding * 2 + gutter + longest * Theme.Fonts.MonoSmallAdvance);
        }

        private int RowCount => lines.Count + (footer is null ? 0 : 1);

        protected override Size MeasureOverride(Size availableSize)
            => new(textWidth, 2 * Theme.Size.PreviewVPadding + RowCount * LineHeight);

        private FormattedText Text(string s, Brush brush, FontSpec font) =>
            new(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, font.Typeface, font.Size, brush,
                VisualTreeHelper.GetDpi(this).PixelsPerDip);

        protected override void OnRender(DrawingContext dc)
        {
            double width = Math.Max(RenderSize.Width, textWidth);
            double top = Window.Height > 0 ? Window.Offset : 0;
            // Before the first scroll report, one screenful is plenty: the report follows the first layout.
            double height = Window.Height > 0 ? Window.Height : Math.Min(RenderSize.Height, 1200);
            int first = Math.Max(0, (int)((top - Theme.Size.PreviewVPadding) / LineHeight) - 1);
            int last = Math.Min(RowCount - 1, (int)((top + height) / LineHeight) + 1);
            var font = Theme.Fonts.MonoSmall;
            for (int i = first; i <= last; i++)
            {
                double y = Theme.Size.PreviewVPadding + i * LineHeight;
                if (i >= lines.Count)
                {
                    var note = Text(footer ?? "", Theme.Brushes.InkTertiary, Theme.Fonts.Caption);
                    dc.DrawText(note, new Point(Theme.Size.PreviewHPadding + gutter, y + (LineHeight - note.Height) / 2));
                    continue;
                }
                var line = lines[i];
                if (line.Tint is not null) dc.DrawRectangle(line.Tint, null, new Rect(0, y, width, LineHeight));
                if (line.RemovedMark) dc.DrawRectangle(Theme.Brushes.PreviewRemovedMark, null, new Rect(0, y, Theme.Size.RemovedMarkWidth, LineHeight));
                double x = Theme.Size.PreviewHPadding;
                for (int c = 0; c < columns; c++)
                {
                    var n = c < line.Numbers.Count ? line.Numbers[c] : null;
                    if (n is int number)
                    {
                        var ft = Text(number.ToString(CultureInfo.InvariantCulture), line.NumberBrush, font);
                        dc.DrawText(ft, new Point(x + numberWidth - ft.WidthIncludingTrailingWhitespace, y + (LineHeight - ft.Height) / 2));
                    }
                    x += numberWidth + Theme.Size.PreviewGutterSpacing;
                }
                var text = Text(line.Text.Replace("\t", "    "), line.TextBrush, font);
                dc.DrawText(text, new Point(x, y + (LineHeight - text.Height) / 2));
            }
        }
    }
}
