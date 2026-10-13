// NotchShape.cs
// Port of Sources/notchcode/Notch/NotchShape.swift.
// The one black shape. Concave "ears" at the top corners where it meets the screen edge,
// convex rounded corners at the bottom.
//
//   ____                          ____
//       \  <- topRadius (ear)    /
//        |                      |
//         \____________________/  <- bottomRadius
//
// The rect's top edge spans the full width; the body sits `topRadius` in from each side.

using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Notchcode.UI;

namespace Notchcode.Notch;

public static class NotchShapes
{
    /// The ear and corner radii that fit a `width` × `height` rect: ears at most a quarter of
    /// the width and half the height, corners at most half the body and what the ears leave
    /// of the height.
    public static (double Top, double Bottom) ClampedRadii(double topRadius, double bottomRadius, double width, double height)
    {
        double top = Math.Max(0, Math.Min(topRadius, Math.Min(width / 4, height / 2)));
        double bodyWidth = width - 2 * top;
        double bottom = Math.Max(0, Math.Min(bottomRadius, Math.Min(bodyWidth / 2, height - top)));
        return (top, bottom);
    }

    /// The shape filling a `width` × `height` rect at the origin, frozen.
    public static PathGeometry Shape(double width, double height, double topRadius, double bottomRadius)
    {
        width = Math.Max(0, width);
        height = Math.Max(0, height);
        var (top, bottom) = ClampedRadii(topRadius, bottomRadius, width, height);
        double left = top;
        double right = width - top;

        var figure = new PathFigure { StartPoint = new Point(0, 0), IsClosed = true, IsFilled = true };
        var current = figure.StartPoint;
        // Left ear: concave, from the top edge down into the body's left side.
        current = ArcTo(figure, current, new Point(left, 0), new Point(left, top), top);
        // Left side down to the bottom-left corner.
        current = ArcTo(figure, current, new Point(left, height), new Point(left + bottom, height), bottom);
        // Bottom edge to the bottom-right corner.
        current = ArcTo(figure, current, new Point(right, height), new Point(right, height - bottom), bottom);
        // Right side up to the right ear.
        current = ArcTo(figure, current, new Point(right, 0), new Point(width, 0), top);
        figure.Segments.Add(new LineSegment(new Point(width, 0), true));

        var geometry = new PathGeometry(new[] { figure });
        geometry.Freeze();
        return geometry;
    }

    /// The hover rim light: the Motion board M7's `inset 0 -2px 0 0` mirrored outward. The
    /// shape's body shifted `RimLine` down, minus the shape in place: a crescent `RimLine`
    /// thick under the flat bottom edge that thins to nothing up each bottom corner. The ears
    /// are left out of the shifted copy (shifted, a concave ear would leave a sliver of light
    /// along the screen edge). Fill it, don't stroke it.
    public static Geometry Rim(double width, double height, double topRadius, double bottomRadius)
    {
        width = Math.Max(0, width);
        height = Math.Max(0, height);
        var (top, bottom) = ClampedRadii(topRadius, bottomRadius, width, height);
        double left = top;
        double right = width - top;
        double drop = Theme.Size.RimLine;

        var figure = new PathFigure { StartPoint = new Point(left, drop), IsClosed = true, IsFilled = true };
        var current = figure.StartPoint;
        current = ArcTo(figure, current, new Point(left, height + drop), new Point(left + bottom, height + drop), bottom);
        current = ArcTo(figure, current, new Point(right, height + drop), new Point(right, height + drop - bottom), bottom);
        figure.Segments.Add(new LineSegment(new Point(right, drop), true));
        var body = new PathGeometry(new[] { figure });

        var rim = Geometry.Combine(body, Shape(width, height, topRadius, bottomRadius), GeometryCombineMode.Exclude, null);
        rim.Freeze();
        return rim;
    }

    /// CoreGraphics' `addArc(tangent1End:tangent2End:radius:)` for the shape's right-angled
    /// corners: a line to where the arc meets the first tangent, then the arc to where it
    /// meets the second. Returns the new current point.
    private static Point ArcTo(PathFigure figure, Point current, Point corner, Point next, double radius)
    {
        if (radius <= 0)
        {
            figure.Segments.Add(new LineSegment(corner, true));
            return corner;
        }
        var d1 = corner - current;
        var d2 = next - corner;
        if (d1.Length < 1e-9 || d2.Length < 1e-9)
        {
            figure.Segments.Add(new LineSegment(corner, true));
            return corner;
        }
        d1.Normalize();
        d2.Normalize();
        var start = corner - d1 * radius;
        var end = corner + d2 * radius;
        figure.Segments.Add(new LineSegment(start, true));
        // y points down: a positive cross product turns clockwise on screen.
        double cross = d1.X * d2.Y - d1.Y * d2.X;
        figure.Segments.Add(new ArcSegment(end, new System.Windows.Size(radius, radius), 0, false,
            cross > 0 ? SweepDirection.Clockwise : SweepDirection.Counterclockwise, true));
        return end;
    }
}

/// Draws the notch shape filling its own bounds: pure black, no stroke. `Raised` gives it the
/// card and attention shadow (a `DropShadowEffect` on this element only, never over text).
public sealed class NotchShapeElement : FrameworkElement
{
    private double topRadius = Theme.Radius.ClosedTop;
    private double bottomRadius = Theme.Radius.ClosedBottom;
    private bool raised;
    private readonly DropShadowEffect shadow = new()
    {
        Color = Color.FromRgb(Theme.Colors.Shadow.R, Theme.Colors.Shadow.G, Theme.Colors.Shadow.B),
        Opacity = Theme.Colors.Shadow.A / 255.0,
        // SwiftUI's shadow radius is a blur radius in points; WPF's BlurRadius is about twice it.
        BlurRadius = Theme.Size.ShadowRadius * 2,
        ShadowDepth = Theme.Size.ShadowY,
        Direction = 270,
        RenderingBias = RenderingBias.Performance,
    };

    public NotchShapeElement()
    {
        IsHitTestVisible = true;
        SnapsToDevicePixels = false;
    }

    /// Sets the radii; the element redraws at its current size.
    public void SetRadii(double top, double bottom)
    {
        if (top == topRadius && bottom == bottomRadius) return;
        topRadius = top;
        bottomRadius = bottom;
        InvalidateVisual();
    }

    /// The card and attention shadow on, or off (closed must be pixel-identical: no shadow).
    public bool Raised
    {
        get => raised;
        set
        {
            if (raised == value) return;
            raised = value;
            Effect = value ? shadow : null;
        }
    }

    public Geometry CurrentGeometry => NotchShapes.Shape(ActualWidth, ActualHeight, topRadius, bottomRadius);

    protected override void OnRender(DrawingContext dc)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        dc.DrawGeometry(Theme.Brushes.Notch, null, CurrentGeometry);
    }
}
