// PanesBKit.cs
// The few layout pieces SwiftUI gives for free and WPF does not, used by the diff views, the
// Git tool, the request cards and Settings (wave 1d): stacks with spacing and a flexible
// child (RowStack / ColumnStack with a Spacer or a maxWidth: .infinity frame), text that truncates
// in the middle or at the tail (`.truncationMode`), a border that clips its content to its
// rounded shape (`.clipShape`), and a few one-line builders. Every value still comes from Theme.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Notchcode.UI.Diff;

/// How a stack places a child across its axis.
public enum StackCross { Center, Start, End, Stretch }

/// SwiftUI's HStack: children left to right, `Spacing` apart (collapsed ones take no gap),
/// centred vertically. A child marked `Flex` (a `Spacer`, or `.frame(maxWidth: .infinity)`)
/// takes what the others leave; several share it. A child that does not fit is given less
/// room, so a trimming text truncates instead of pushing the rest out.
public class RowStack : Panel
{
    public static readonly DependencyProperty FlexProperty = DependencyProperty.RegisterAttached(
        "Flex", typeof(bool), typeof(RowStack), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsParentMeasure));
    public static bool GetFlex(DependencyObject d) => (bool)d.GetValue(FlexProperty);
    public static void SetFlex(DependencyObject d, bool value) => d.SetValue(FlexProperty, value);

    /// Takes room before the others when the row is short (SwiftUI's `.layoutPriority`).
    public static readonly DependencyProperty PriorityProperty = DependencyProperty.RegisterAttached(
        "Priority", typeof(int), typeof(RowStack), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsParentMeasure));
    public static int GetPriority(DependencyObject d) => (int)d.GetValue(PriorityProperty);
    public static void SetPriority(DependencyObject d, int value) => d.SetValue(PriorityProperty, value);

    public double Spacing { get; set; }
    public StackCross Cross { get; set; } = StackCross.Center;

    public RowStack() { }

    public RowStack(double spacing, params UIElement?[] children)
    {
        Spacing = spacing;
        foreach (var child in children) if (child is not null) Children.Add(child);
    }

    private List<UIElement> Visible => InternalChildren.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed).ToList();

    private double[] widths = [];

    protected override Size MeasureOverride(Size available)
    {
        var kids = Visible;
        widths = new double[kids.Count];
        double gaps = Math.Max(0, kids.Count - 1) * Spacing;
        double room = Math.Max(0, available.Width - gaps);
        double height = 0;
        // Fixed children first, highest priority first; each gets what is left.
        var order = Enumerable.Range(0, kids.Count).Where(i => !GetFlex(kids[i]))
            .OrderByDescending(i => GetPriority(kids[i])).ToList();
        double used = 0;
        foreach (int i in order)
        {
            kids[i].Measure(new Size(double.PositiveInfinity, available.Height));
            widths[i] = kids[i].DesiredSize.Width;
        }
        // Too wide: lower priority children give way first, from the end, each only down to
        // the least it can show (a trimming text to nothing, a keycap not at all), as SwiftUI
        // truncates text rather than dropping fixed-size views.
        double total = order.Sum(i => widths[i]);
        if (!double.IsInfinity(room) && total > room)
        {
            var least = new double[kids.Count];
            foreach (int i in order) least[i] = CanShrink(kids[i]) ? 0 : widths[i];
            foreach (int i in Enumerable.Reverse(order).OrderBy(i => GetPriority(kids[i])))
            {
                double over = total - room;
                if (over <= 0) break;
                double give = Math.Min(over, widths[i] - least[i]);
                widths[i] -= give;
                total -= give;
            }
        }
        foreach (int i in order)
        {
            // Only a child that gave way is measured again at its smaller width; the others keep
            // their unbounded measure, so a text that grows later (a clock's first tick) still
            // asks for more room.
            kids[i].Measure(new Size(double.PositiveInfinity, available.Height));
            if (widths[i] < kids[i].DesiredSize.Width)
            {
                kids[i].Measure(new Size(widths[i], available.Height));
                widths[i] = Math.Min(widths[i], kids[i].DesiredSize.Width);
            }
            used += widths[i];
            height = Math.Max(height, kids[i].DesiredSize.Height);
        }
        var flex = Enumerable.Range(0, kids.Count).Where(i => GetFlex(kids[i])).ToList();
        double left = double.IsInfinity(room) ? 0 : Math.Max(0, room - used);
        foreach (int i in flex)
        {
            double share = flex.Count == 0 ? 0 : left / flex.Count;
            kids[i].Measure(new Size(double.IsInfinity(room) ? double.PositiveInfinity : share, available.Height));
            widths[i] = double.IsInfinity(room) ? kids[i].DesiredSize.Width : share;
            height = Math.Max(height, kids[i].DesiredSize.Height);
        }
        double width = widths.Sum() + gaps;
        if (flex.Count > 0 && !double.IsInfinity(available.Width)) width = available.Width;
        return new Size(width, height);
    }

    /// A view that can show less than its whole width: text that trims (a tail or middle
    /// ellipsis), or a container holding one. Keycaps, glyphs and untrimmed labels cannot.
    public static bool CanShrink(UIElement element) => element switch
    {
        TrimText t => t.Trim != TrimMode.None,
        TextBlock b => b.TextTrimming != TextTrimming.None || b.TextWrapping != TextWrapping.NoWrap,
        Panel p => p.Children.Cast<UIElement>().Any(c => c.Visibility != Visibility.Collapsed && CanShrink(c)),
        Decorator d => d.Child is { } c && CanShrink(c),
        _ => false,
    };

    protected override Size ArrangeOverride(Size final)
    {
        var kids = Visible;
        if (widths.Length != kids.Count) MeasureOverride(final);
        double x = 0;
        double flexTotal = 0;
        double fixedTotal = 0;
        for (int i = 0; i < kids.Count; i++)
        {
            if (GetFlex(kids[i])) flexTotal++;
            else fixedTotal += widths[i];
        }
        double gaps = Math.Max(0, kids.Count - 1) * Spacing;
        double flexWidth = flexTotal == 0 ? 0 : Math.Max(0, final.Width - fixedTotal - gaps) / flexTotal;
        for (int i = 0; i < kids.Count; i++)
        {
            var kid = kids[i];
            double w = GetFlex(kid) ? flexWidth : widths[i];
            double h = Cross == StackCross.Stretch ? final.Height : Math.Min(final.Height, kid.DesiredSize.Height);
            double y = Cross switch
            {
                StackCross.Start or StackCross.Stretch => 0,
                StackCross.End => final.Height - h,
                _ => (final.Height - h) / 2,
            };
            kid.Arrange(new Rect(x, y, Math.Max(0, w), Math.Max(0, h)));
            x += w + Spacing;
        }
        return final;
    }
}

/// SwiftUI's VStack: children top to bottom, `Spacing` apart, each as wide as the stack (its
/// own HorizontalAlignment places it inside). `Flex` children share the height left over.
public class ColumnStack : Panel
{
    public double Spacing { get; set; }

    public ColumnStack() { }

    public ColumnStack(double spacing, params UIElement?[] children)
    {
        Spacing = spacing;
        foreach (var child in children) if (child is not null) Children.Add(child);
    }

    private List<UIElement> Visible => InternalChildren.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed).ToList();
    private double[] heights = [];

    protected override Size MeasureOverride(Size available)
    {
        var kids = Visible;
        heights = new double[kids.Count];
        double gaps = Math.Max(0, kids.Count - 1) * Spacing;
        double used = 0, width = 0;
        var flex = new List<int>();
        // RowStack.Priority < 0 marks a child that takes what is left (SwiftUI's negative layoutPriority).
        for (int i = 0; i < kids.Count; i++)
        {
            if (RowStack.GetFlex(kids[i]) || RowStack.GetPriority(kids[i]) < 0) { flex.Add(i); continue; }
            kids[i].Measure(new Size(available.Width, double.PositiveInfinity));
            heights[i] = kids[i].DesiredSize.Height;
            used += heights[i];
            width = Math.Max(width, kids[i].DesiredSize.Width);
        }
        double left = double.IsInfinity(available.Height) ? double.PositiveInfinity : Math.Max(0, available.Height - used - gaps);
        // Shrinking children (priority < 0) measure first, at their own size up to what is left;
        // plain flex children share the rest.
        foreach (int i in flex.Where(i => !RowStack.GetFlex(kids[i])).OrderByDescending(i => RowStack.GetPriority(kids[i])))
        {
            kids[i].Measure(new Size(available.Width, left));
            heights[i] = Math.Min(left, kids[i].DesiredSize.Height);
            if (!double.IsInfinity(left)) left -= heights[i];
            used += heights[i];
            width = Math.Max(width, kids[i].DesiredSize.Width);
        }
        var plain = flex.Where(i => RowStack.GetFlex(kids[i])).ToList();
        foreach (int i in plain)
        {
            double share = double.IsInfinity(left) ? double.PositiveInfinity : left / plain.Count;
            kids[i].Measure(new Size(available.Width, share));
            heights[i] = double.IsInfinity(share) ? kids[i].DesiredSize.Height : share;
            used += heights[i];
            width = Math.Max(width, kids[i].DesiredSize.Width);
        }
        double height = used + gaps;
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var kids = Visible;
        if (heights.Length != kids.Count) MeasureOverride(final);
        double y = 0;
        for (int i = 0; i < kids.Count; i++)
        {
            kids[i].Arrange(new Rect(0, y, final.Width, Math.Max(0, heights[i])));
            y += heights[i] + Spacing;
        }
        return final;
    }
}

/// How a `TrimText` cuts a line that does not fit.
public enum TrimMode { Tail, Middle, None }

/// One line of text in a Theme font that never wraps and, when it does not fit, is cut in the
/// middle ("notch…View.swift") or at the tail with an ellipsis (SwiftUI's
/// `.lineLimit(1).truncationMode(.middle)`). Its full text is its tooltip when cut.
public sealed class TrimText : FrameworkElement
{
    private string text = "";
    private FontSpec font = Theme.Fonts.Caption;
    private Brush foreground = Theme.Brushes.Ink;
    private Brush? highlight;
    private int highlightStart = -1, highlightLength;
    private FormattedText? shown;

    public TrimText() { SnapsToDevicePixels = true; UseLayoutRounding = true; }

    public TrimText(string text, FontSpec font, Brush foreground, TrimMode trim = TrimMode.Tail) : this()
    {
        this.text = text;
        this.font = font;
        this.foreground = foreground;
        Trim = trim;
    }

    public string Text { get => text; set { if (text == value) return; text = value; InvalidateMeasure(); InvalidateVisual(); } }
    public FontSpec Font { get => font; set { font = value; InvalidateMeasure(); InvalidateVisual(); } }
    public Brush Foreground { get => foreground; set { foreground = value; InvalidateVisual(); } }
    public TrimMode Trim { get; set; } = TrimMode.Tail;
    /// Points between characters (the hero's tracking); 0 for every other font.
    public double Tracking { get; set; }

    /// Lights `length` characters from `start` with `brush` behind them (the picker filter's match).
    public void Highlight(int start, int length, Brush? brush)
    {
        highlightStart = start;
        highlightLength = length;
        highlight = brush;
        InvalidateVisual();
    }

    private FormattedText Format(string s)
    {
        var ft = new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, font.Typeface, font.Size,
            foreground, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        return ft;
    }

    private double LineHeight => Format("Ag").Height;

    protected override Size MeasureOverride(Size available)
    {
        var full = Format(text);
        double width = full.WidthIncludingTrailingWhitespace + Math.Max(0, text.Length - 1) * Tracking;
        double w = Trim == TrimMode.None ? width : Math.Min(width, available.Width);
        return new Size(Math.Ceiling(Math.Max(0, w)), Math.Ceiling(LineHeight));
    }

    protected override void OnRender(DrawingContext dc)
    {
        double width = ActualWidth;
        string s = Fit(text, width);
        ToolTip = s == text ? null : text;
        shown = Format(s);
        double y = (ActualHeight - shown.Height) / 2;
        if (highlight is not null && highlightStart >= 0 && s == text && highlightStart + highlightLength <= text.Length)
        {
            var geometry = shown.BuildHighlightGeometry(new Point(0, y), highlightStart, highlightLength);
            if (geometry is not null) dc.DrawGeometry(highlight, null, geometry);
        }
        dc.DrawText(shown, new Point(0, y));
    }

    private string Fit(string s, double width)
    {
        if (Trim == TrimMode.None || Format(s).WidthIncludingTrailingWhitespace <= width + 0.5) return s;
        const string ellipsis = "…";
        int lo = 0, hi = s.Length;
        string best = ellipsis;
        while (lo <= hi)
        {
            int keep = (lo + hi) / 2;
            string candidate = Trim == TrimMode.Middle
                ? s[..((keep + 1) / 2)] + ellipsis + s[(s.Length - keep / 2)..]
                : s[..keep].TrimEnd() + ellipsis;
            if (Format(candidate).WidthIncludingTrailingWhitespace <= width + 0.5) { best = candidate; lo = keep + 1; }
            else hi = keep - 1;
        }
        return best;
    }
}

/// A count that rolls when it changes (SwiftUI's `.contentTransition(.numericText())`): the
/// old text slides out and fades as the new one slides in, up when the number grew, down
/// when it shrank, on `countPop`'s spring. Clipped to its line. Reduce Motion: it just changes.
public sealed class RollingText : Grid
{
    private readonly FontSpec font;
    private Brush foreground;
    private TextBlock current;

    public RollingText(string text, FontSpec font, Brush foreground)
    {
        this.font = font;
        this.foreground = foreground;
        ClipToBounds = true;
        VerticalAlignment = VerticalAlignment.Center;
        current = Make(text);
        Children.Add(current);
    }

    public Brush Foreground
    {
        get => foreground;
        set
        {
            foreground = value;
            foreach (var child in Children.OfType<TextBlock>()) child.Foreground = value;
        }
    }

    public string Text
    {
        get => current.Text;
        set => Roll(value);
    }

    private TextBlock Make(string text)
    {
        var block = Kit.Text(text, font, foreground, TextTrimming.None);
        block.HorizontalAlignment = HorizontalAlignment.Left;
        return block;
    }

    private void Roll(string next)
    {
        if (next == current.Text) return;
        if (!IsLoaded || Theme.Motion.ReduceMotion || current.Text.Length == 0 || next.Length == 0)
        {
            current.Text = next;
            return;
        }
        double direction = Number(next) >= Number(current.Text) ? 1 : -1;
        double distance = font.Size * Theme.Size.CountRollShare * direction;
        var old = current;
        current = Make(next);
        Children.Add(current);
        var spec = Theme.Motion.CountPop;
        var inMove = Transitions.Translate(current);
        Transitions.Snap(inMove, TranslateTransform.YProperty, distance);
        Transitions.Snap(current, OpacityProperty, 0);
        Transitions.Animate(inMove, TranslateTransform.YProperty, spec, 0);
        Transitions.Animate(current, OpacityProperty, spec, 1);
        var outMove = Transitions.Translate(old);
        Transitions.Animate(outMove, TranslateTransform.YProperty, spec, -distance);
        Transitions.Animate(old, OpacityProperty, spec, 0, () => Children.Remove(old));
    }

    /// The first number in `text` ("3 of 4" reads 3, "+38 −6" reads 38), else 0.
    private static double Number(string text)
    {
        int start = -1, end = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (char.IsDigit(text[i])) { if (start < 0) start = i; end = i + 1; }
            else if (start >= 0) break;
        }
        return start < 0 ? 0 : double.Parse(text[start..end], CultureInfo.InvariantCulture);
    }
}

/// A Border whose content is clipped to its rounded shape (`.clipShape(RoundedRectangle)`).
public class RoundedClip : Border
{
    protected override Size ArrangeOverride(Size final)
    {
        var size = base.ArrangeOverride(final);
        var r = CornerRadius.TopLeft;
        var clip = new RectangleGeometry(new Rect(0, 0, size.Width, size.Height), r, r);
        clip.Freeze();
        Clip = clip;
        return size;
    }
}

/// One-line builders for the views.
public static class Kit
{
    /// A text line in `font` and `brush`: no wrapping, tail trimming.
    public static TextBlock Text(string text, FontSpec font, Brush brush, TextTrimming trimming = TextTrimming.CharacterEllipsis)
    {
        var block = new TextBlock
        {
            Text = text,
            Foreground = brush,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = trimming,
            VerticalAlignment = VerticalAlignment.Center,
        };
        font.Apply(block);
        return block;
    }

    /// Wrapping text, at most `maxLines` lines (0: any), cut with an ellipsis.
    public static TextBlock Wrapped(string text, FontSpec font, Brush brush, int maxLines = 0)
    {
        var block = Text(text, font, brush);
        block.TextWrapping = TextWrapping.Wrap;
        if (maxLines > 0)
        {
            block.MaxHeight = Math.Ceiling(font.Size * 1.34 * maxLines);
        }
        return block;
    }

    /// `element` takes what its RowStack / ColumnStack leaves (a Spacer, or maxWidth: .infinity).
    public static T Flex<T>(T element) where T : UIElement
    {
        RowStack.SetFlex(element, true);
        return element;
    }

    /// An empty flexible gap (SwiftUI's `Spacer(minLength:)`).
    public static FrameworkElement Spacer(double minLength = 0) => Flex(new FrameworkElement { MinWidth = minLength });

    /// `element` with `priority` (SwiftUI's `.layoutPriority`); negative in a ColumnStack shrinks first.
    public static T Priority<T>(T element, int priority) where T : UIElement
    {
        RowStack.SetPriority(element, priority);
        return element;
    }

    /// A rounded fill behind `child` (a background RoundedRectangle).
    public static Border Box(UIElement? child, Brush? fill, double radius, Thickness padding = default)
        => new() { Child = child, Background = fill, CornerRadius = new CornerRadius(radius), Padding = padding, SnapsToDevicePixels = true };

    /// Calls `action` on a left click (press and release inside), with the hand cursor.
    public static T OnClick<T>(T element, Action action) where T : UIElement
    {
        bool down = false;
        element.MouseLeftButtonDown += (_, e) => { down = true; element.CaptureMouse(); e.Handled = true; };
        element.MouseLeftButtonUp += (_, e) =>
        {
            if (!down) return;
            down = false;
            element.ReleaseMouseCapture();
            if (element is FrameworkElement fe)
            {
                var p = e.GetPosition(fe);
                if (p.X < 0 || p.Y < 0 || p.X > fe.ActualWidth || p.Y > fe.ActualHeight) return;
            }
            if (element.IsEnabled) action();
            e.Handled = true;
        };
        element.LostMouseCapture += (_, _) => down = false;
        if (element is FrameworkElement f) f.Cursor = Cursors.Hand;
        return element;
    }

    /// Fill, so the whole box takes the mouse (SwiftUI's `.contentShape(Rectangle())`).
    public static readonly Brush HitFill = MakeHitFill();
    private static Brush MakeHitFill()
    {
        var b = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
        b.Freeze();
        return b;
    }

    /// A hairline or other thin rule.
    public static Border Rule(Brush brush, double width = double.NaN, double height = double.NaN)
        => new() { Background = brush, Width = width, Height = height };
}
