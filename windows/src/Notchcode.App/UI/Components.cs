// Components.cs
// Port of Sources/notchcode/UI/Components.swift: the small shared views, plus the two layout
// pieces SwiftUI gave for free and WPF lacks (`HStack` with spacing and layout priority, and
// `TextLine`: one line of text that truncates at the end or in the middle). Every value
// comes from Theme. Views are code-built FrameworkElements so other tools can compose them.

using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Notchcode.Notch;
using Notchcode.State;
using Path = System.Windows.Shapes.Path;

namespace Notchcode.UI;

// MARK: - Layout

/// SwiftUI's `HStack(spacing:)`: children left to right, centred vertically, `Spacing` apart.
/// When they do not fit, children marked with `LayoutPriority` (or any `TextLine`) shrink:
/// the highest priority claims its room first, as `.layoutPriority` does; the rest keep
/// their natural width. Collapsed children take no room and no spacing.
public class HStack : Panel
{
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(HStack),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    /// `.layoutPriority(n)`; null (unset) means the child keeps its natural width.
    public static readonly DependencyProperty LayoutPriorityProperty = DependencyProperty.RegisterAttached(
        "LayoutPriority", typeof(double?), typeof(HStack),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsParentMeasure));

    public static double? GetLayoutPriority(DependencyObject d) => (double?)d.GetValue(LayoutPriorityProperty);
    public static void SetLayoutPriority(DependencyObject d, double? value) => d.SetValue(LayoutPriorityProperty, value);

    public double Spacing
    {
        get => (double)GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    public HStack() { }

    public HStack(double spacing, params UIElement?[] children)
    {
        Spacing = spacing;
        foreach (var child in children) if (child is not null) Children.Add(child);
    }

    private double?[] priorities = [];
    private double[] widths = [];

    /// `.fixedSize()`: the child keeps its natural width even when it is a `TextLine`.
    public static readonly DependencyProperty FixedProperty = DependencyProperty.RegisterAttached(
        "Fixed", typeof(bool), typeof(HStack),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsParentMeasure));

    public static bool GetFixed(DependencyObject d) => (bool)d.GetValue(FixedProperty);
    public static void SetFixed(DependencyObject d, bool value) => d.SetValue(FixedProperty, value);

    private static double? PriorityOf(UIElement child)
        => GetFixed(child) ? null : GetLayoutPriority(child) ?? (child is TextLine ? 0 : null);

    protected override Size MeasureOverride(Size available)
    {
        var shown = Children.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed).ToList();
        widths = new double[Children.Count];
        priorities = new double?[Children.Count];
        double spacing = Spacing * Math.Max(0, shown.Count - 1);
        double fixedWidth = 0, height = 0;
        var flexible = new List<(UIElement Child, int Index, double Priority)>();
        for (int i = 0; i < Children.Count; i++)
        {
            var child = Children[i];
            if (child.Visibility == Visibility.Collapsed) { child.Measure(new Size(0, 0)); continue; }
            priorities[i] = PriorityOf(child);
            if (priorities[i] is double p) { flexible.Add((child, i, p)); continue; }
            child.Measure(new Size(double.PositiveInfinity, available.Height));
            widths[i] = child.DesiredSize.Width;
            fixedWidth += widths[i];
            height = Math.Max(height, child.DesiredSize.Height);
        }
        double left = double.IsInfinity(available.Width) ? double.PositiveInfinity : Math.Max(0, available.Width - fixedWidth - spacing);
        // Highest priority first; equal priorities share what is left evenly.
        foreach (var group in flexible.GroupBy(f => f.Priority).OrderByDescending(g => g.Key))
        {
            var members = group.ToList();
            // Natural widths first, so a short one does not take more than it needs.
            foreach (var m in members) m.Child.Measure(new Size(double.PositiveInfinity, available.Height));
            var ordered = members.OrderBy(m => m.Child.DesiredSize.Width).ToList();
            for (int k = 0; k < ordered.Count; k++)
            {
                var m = ordered[k];
                double share = double.IsInfinity(left) ? double.PositiveInfinity : left / (ordered.Count - k);
                double natural = m.Child.DesiredSize.Width;
                if (natural > share) m.Child.Measure(new Size(share, available.Height));
                widths[m.Index] = Math.Min(m.Child.DesiredSize.Width, share);
                if (!double.IsInfinity(left)) left = Math.Max(0, left - widths[m.Index]);
                height = Math.Max(height, m.Child.DesiredSize.Height);
            }
        }
        double total = widths.Sum() + spacing;
        return new Size(total, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0;
        bool first = true;
        for (int i = 0; i < Children.Count; i++)
        {
            var child = Children[i];
            if (child.Visibility == Visibility.Collapsed) continue;
            if (!first) x += Spacing;
            first = false;
            double w = i < widths.Length ? widths[i] : child.DesiredSize.Width;
            double h = child.DesiredSize.Height;
            child.Arrange(new Rect(x, (finalSize.Height - h) / 2, w, h));
            x += w;
        }
        return finalSize;
    }
}

/// How a `TextLine` cuts text that does not fit.
public enum Truncation { Tail, Middle, Head, None }

/// One line of text in a Theme font: `.lineLimit(1)` with `.truncationMode(.tail)` or
/// `.middle`. Its natural width is the whole text; given less, it cuts with "…".
public sealed class TextLine : FrameworkElement
{
    private readonly TextBlock block = new() { TextWrapping = TextWrapping.NoWrap };
    private string text = "";
    private FontSpec font = Theme.Fonts.Caption;

    public TextLine(string text, FontSpec font, Brush foreground, Truncation truncation = Truncation.Tail)
    {
        this.text = text;
        this.font = font;
        font.Apply(block);
        block.Foreground = foreground;
        block.Text = text;
        Truncation = truncation;
        AddVisualChild(block);
        AddLogicalChild(block);
        VerticalAlignment = VerticalAlignment.Center;
    }

    public Truncation Truncation { get; set; }

    public string Text
    {
        get => text;
        set
        {
            if (text == value) return;
            text = value;
            block.Text = value;
            InvalidateMeasure();
        }
    }

    public Brush Foreground
    {
        get => block.Foreground;
        set => block.Foreground = value;
    }

    public FontSpec Font
    {
        get => font;
        set
        {
            font = value;
            font.Apply(block);
            InvalidateMeasure();
        }
    }

    protected override int VisualChildrenCount => 1;
    protected override Visual GetVisualChild(int index) => block;

    protected override Size MeasureOverride(Size available)
    {
        double full = font.Measure(text);
        string shown = text;
        if (Truncation != Truncation.None && full > available.Width + 0.5)
            shown = Fit(text, available.Width);
        if (block.Text != shown) block.Text = shown;
        block.Measure(new Size(double.PositiveInfinity, available.Height));
        return new Size(Math.Min(block.DesiredSize.Width, available.Width), block.DesiredSize.Height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        block.Arrange(new Rect(0, 0, Math.Max(finalSize.Width, block.DesiredSize.Width), finalSize.Height));
        return finalSize;
    }

    /// The longest cut of `value` (with "…") that fits `width`.
    private string Fit(string value, double width)
    {
        const string ellipsis = "…";
        if (width <= font.Measure(ellipsis)) return "";
        int lo = 0, hi = value.Length;
        string best = ellipsis;
        while (lo <= hi)
        {
            int keep = (lo + hi) / 2;
            string candidate = Cut(value, keep, ellipsis);
            if (font.Measure(candidate) <= width) { best = candidate; lo = keep + 1; }
            else hi = keep - 1;
        }
        return best;
    }

    private string Cut(string value, int keep, string ellipsis) => Truncation switch
    {
        Truncation.Middle => value[..((keep + 1) / 2)] + ellipsis + value[(value.Length - keep / 2)..],
        Truncation.Head => ellipsis + value[(value.Length - keep)..],
        _ => value[..keep].TrimEnd() + ellipsis,
    };
}

/// A view that follows `AppState`: it calls `Update` once per dispatcher turn after any
/// published property changed, while it is in the tree. Subclasses rebuild only what moved.
public abstract class StateView : Grid
{
    protected readonly AppState State;
    private bool scheduled;
    private bool subscribed;

    protected StateView(AppState state)
    {
        State = state;
        Loaded += (_, _) => Subscribe();
        Unloaded += (_, _) => Unsubscribe();
    }

    private void Subscribe()
    {
        if (subscribed) return;
        subscribed = true;
        State.PropertyChanged += OnStateChanged;
        Update();
    }

    private void Unsubscribe()
    {
        if (!subscribed) return;
        subscribed = false;
        State.PropertyChanged -= OnStateChanged;
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (scheduled) return;
        scheduled = true;
        Dispatcher.BeginInvoke(DispatcherPriority.DataBind, () =>
        {
            scheduled = false;
            if (subscribed) Update();
        });
    }

    /// Brings the view in line with the state.
    protected abstract void Update();
}

/// Small helpers for building views in code.
public static class Ui
{
    /// A one-line text in `font` and `brush`.
    public static TextLine Text(string text, FontSpec font, Brush brush, Truncation truncation = Truncation.Tail)
        => new(text, font, brush, truncation);

    /// A plain TextBlock (wrapping allowed) in `font` and `brush`.
    public static TextBlock Block(string text, FontSpec font, Brush brush, TextWrapping wrapping = TextWrapping.NoWrap)
    {
        var block = new TextBlock { Text = text, Foreground = brush, TextWrapping = wrapping, VerticalAlignment = VerticalAlignment.Center };
        font.Apply(block);
        return block;
    }

    /// `.layoutPriority(p)` inside an `HStack`.
    public static T Priority<T>(this T element, double priority) where T : UIElement
    {
        HStack.SetLayoutPriority(element, priority);
        return element;
    }

    /// `.fixedSize()` inside an `HStack`: never shrinks.
    public static T Fixed<T>(this T element) where T : UIElement
    {
        HStack.SetFixed(element, true);
        if (element is TextLine line) line.Truncation = Truncation.None;
        return element;
    }

    /// A rounded rectangle path ("RoundedRectangle(cornerRadius:style: .continuous)").
    public static Border Rounded(Brush? fill, double radius, double width = double.NaN, double height = double.NaN)
        => new() { Background = fill, CornerRadius = new CornerRadius(radius), Width = width, Height = height };

    /// A capsule (fully rounded) border of `height`.
    public static Border Capsule(Brush? fill, double height)
        => new() { Background = fill, CornerRadius = new CornerRadius(height / 2), Height = height };

    /// Calls `action` on a left click (press and release inside), as SwiftUI's `onTapGesture`.
    public static T OnTap<T>(this T element, Action action) where T : UIElement
    {
        bool pressed = false;
        element.MouseLeftButtonDown += (_, e) => { pressed = true; e.Handled = true; };
        element.MouseLeftButtonUp += (_, e) =>
        {
            if (!pressed) return;
            pressed = false;
            e.Handled = true;
            action();
        };
        element.MouseLeave += (_, _) => pressed = false;
        if (element is Panel panel && panel.Background is null) panel.Background = Theme.Brushes.HitTarget;
        if (element is Border border && border.Background is null) border.Background = Theme.Brushes.HitTarget;
        return element;
    }

    /// `.help(text)`: a tooltip.
    public static T Help<T>(this T element, string text) where T : FrameworkElement
    {
        element.ToolTip = text;
        return element;
    }
}

/// "Open in Windows Terminal ↗" text link.
public sealed class TeleportLink : Border
{
    public TeleportLink(string title, Action action)
    {
        Background = Theme.Brushes.HitTarget;
        Cursor = Cursors.Hand;
        Child = new HStack(Theme.Size.SpaceXS,
            Ui.Text(title, Theme.Fonts.CaptionMedium, Theme.Brushes.InkSecondary).Fixed(),
            Theme.Symbols.Teleport.ToPath(Theme.Fonts.CaptionSize * 0.8, Theme.Brushes.InkSecondary));
        this.OnTap(action);
    }
}

// MARK: - Containers

/// The inset fill around a group, with the pane parallax. `fillsHeight` stretches it to the
/// room it is given, content at the top (the Usage tiles, at the tile radius).
public sealed class InsetGroup : Border
{
    public InsetGroup(UIElement content, double radius = Theme.Radius.Inset, bool fillsHeight = false,
        double verticalPadding = Theme.Size.InsetPadding)
    {
        Child = content;
        Padding = new Thickness(Theme.Size.InsetPadding, verticalPadding, Theme.Size.InsetPadding, verticalPadding);
        Background = Theme.Brushes.Inset;
        CornerRadius = new CornerRadius(radius);
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = fillsHeight ? VerticalAlignment.Stretch : VerticalAlignment.Top;
        Transitions.SetParallaxGroup(this, true);
    }
}

public static class Boxes
{
    /// The snippet box around a diff, the Files preview or rendered Markdown: the inset fill
    /// at the snippet radius, the content clipped to it.
    public static Border SnippetBox(UIElement content)
    {
        var border = new Border
        {
            Child = content,
            Background = Theme.Brushes.Inset,
            CornerRadius = new CornerRadius(Theme.Radius.Snippet),
        };
        ClipToRounded(border, Theme.Radius.Snippet);
        return border;
    }

    /// A small capsule behind a label: tags, count pills, the tree's ± badges.
    public static Border CapsuleTag(UIElement label, Brush? fill = null, double hPadding = Theme.Size.SmallPillHPadding,
        double height = Theme.Size.SmallPillHeight)
        => new()
        {
            Child = label,
            Background = fill ?? Theme.Brushes.DoneChipFill,
            Padding = new Thickness(hPadding, 0, hPadding, 0),
            Height = height,
            CornerRadius = new CornerRadius(height / 2),
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// Clips `element` to a rounded rectangle of its own size, kept current as it resizes.
    public static void ClipToRounded(FrameworkElement element, double radius)
    {
        void Apply()
        {
            var clip = new RectangleGeometry(new Rect(0, 0, element.ActualWidth, element.ActualHeight), radius, radius);
            clip.Freeze();
            element.Clip = clip;
        }
        element.SizeChanged += (_, _) => Apply();
    }
}

/// The header row of every state: a left wing, the camera gap, a right wing. Nothing is
/// ever drawn in the centre notch width. Each wing is clipped to its slot.
public sealed class WingRow : Grid
{
    public Border LeftWing { get; }
    public Border RightWing { get; }

    public WingRow(NotchLayout layout, double bodyWidth, UIElement? left, UIElement? right)
    {
        double wing = layout.WingWidth(bodyWidth);
        Width = bodyWidth;
        Height = layout.NotchHeight;
        Margin = new Thickness(0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.SidePadding) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(wing) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(layout.NotchWidth + 2 * Theme.Size.WingInnerGap) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(wing) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Theme.Size.SidePadding) });

        LeftWing = new Border
        {
            Child = left,
            Padding = new Thickness(Theme.Size.WingEdgeInset, 0, 0, 0),
            ClipToBounds = true,
            Height = layout.NotchHeight,
        };
        if (left is FrameworkElement l) { l.HorizontalAlignment = HorizontalAlignment.Left; l.VerticalAlignment = VerticalAlignment.Center; }
        RightWing = new Border
        {
            Child = right,
            Padding = new Thickness(0, 0, Theme.Size.WingEdgeInset, 0),
            ClipToBounds = true,
            Height = layout.NotchHeight,
        };
        if (right is FrameworkElement r) { r.HorizontalAlignment = HorizontalAlignment.Right; r.VerticalAlignment = VerticalAlignment.Center; }
        SetColumn(LeftWing, 1);
        SetColumn(RightWing, 3);
        Children.Add(LeftWing);
        Children.Add(RightWing);
    }
}

/// A short tertiary line for empty tabs and panes, centred in the room it has.
public sealed class EmptyNote : Grid
{
    public EmptyNote(string text, FontSpec? font = null)
    {
        var block = Ui.Block(text, font ?? Theme.Fonts.Body, Theme.Brushes.InkTertiary, TextWrapping.Wrap);
        block.HorizontalAlignment = HorizontalAlignment.Center;
        block.TextAlignment = TextAlignment.Center;
        Children.Add(block);
    }
}

// MARK: - Bars and rings

/// A capsule track with a filled share.
public sealed class UsageBar : Grid
{
    private readonly Border fill;
    private double fraction;

    public UsageBar(double fraction, Brush? tint = null)
    {
        Height = Theme.Size.BarHeight;
        Children.Add(Ui.Capsule(Theme.Brushes.Track, Theme.Size.BarHeight));
        fill = Ui.Capsule(tint ?? Theme.Brushes.Ink, Theme.Size.BarHeight);
        fill.HorizontalAlignment = HorizontalAlignment.Left;
        Children.Add(fill);
        Fraction = fraction;
        SizeChanged += (_, _) => Layout();
    }

    public double Fraction
    {
        get => fraction;
        set { fraction = Math.Clamp(value, 0, 1); Layout(); }
    }

    public Brush Tint { set => fill.Background = value; }

    private void Layout() => fill.Width = ActualWidth * fraction;
}

/// The countdown ring: a track and the attention arc from the top, clockwise.
public sealed class CountdownRing : Grid
{
    private readonly Path arc;
    private readonly double size;

    public CountdownRing(double fraction, double size = Theme.Size.CountdownRing)
    {
        this.size = size;
        Width = size;
        Height = size;
        Children.Add(new Ellipse { Stroke = Theme.Brushes.Track, StrokeThickness = Theme.Size.CountdownLine, Width = size, Height = size });
        arc = new Path
        {
            Stroke = Theme.Brushes.Attention,
            StrokeThickness = Theme.Size.CountdownLine,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        Children.Add(arc);
        Fraction = fraction;
    }

    public double Fraction
    {
        set
        {
            double f = Math.Clamp(value, 0, 1);
            double r = (size - Theme.Size.CountdownLine) / 2;
            var c = new Point(size / 2, size / 2);
            if (f <= 0) { arc.Data = null; return; }
            if (f >= 0.9999) { arc.Data = new EllipseGeometry(c, r, r); return; }
            double start = Theme.Motion.RingStartDegrees * Math.PI / 180;
            double end = start + f * 2 * Math.PI;
            var a = new Point(c.X + r * Math.Cos(start), c.Y + r * Math.Sin(start));
            var b = new Point(c.X + r * Math.Cos(end), c.Y + r * Math.Sin(end));
            var figure = new PathFigure { StartPoint = a, IsFilled = false };
            figure.Segments.Add(new ArcSegment(b, new Size(r, r), 0, f > 0.5, SweepDirection.Clockwise, true));
            var geometry = new PathGeometry(new[] { figure });
            geometry.Freeze();
            arc.Data = geometry;
        }
    }
}

/// Seconds left and the share of time left on a request, read from its deadline (the
/// remaining/remainingFraction of RequestActions.swift, kept here so the shell does not
/// depend on Features/Requests).
public static class DeadlineMath
{
    public static double Left(PendingRequest request, DateTime now) => Math.Max(0, (request.Deadline - now).TotalSeconds);

    public static double Share(PendingRequest request, DateTime now)
        => Left(request, now) / Math.Max(1, (request.Deadline - request.ReceivedAt).TotalSeconds);
}

/// `RequestTimeline`: calls `tick(fraction, remaining)` every rendered frame while the element
/// is loaded, read from the request's deadline, so countdowns stay right even after the app
/// was busy. Reduce Motion: once a second.
public sealed class RequestTicker
{
    private readonly FrameworkElement owner;
    private readonly PendingRequest request;
    private readonly Action<double, double> tick;
    private DispatcherTimer? timer;
    private bool rendering;

    public RequestTicker(FrameworkElement owner, PendingRequest request, Action<double, double> tick)
    {
        this.owner = owner;
        this.request = request;
        this.tick = tick;
        owner.Loaded += (_, _) => Start();
        owner.Unloaded += (_, _) => Stop();
        Fire();
    }

    private void Fire()
    {
        var now = DateTime.UtcNow;
        tick(DeadlineMath.Share(request, now), DeadlineMath.Left(request, now));
    }

    private void Start()
    {
        Fire();
        if (Theme.Motion.ReduceMotion)
        {
            timer ??= new DispatcherTimer(TimeSpan.FromSeconds(Theme.Timing.ClockTick), DispatcherPriority.Render, (_, _) => Fire(), owner.Dispatcher);
            timer.Start();
        }
        else if (!rendering)
        {
            rendering = true;
            CompositionTarget.Rendering += OnRendering;
        }
    }

    private void Stop()
    {
        timer?.Stop();
        if (rendering)
        {
            rendering = false;
            CompositionTarget.Rendering -= OnRendering;
        }
    }

    private void OnRendering(object? sender, EventArgs e) => Fire();
}

/// Ring plus "0:53" until the request's deadline.
public sealed class DeadlineCountdown : HStack
{
    public DeadlineCountdown(PendingRequest request, double ringSize = Theme.Size.CountdownRing, FontSpec? font = null)
    {
        Spacing = Theme.Size.SpaceS;
        var ring = new CountdownRing(1, ringSize);
        var clock = Ui.Text("", font ?? Theme.Fonts.CaptionMedium, Theme.Brushes.AttentionText).Fixed();
        Children.Add(ring);
        Children.Add(clock);
        string last = "";
        _ = new RequestTicker(this, request, (fraction, remaining) =>
        {
            ring.Fraction = fraction;
            string text = Format.Clock(remaining);
            if (text != last) { last = text; clock.Text = text; }
        });
    }
}

/// Elapsed "m:ss" since a date in tertiary (or `brush`), ticking once a second.
public sealed class ElapsedText : Border
{
    public ElapsedText(DateTime since, Brush? brush = null)
    {
        var text = Ui.Text(Format.Clock((DateTime.UtcNow - since).TotalSeconds), Theme.Fonts.Caption, brush ?? Theme.Brushes.InkTertiary).Fixed();
        Child = text;
        var timer = new DispatcherTimer(TimeSpan.FromSeconds(Theme.Timing.ClockTick), DispatcherPriority.Render,
            (_, _) => text.Text = Format.Clock((DateTime.UtcNow - since).TotalSeconds), Dispatcher);
        Loaded += (_, _) => timer.Start();
        Unloaded += (_, _) => timer.Stop();
    }
}

/// Text cut after `lines` lines with a fade over the end of the last one instead of an
/// ellipsis, so a cut line reads as cut, not ended. Text that fits shows whole, no fade.
public sealed class FadeText : Border
{
    private readonly TextBlock block;
    private readonly int lines;

    public FadeText(string text, FontSpec font, Brush brush, int lines = 1)
    {
        this.lines = Math.Max(1, lines);
        block = Ui.Block(text, font, brush, TextWrapping.Wrap);
        block.VerticalAlignment = VerticalAlignment.Top;
        Child = block;
        ClipToBounds = true;
        SizeChanged += (_, _) => ApplyFade();
    }

    protected override Size MeasureOverride(Size constraint)
    {
        block.Measure(new Size(constraint.Width, double.PositiveInfinity));
        double line = block.FontFamily.LineSpacing * block.FontSize;
        double cap = line * lines;
        return new Size(Math.Min(block.DesiredSize.Width, constraint.Width), Math.Min(block.DesiredSize.Height, cap));
    }

    private void ApplyFade()
    {
        double line = block.FontFamily.LineSpacing * block.FontSize;
        bool cut = block.DesiredSize.Height > line * lines + 1;
        if (!cut || ActualWidth <= 0) { OpacityMask = null; return; }
        // Opaque everywhere except the last line's end, which fades out over `ChangesFadeWidth`.
        var mask = new DrawingGroup();
        double w = ActualWidth, h = ActualHeight, fade = Theme.Size.ChangesFadeWidth;
        mask.Children.Add(new GeometryDrawing(System.Windows.Media.Brushes.Black, null, new RectangleGeometry(new Rect(0, 0, w, Math.Max(0, h - line)))));
        mask.Children.Add(new GeometryDrawing(System.Windows.Media.Brushes.Black, null, new RectangleGeometry(new Rect(0, h - line, Math.Max(0, w - fade), line))));
        var gradient = new LinearGradientBrush(System.Windows.Media.Colors.Black, System.Windows.Media.Colors.Transparent, 0);
        mask.Children.Add(new GeometryDrawing(gradient, null, new RectangleGeometry(new Rect(Math.Max(0, w - fade), h - line, fade, line))));
        var brush = new DrawingBrush(mask) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top, ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, w, h), ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, w, h) };
        brush.Freeze();
        OpacityMask = brush;
    }
}

// MARK: - Diff pieces

/// Five small cells, green and red in proportion to added and removed.
public sealed class DiffCells : HStack
{
    public DiffCells(int added, int removed)
    {
        Spacing = Theme.Size.DiffCellSpacing;
        int cells = Theme.Limits.DiffCellCount;
        int total = added + removed;
        int greens = total == 0 ? 0 : (int)Math.Round((double)added / total * cells, MidpointRounding.AwayFromZero);
        int reds = total == 0 ? 0 : cells - greens;
        for (int i = 0; i < cells; i++)
        {
            var fill = i < greens ? Theme.Brushes.Green : i < greens + reds ? Theme.Brushes.Red : Theme.Brushes.CellEmpty;
            Children.Add(Ui.Rounded(fill, Theme.Radius.DiffCell, Theme.Size.DiffCellWidth, Theme.Size.DiffCellHeight));
        }
    }
}

/// "+12 −3" in mono, at the caption size.
public sealed class DiffCounts : HStack
{
    public DiffCounts(int added, int removed)
    {
        Spacing = Theme.Size.SpaceS;
        Children.Add(Ui.Text(Format.Added(added), Theme.Fonts.MonoCaption, Theme.Brushes.Green).Fixed());
        Children.Add(Ui.Text(Format.Removed(removed), Theme.Fonts.MonoCaption, Theme.Brushes.Red).Fixed());
    }
}

/// An integer that counts through every value while it animates ("+0" … "+48").
public sealed class CountingText : Border
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(CountingText), new PropertyMetadata(0.0, (d, _) => ((CountingText)d).Render()));

    private readonly TextLine text;
    private readonly Func<int, string> format;

    public CountingText(double value, Func<int, string> format, FontSpec font, Brush brush)
    {
        this.format = format;
        text = Ui.Text(format((int)Math.Round(value)), font, brush).Fixed();
        Child = text;
        Value = value;
    }

    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    private void Render() => text.Text = format((int)Math.Round(Value, MidpointRounding.AwayFromZero));
}

/// "+12" in a small tinted capsule. `countsUp`: the number counts up from 0 when it appears
/// (done peek); Reduce Motion: it is there at once.
public sealed class CountPill : Border
{
    public CountPill(int count, Func<int, string> format, Brush tint, Brush fill, bool countsUp = false)
    {
        var counting = new CountingText(countsUp ? 0 : count, format, Theme.Fonts.MonoCaption, tint);
        Child = Boxes.CapsuleTag(counting, fill);
        VerticalAlignment = VerticalAlignment.Center;
        if (!countsUp) return;
        Loaded += (_, _) =>
        {
            if (Theme.Motion.ReduceMotion) { counting.Value = count; return; }
            Transitions.Animate(counting, CountingText.ValueProperty, Theme.Motion.CountUp, count);
        };
    }
}

/// Tool name chip ("Bash") on the permission card.
public sealed class ToolChip : Border
{
    public ToolChip(string tool)
    {
        Child = Ui.Text(tool, Theme.Fonts.MonoSmall, Theme.Brushes.InkSecondary).Fixed();
        Padding = new Thickness(Theme.Size.ChipHPadding, 0, Theme.Size.ChipHPadding, 0);
        Height = Theme.Size.ChipHeight;
        Background = Theme.Brushes.Inset;
        CornerRadius = new CornerRadius(Theme.Radius.Chip);
        VerticalAlignment = VerticalAlignment.Center;
    }
}

// MARK: - Subagents

/// A subagent's colour square. The colour is stable per agent within its session.
public sealed class AgentSquare : Border
{
    public AgentSquare(int colorIndex, bool finished = false)
    {
        Width = Theme.Size.AgentSquare;
        Height = Theme.Size.AgentSquare;
        CornerRadius = new CornerRadius(Theme.Radius.AgentSquare);
        Background = Theme.Brushes.Agent(colorIndex);
        Opacity = finished ? Theme.Opacity.AgentFinished : 1;
        VerticalAlignment = VerticalAlignment.Center;
    }
}

// MARK: - Hints

/// A one-line hint that appears for a moment ("No terminal found").
public sealed class HintText : Border
{
    public HintText(string? text)
    {
        if (text is null) return;
        Child = Ui.Text(text, Theme.Fonts.CaptionMedium, Theme.Brushes.AttentionText);
        Loaded += (_, _) => Transitions.FadeIn(this);
    }
}

// MARK: - Placeholder

/// A centred caption standing in for a pane another wave builds ("Sessions pane · wave 1c").
public sealed class PlaceholderPane : Grid
{
    public PlaceholderPane(string caption)
    {
        var block = Ui.Block(caption, Theme.Fonts.Caption, Theme.Brushes.PlaceholderText);
        block.HorizontalAlignment = HorizontalAlignment.Center;
        block.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(block);
    }
}
