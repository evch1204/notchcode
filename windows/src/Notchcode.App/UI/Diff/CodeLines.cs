// CodeLines.cs
// Port of Sources/notchcode/UI/Diff/CodeLines.swift.
// One line of a file or a diff with its dim number columns, generic over its content:
// clipped to its box (the diff box), or whole for a pane that scrolls sideways. And the
// box that scrolls both ways around such lines (the Files preview, the Git tool's
// reviewer diff).

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Notchcode.UI;

namespace Notchcode.UI.Diff;

/// One line of a file or a diff: one dim number column (a file's lines) or two (a diff's
/// old and new), then the text in the mono size, never wrapped. Without `minWidth` the row
/// fills its box and whatever runs past the edge is cut off (the text never widens the row);
/// with one the line is whole and the row at least that wide, so its `tint` spans a pane
/// that scrolls sideways.
public sealed class CodeLineRow : Panel
{
    private readonly TextBlock[] numberBlocks;
    private readonly UIElement content;
    private readonly double numberWidth;
    private readonly double? minWidth;
    private readonly double height;

    public CodeLineRow(IReadOnlyList<int?> numbers, UIElement content, double numberWidth = Theme.Size.DiffLineNumberWidth,
                       Brush? numberColor = null, double height = Theme.Size.DiffLineHeight, double? minWidth = null, Brush? tint = null)
    {
        this.content = content;
        this.numberWidth = numberWidth;
        this.minWidth = minWidth;
        this.height = height;
        Background = tint;
        ClipToBounds = minWidth is null;
        numberBlocks = numbers.Select(n =>
        {
            var t = Kit.Text(n?.ToString() ?? "", Theme.Fonts.MonoSmall, numberColor ?? Theme.Brushes.DiffLineNumber, TextTrimming.None);
            t.TextAlignment = TextAlignment.Right;
            return t;
        }).ToArray();
        foreach (var t in numberBlocks) Children.Add(t);
        Children.Add(content);
    }

    /// A diff line: both numbers, the +/− prefix and text in its colour, the line's tint, and
    /// the words in `words` (character offsets into the text) with the stronger word tint.
    public static CodeLineRow For(DiffLine line, IReadOnlyList<(int Start, int End)>? words = null, double? minWidth = null)
        => new([line.OldNumber(), line.NewNumber()], line.StyledText(words ?? []), minWidth: minWidth, tint: line.Background());

    private double Gutter => numberBlocks.Length * (numberWidth + Theme.Size.PreviewGutterSpacing);

    protected override Size MeasureOverride(Size available)
    {
        foreach (var t in numberBlocks) t.Measure(new Size(numberWidth, height));
        content.Measure(new Size(double.PositiveInfinity, height));
        double natural = 2 * Theme.Size.PreviewHPadding + Gutter + content.DesiredSize.Width;
        double width = minWidth is { } min ? Math.Max(min, natural) : (double.IsInfinity(available.Width) ? natural : available.Width);
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = Theme.Size.PreviewHPadding;
        foreach (var t in numberBlocks)
        {
            double h = t.DesiredSize.Height;
            t.Arrange(new Rect(x, (height - h) / 2, numberWidth, h));
            x += numberWidth + Theme.Size.PreviewGutterSpacing;
        }
        double ch = content.DesiredSize.Height;
        content.Arrange(new Rect(x, (height - ch) / 2, content.DesiredSize.Width, ch));
        return final;
    }
}

/// ScrollViewer extras: an animatable offset (↑↓ steps glide on `Theme.Motion.Tap`), Shift and
/// the tilt wheel scroll sideways (WPF has no horizontal wheel of its own).
public static class ScrollExtras
{
    public static readonly DependencyProperty AnimatedVerticalOffsetProperty = DependencyProperty.RegisterAttached(
        "AnimatedVerticalOffset", typeof(double), typeof(ScrollExtras),
        new PropertyMetadata(0.0, (d, e) => ((ScrollViewer)d).ScrollToVerticalOffset((double)e.NewValue)));

    /// Glides `scroll` to `offset` on `Theme.Motion.Tap` (at once under Reduce Motion).
    public static void GlideTo(ScrollViewer scroll, double offset)
    {
        offset = Math.Clamp(offset, 0, scroll.ScrollableHeight);
        if (Theme.Motion.ReduceMotion) { Transitions.Snap(scroll, AnimatedVerticalOffsetProperty, offset); return; }
        Transitions.Snap(scroll, AnimatedVerticalOffsetProperty, scroll.VerticalOffset);
        Transitions.Animate(scroll, AnimatedVerticalOffsetProperty, Theme.Motion.Tap, offset);
    }

    /// A ScrollViewer with no visible bars that scrolls by pixels, both ways when `horizontal`.
    public static ScrollViewer Make(bool horizontal)
    {
        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = horizontal ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Disabled,
            CanContentScroll = false,
            Focusable = false,
            PanningMode = horizontal ? PanningMode.Both : PanningMode.VerticalOnly,
        };
        if (horizontal) SideWheel(scroll);
        return scroll;
    }

    private const int WmMouseHWheel = 0x020E;

    /// Shift + wheel and the tilt wheel (WM_MOUSEHWHEEL) scroll `scroll` sideways.
    public static void SideWheel(ScrollViewer scroll)
    {
        scroll.PreviewMouseWheel += (_, e) =>
        {
            if ((Keyboard.Modifiers & ModifierKeys.Shift) == 0) return;
            scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - e.Delta);
            e.Handled = true;
        };
        HwndSourceHook? hook = null;
        HwndSource? source = null;
        scroll.Loaded += (_, _) =>
        {
            source = PresentationSource.FromVisual(scroll) as HwndSource;
            if (source is null) return;
            hook = (IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
            {
                if (msg != WmMouseHWheel || !scroll.IsMouseOver) return IntPtr.Zero;
                int delta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
                scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset + delta);
                handled = true;
                return IntPtr.Zero;
            };
            source.AddHook(hook);
        };
        scroll.Unloaded += (_, _) =>
        {
            if (source is not null && hook is not null) source.RemoveHook(hook);
            source = null;
            hook = null;
        };
    }
}

/// Lines in a box that scrolls both ways (the Files preview, the Git diff): the content's
/// width is set from the longest of `texts` (tabs counted as four spaces, as the rows show
/// them) to give the scroll view its sideways range, and every row gets that width so its tint
/// spans it. `gutter` is what a row puts before its text (the number columns and their gaps);
/// `reserve` is room kept clear at the right edge (the Git minimap). An optional footer line
/// sits under the rows in the text column. The Git diff tracks the content's offset
/// (`OnScroll`) and the pane's height (`OnHeight`) and lays its minimap over the scroll
/// (`Accessory`).
public sealed class WideLinesScroll : Border
{
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: true);
    private readonly StackPanel stack = new();
    private readonly Grid root = new();
    private readonly double gutter, lineHeight, reserve;
    private readonly string? footer;
    private readonly Func<double, IEnumerable<UIElement>> rows;
    private readonly int longest;
    private double builtWidth = -1;

    /// The offset of the content's top as the pane scrolls (Swift's `-minY`).
    public Action<double>? OnScroll { get; set; }
    /// The pane's height, on appear and when it changes.
    public Action<double>? OnHeight { get; set; }

    public WideLinesScroll(IReadOnlyList<string> texts, double gutter, Func<double, IEnumerable<UIElement>> rows,
                           double lineHeight = Theme.Size.DiffLineHeight, double reserve = 0, string? footer = null)
    {
        this.gutter = gutter;
        this.lineHeight = lineHeight;
        this.reserve = reserve;
        this.footer = footer;
        this.rows = rows;
        // `.snippetBox()`: the inset fill at the snippet radius, the content clipped to it.
        Background = Theme.Brushes.Inset;
        CornerRadius = new CornerRadius(Theme.Radius.Snippet);
        Boxes.ClipToRounded(this, Theme.Radius.Snippet);
        longest =texts.Count == 0 ? 0 : texts.Max(t => t.Length + 3 * t.Count(c => c == '\t'));
        stack.Margin = new Thickness(0, Theme.Size.PreviewVPadding, reserve, Theme.Size.PreviewVPadding);
        stack.HorizontalAlignment = HorizontalAlignment.Left;
        scroll.Content = stack;
        root.Children.Add(scroll);
        Child = root;
        scroll.ScrollChanged += (_, e) => { if (e.VerticalChange != 0 || e.ExtentHeightChange != 0) OnScroll?.Invoke(scroll.VerticalOffset); };
        SizeChanged += (_, e) =>
        {
            Rebuild();
            if (e.HeightChanged) OnHeight?.Invoke(ActualHeight);
        };
    }

    /// Laid over the scroll at the top right (the minimap), not scrolling with the lines.
    public UIElement? Accessory
    {
        set
        {
            if (root.Children.Count > 1) root.Children.RemoveAt(1);
            if (value is FrameworkElement fe)
            {
                fe.HorizontalAlignment = HorizontalAlignment.Right;
                fe.VerticalAlignment = VerticalAlignment.Stretch;
                root.Children.Add(fe);
            }
        }
    }

    /// Puts `row` at the top of the pane.
    public void ScrollToRow(int row) => scroll.ScrollToVerticalOffset(Theme.Size.PreviewVPadding + Math.Max(0, row) * lineHeight);

    private void Rebuild()
    {
        double available = Math.Max(0, ActualWidth - reserve);
        double textWidth = Theme.Size.PreviewHPadding * 2 + gutter + longest * Theme.Fonts.MonoSmallAdvance;
        double contentWidth = Math.Max(available, Math.Ceiling(textWidth));
        if (Math.Abs(contentWidth - builtWidth) < 0.5) return;
        builtWidth = contentWidth;
        stack.Children.Clear();
        stack.Width = contentWidth;
        foreach (var row in rows(contentWidth)) stack.Children.Add(row);
        if (footer is not null)
        {
            var note = Kit.Text(footer, Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None);
            note.Margin = new Thickness(gutter + Theme.Size.PreviewHPadding, 0, 0, 0);
            note.Height = lineHeight;
            stack.Children.Add(note);
        }
    }
}
