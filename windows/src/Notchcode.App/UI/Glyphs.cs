// Glyphs.cs
// Drawn glyphs: Claude's sparkle, the breathing triangle, circles and status dots, the
// session state glyph, the done check, and the strip's tool icons. On macOS most of these
// were SF Symbols; Windows has none, so each is drawn here as a path in a 24 × 24 box
// (the tool canvas's box) and scaled to the size it is shown at.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Notchcode.Core;
using Path = System.Windows.Shapes.Path;

namespace Notchcode.UI;

/// A glyph in the 24 × 24 box: filled, or stroked with round caps and joins at
/// `StrokeRatio` × its size.
public sealed record GlyphSpec(Geometry Geometry, bool Filled, double StrokeRatio)
{
    /// The geometry scaled from the 24 box to `size` × `size`, frozen.
    public Geometry At(double size) => GlyphShapes.Scaled(Geometry, size);

    /// A WPF `Path` drawing the glyph at `size` in `brush`.
    public Path ToPath(double size, Brush brush)
    {
        var path = new Path
        {
            Data = At(size),
            Width = size,
            Height = size,
            Stretch = Stretch.None,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            SnapsToDevicePixels = false,
        };
        if (Filled) path.Fill = brush;
        else
        {
            path.Stroke = brush;
            path.StrokeThickness = size * StrokeRatio;
        }
        return path;
    }
}

/// The drawn stand-ins for the SF Symbols named in `Theme.Symbols`, and the done check.
public static class GlyphShapes
{
    public const double Box = 24;

    /// The SF Symbols were drawn semibold; a stroked stand-in uses this share of its size
    /// (2.6 in the 24 box), a hair heavier than the tool icons' 2.4. Port's choice.
    public const double SymbolStrokeRatio = 2.6 / 24;

    /// "sparkle": a four-point star with concave sides, filled.
    public static readonly GlyphSpec Sparkle = new(Svg(
        "M12 1C12.9 7.6 16.4 11.1 23 12C16.4 12.9 12.9 16.4 12 23C11.1 16.4 7.6 12.9 1 12C7.6 11.1 11.1 7.6 12 1Z"),
        Filled: true, 0);

    /// "exclamationmark.triangle.fill": a rounded triangle with the exclamation knocked out
    /// (even-odd fill).
    public static readonly GlyphSpec AttentionTriangle = new(Svg(
        "M10.3 3.9C11.1 2.6 12.9 2.6 13.7 3.9L22.2 18.6C23 20 22 21.5 20.5 21.5H3.5C2 21.5 1 20 1.8 18.6Z"
        + "M10.9 9.1A1.1 1.1 0 0 1 13.1 9.1V14.1A1.1 1.1 0 0 1 10.9 14.1Z"
        + "M10.7 17.8A1.3 1.3 0 1 0 13.3 17.8A1.3 1.3 0 1 0 10.7 17.8Z"),
        Filled: true, 0);

    /// "questionmark".
    public static readonly GlyphSpec QuestionMark = new(Svg(
        "M8.5 8.5A3.5 3.5 0 1 1 13.7 11.6C12.7 12.2 12 12.9 12 14.2V15 M12 19h.01"),
        Filled: false, SymbolStrokeRatio);

    /// "checkmark".
    public static readonly GlyphSpec Checkmark = new(Svg("M4.5 12.5l5 5L19.5 6.5"), Filled: false, SymbolStrokeRatio);

    /// "arrow.up.right".
    public static readonly GlyphSpec ArrowUpRight = new(Svg("M7 17L17 7 M8 7h9v9"), Filled: false, SymbolStrokeRatio);

    /// "chevron.right".
    public static readonly GlyphSpec ChevronRight = new(Svg("M9 5l7 7-7 7"), Filled: false, SymbolStrokeRatio);

    /// "chevron.left".
    public static readonly GlyphSpec ChevronLeft = new(Svg("M15 5l-7 7 7 7"), Filled: false, SymbolStrokeRatio);

    /// "plusminus".
    public static readonly GlyphSpec PlusMinus = new(Svg("M12 4v9 M7.5 8.5h9 M7.5 19h9"), Filled: false, SymbolStrokeRatio);

    /// "line.3.horizontal.decrease".
    public static readonly GlyphSpec FilterLines = new(Svg("M4 7h16 M7 12h10 M10 17h4"), Filled: false, SymbolStrokeRatio);

    /// "sidebar.left": a window with the left column ruled off.
    public static readonly GlyphSpec SidebarLeft = new(Combine(RoundedRect(3, 4, 18, 16, 3), Svg("M9.5 4v16")), Filled: false, SymbolStrokeRatio);

    /// "macwindow": a window with its title bar ruled off.
    public static readonly GlyphSpec Window = new(Combine(RoundedRect(3, 4, 18, 16, 3), Svg("M3 9h18")), Filled: false, SymbolStrokeRatio);

    /// "pencil.line": a pencil over a line.
    public static readonly GlyphSpec PencilLine = new(Svg("M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"), Filled: false, SymbolStrokeRatio);

    /// `CheckShape`: the done check (`Theme.Shapes.check`) drawn through its points inside
    /// `rect`, so it can draw on (stroke it, animate a dash offset or a clip).
    public static Geometry Check(Rect rect)
    {
        var points = Theme.Shapes.Check.Select(p => new Point(rect.X + p.X * rect.Width, rect.Y + p.Y * rect.Height)).ToArray();
        var figure = new PathFigure { StartPoint = points[0], IsClosed = false, IsFilled = false };
        foreach (var point in points.Skip(1)) figure.Segments.Add(new LineSegment(point, true));
        var geometry = new PathGeometry(new[] { figure });
        geometry.Freeze();
        return geometry;
    }

    /// The length of the check's polyline in `rect`, for drawing it on with a dash.
    public static double CheckLength(Rect rect)
    {
        var points = Theme.Shapes.Check.Select(p => new Point(p.X * rect.Width, p.Y * rect.Height)).ToArray();
        double length = 0;
        for (int i = 1; i < points.Length; i++) length += (points[i] - points[i - 1]).Length;
        return length;
    }

    // MARK: - Building blocks

    /// `geometry` (in the 24 box) scaled to `size` × `size`, frozen.
    public static Geometry Scaled(Geometry geometry, double size)
    {
        var scaled = geometry.Clone();
        scaled.Transform = new ScaleTransform(size / Box, size / Box);
        scaled.Freeze();
        return scaled;
    }

    /// A circle centred on (x, y).
    public static Geometry Circle(double x, double y, double r)
    {
        var circle = new EllipseGeometry(new Point(x, y), r, r);
        circle.Freeze();
        return circle;
    }

    public static Geometry RoundedRect(double x, double y, double width, double height, double radius)
    {
        var rect = new RectangleGeometry(new Rect(x, y, width, height), radius, radius);
        rect.Freeze();
        return rect;
    }

    /// Every figure of `parts` in one frozen path (even-odd).
    public static Geometry Combine(params Geometry[] parts)
    {
        var path = new PathGeometry { FillRule = FillRule.EvenOdd };
        foreach (var part in parts) path.AddGeometry(part);
        path.Freeze();
        return path;
    }

    /// Parses the SVG path commands the canvas uses: M L H V C A Z, absolute or relative.
    /// Arcs are circular (rx = ry, no rotation), which is all Lucide draws. A port of
    /// `ToolShapes.svg` in Glyphs.swift: the same tokeniser and the same commands; an arc
    /// becomes a WPF `ArcSegment` with SVG's own flags (sweep 1 is clockwise on screen, and
    /// WPF grows a radius too small for the chord just as the Swift code does).
    public static Geometry Svg(string d)
    {
        var groups = new List<(char Command, List<double> Numbers)>();
        int i = 0;
        while (i < d.Length)
        {
            char c = d[i];
            if (char.IsLetter(c))
            {
                groups.Add((c, new List<double>()));
                i++;
            }
            else if (c == '-' || c == '.' || char.IsDigit(c))
            {
                int j = i + 1;
                bool seenDot = c == '.';
                while (j < d.Length)
                {
                    char n = d[j];
                    if (char.IsDigit(n)) { j++; continue; }
                    if (n == '.' && !seenDot) { seenDot = true; j++; continue; }
                    break;
                }
                if (double.TryParse(d.AsSpan(i, j - i), System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out double value) && groups.Count > 0)
                    groups[^1].Numbers.Add(value);
                i = j;
            }
            else
            {
                i++;
            }
        }

        var geometry = new PathGeometry { FillRule = FillRule.EvenOdd };
        PathFigure? figure = null;
        var current = new Point(0, 0);
        var start = new Point(0, 0);

        PathFigure Open()
        {
            if (figure is null || figure.IsClosed)
            {
                // Drawing after Z (or before any M) starts a new subpath at the current point.
                figure = new PathFigure { StartPoint = current, IsFilled = true };
                geometry.Figures.Add(figure);
            }
            return figure;
        }

        foreach (var (cmd, values) in groups)
        {
            char command = cmd;
            var numbers = new Queue<double>(values);
            double Next() => numbers.Count == 0 ? 0 : numbers.Dequeue();
            bool relative = char.IsLower(command);
            do
            {
                Point o = relative ? current : new Point(0, 0);
                switch (char.ToUpperInvariant(command))
                {
                    case 'M':
                        current = new Point(o.X + Next(), o.Y + Next());
                        figure = new PathFigure { StartPoint = current, IsFilled = true };
                        geometry.Figures.Add(figure);
                        start = current;
                        command = relative ? 'l' : 'L';
                        break;
                    case 'L':
                        current = new Point(o.X + Next(), o.Y + Next());
                        Open().Segments.Add(new LineSegment(current, true));
                        break;
                    case 'H':
                        current = new Point((relative ? current.X : 0) + Next(), current.Y);
                        Open().Segments.Add(new LineSegment(current, true));
                        break;
                    case 'V':
                        current = new Point(current.X, (relative ? current.Y : 0) + Next());
                        Open().Segments.Add(new LineSegment(current, true));
                        break;
                    case 'C':
                    {
                        var c1 = new Point(o.X + Next(), o.Y + Next());
                        var c2 = new Point(o.X + Next(), o.Y + Next());
                        current = new Point(o.X + Next(), o.Y + Next());
                        Open().Segments.Add(new BezierSegment(c1, c2, current, true));
                        break;
                    }
                    case 'A':
                    {
                        double r = Next();
                        _ = Next(); // ry: equal to rx on the canvas
                        _ = Next(); // x-axis rotation: always 0
                        bool large = Next() != 0;
                        bool sweep = Next() != 0;
                        var end = new Point(o.X + Next(), o.Y + Next());
                        if (end != current)
                            Open().Segments.Add(new ArcSegment(end, new System.Windows.Size(r, r), 0, large,
                                sweep ? SweepDirection.Clockwise : SweepDirection.Counterclockwise, true));
                        current = end;
                        break;
                    }
                    case 'Z':
                        if (figure is not null) figure.IsClosed = true;
                        current = start;
                        break;
                    default:
                        numbers.Clear();
                        break;
                }
            } while (numbers.Count > 0);
        }
        geometry.Freeze();
        return geometry;
    }
}

/// The strip's tool icons, copied from the design canvas: Lucide-style outlines in a
/// 24 × 24 box. The paths are the canvas's SVG, parsed once. `CardTab` lives in State, so
/// the view picks the shape: sessions, changes, files, usage (+ `UsageHub` filled), git,
/// settings (the gear, stroked at `Theme.Size.gearStrokeRatio`).
public static class ToolShapes
{
    public const double Box = GlyphShapes.Box;

    public static readonly Geometry Sessions = GlyphShapes.Combine(
        GlyphShapes.RoundedRect(4, 9, 16, 11, 2.5),
        GlyphShapes.Svg("M7 6h10 M9 3h6"));

    public static readonly Geometry Changes = GlyphShapes.Combine(
        GlyphShapes.Circle(12, 12, 9),
        GlyphShapes.Svg("M8 9.5h8 M12 5.5v8 M8 15.5h8"));

    public static readonly Geometry Files = GlyphShapes.Svg(
        "M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z");

    public static readonly Geometry Usage = GlyphShapes.Svg("M4 16a8 8 0 1 1 16 0 M12 16l4.5-5");

    /// The filled part, if any: only the gauge's hub.
    public static readonly Geometry UsageHub = GlyphShapes.Circle(12, 16, 1.5);

    public static readonly Geometry Git = GlyphShapes.Combine(
        GlyphShapes.Circle(6, 5, 2),
        GlyphShapes.Circle(6, 19, 2),
        GlyphShapes.Circle(18, 6, 2),
        GlyphShapes.Svg("M6 7v10 M18 8c0 5-12 3-12 9"));

    public static readonly Geometry Settings = GlyphShapes.Combine(
        GlyphShapes.Circle(12, 12, 3.2),
        GlyphShapes.Svg(
            "M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 "
            + "1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3"
            + "l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 "
            + "0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1"
            + "a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 "
            + "1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 "
            + "0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"));
}

// MARK: - Glyph views

/// A strip tool's icon: the canvas outline stroked with round caps and joins in
/// `Foreground`, the stroke kept proportional to the size (the gear a little finer), plus
/// the filled hub when there is one.
public sealed class ToolGlyph : Grid
{
    private readonly Path stroke;
    private readonly Path? fill;

    public ToolGlyph(Geometry outline, Geometry? filled = null, bool gear = false, double size = Theme.Size.ToolIcon)
    {
        Width = size;
        Height = size;
        double ratio = gear ? Theme.Size.GearStrokeRatio : Theme.Size.ToolStrokeRatio;
        stroke = new Path
        {
            Data = GlyphShapes.Scaled(outline, size),
            StrokeThickness = size * ratio,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Stroke = Theme.Brushes.SegmentIcon,
        };
        Children.Add(stroke);
        if (filled is not null)
        {
            fill = new Path { Data = GlyphShapes.Scaled(filled, size), Fill = Theme.Brushes.SegmentIcon };
            Children.Add(fill);
        }
    }

    /// The icon's colour (segment icon at rest, ink when selected).
    public Brush Foreground
    {
        get => stroke.Stroke;
        set
        {
            stroke.Stroke = value;
            if (fill is not null) fill.Fill = value;
        }
    }
}

/// Claude's clay sparkle with a pulsing ring while work is happening.
public sealed class SparkleGlyph : Grid
{
    public SparkleGlyph(double size = Theme.Size.Glyph)
    {
        Width = size;
        Height = size;
        if (!Theme.Motion.ReduceMotion)
        {
            var ring = new Ellipse
            {
                Width = size,
                Height = size,
                Stroke = Theme.Brushes.Clay,
                StrokeThickness = Theme.Size.RingLine,
                Opacity = Theme.Opacity.PulseStart,
            };
            Children.Add(ring);
            Loaded += (_, _) => Transitions.Pulse(ring);
            Unloaded += (_, _) => Transitions.Stop(ring);
        }
        Children.Add(GlyphShapes.Sparkle.ToPath(size, Theme.Brushes.Clay));
    }
}

/// Clay warning triangle with a slow breathing glow.
public sealed class BreathingTriangle : Grid
{
    public BreathingTriangle(double size = Theme.Size.Glyph)
    {
        Width = size;
        Height = size;
        var path = GlyphShapes.AttentionTriangle.ToPath(size, Theme.Brushes.Attention);
        // The glow breathes between the dim and the bright clay: one colour at the bright
        // alpha, its opacity breathing between their ratio and 1.
        var glow = new DropShadowEffect
        {
            Color = Color.FromRgb(Theme.Colors.AttentionGlow.R, Theme.Colors.AttentionGlow.G, Theme.Colors.AttentionGlow.B),
            BlurRadius = Theme.Size.BreatheRadius * 2,
            ShadowDepth = 0,
            Opacity = Theme.Colors.AttentionGlowDim.A / 255.0,
        };
        path.Effect = glow;
        Children.Add(path);
        Loaded += (_, _) => Transitions.Breathe(glow, DropShadowEffect.OpacityProperty,
            Theme.Colors.AttentionGlowDim.A / 255.0, Theme.Colors.AttentionGlow.A / 255.0);
    }
}

/// A symbol in a tinted circle (peek glyphs).
public sealed class CircleGlyph : Grid
{
    public CircleGlyph(GlyphSpec symbol, Color tint)
    {
        double size = Theme.Size.PeekCircle;
        Width = size;
        Height = size;
        Children.Add(new Ellipse { Fill = Theme.Brush(tint.WithOpacity(Theme.Opacity.GlyphCircle)) });
        var glyph = symbol.ToPath(size * Theme.Size.GlyphInCircle, Theme.Brush(tint));
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(glyph);
    }
}

/// A state's dot (a Border with full corners: WPF's Ellipse is sealed).
public sealed class StatusDot : Border
{
    public StatusDot(SessionState state)
    {
        Width = Theme.Size.Dot;
        Height = Theme.Size.Dot;
        CornerRadius = new CornerRadius(Theme.Size.Dot / 2);
        Background = Theme.Brushes.StateGlyph(state);
    }
}

/// A session's state as a glyph: the clay spark pulsing while working, the clay triangle
/// when it needs you, a green check when done, a dim dot when idle. `circled` sets it in
/// an inset circle (the open card's status segment).
public sealed class StateGlyph : Grid
{
    public StateGlyph(SessionState state, bool circled = false)
    {
        double box = circled ? Theme.Size.IconCircle : Theme.Size.Glyph;
        Width = box;
        Height = box;
        if (circled) Children.Add(new Ellipse { Fill = Theme.Brushes.Inset });
        FrameworkElement glyph = state switch
        {
            SessionState.Working => new SparkleGlyph(),
            SessionState.NeedsYou => new BreathingTriangle(),
            SessionState.Done => GlyphShapes.Checkmark.ToPath(Theme.Size.Glyph, Theme.Brushes.StateGlyph(SessionState.Done)),
            _ => new Ellipse { Width = Theme.Size.Dot, Height = Theme.Size.Dot, Fill = Theme.Brushes.StateGlyph(SessionState.Idle) },
        };
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(glyph);
    }
}

/// The done peek's green circle: pops in (0 → 1.15 → 1) 150 ms after the peek opens, then
/// the check draws on. Reduce Motion: it simply appears.
public sealed class DoneCheckGlyph : Grid
{
    public DoneCheckGlyph(double size = Theme.Size.PeekCircle)
    {
        Width = size;
        Height = size;
        Children.Add(new Ellipse { Fill = Theme.Brush(Theme.Colors.Green.WithOpacity(Theme.Opacity.GlyphCircle)) });
        double inset = size * Theme.Size.CheckInset;
        var rect = new Rect(inset, inset, size - 2 * inset, size - 2 * inset);
        // Drawn on with a dash: one dash the check's length, its offset running from the
        // length (nothing shown) to 0 (all of it). Dash units are stroke thicknesses.
        double length = GlyphShapes.CheckLength(rect) / Theme.Size.CheckLine;
        var check = new Path
        {
            Data = GlyphShapes.Check(rect),
            Stroke = Theme.Brushes.Green,
            StrokeThickness = Theme.Size.CheckLine,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeDashCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeDashArray = new DoubleCollection { length, length + 1 },
            StrokeDashOffset = length,
        };
        Children.Add(check);

        Opacity = 0;
        Loaded += (_, _) =>
        {
            if (Theme.Motion.ReduceMotion)
            {
                Opacity = 1;
                check.StrokeDashOffset = 0;
                return;
            }
            var scale = Transitions.Scale(this);
            scale.ScaleX = 0;
            scale.ScaleY = 0;
            // Two plain animations (0 → overshoot, then a spring to 1), as on macOS.
            Transitions.Animate(check, Shape.StrokeDashOffsetProperty, Theme.Motion.CheckDraw, 0);
            Transitions.Animate(this, OpacityProperty, MotionSpec.Linear(0).WithDelay(Theme.Motion.CheckDelay), 1);
            Transitions.Pop(this, 0, Theme.Motion.CheckPopOvershoot,
                Theme.Motion.CheckPopRise.WithDelay(Theme.Motion.CheckDelay), Theme.Motion.CheckPopSettle);
        };
    }
}
