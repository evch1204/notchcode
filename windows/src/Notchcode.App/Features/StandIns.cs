// StandIns.cs
// What the Sessions, Changes, Files and Usage panes still need that the shared UI has no twin
// for. Wave 3b retired the rest (wave 1c's copies of Ui, TextLine-style middle truncation,
// FadeText, EmptyNote, DiffCells, DiffCounts, AgentSquare, ElapsedText, SmallTag, CapsuleTag,
// SnippetBox, InsetGroup, UsageBar, ActionSegment, TreeTogglePill, SegmentedPills, ChipFlow,
// PathLabel, RowChevron, FileKindBadge): the panes now use UI/Components.cs, Controls.cs,
// Segments.cs, ChipFlow.cs and UI/Diff/FileRows.cs, ReviewerDiff.cs. What is left here:
//
// - `VRule`: a 1 pt vertical line filling its slot (a lane line, a Markdown quote rule).
//   SwiftUI drew it as a `Rectangle().frame(width:)`; the shared UI has no element for it.
// - `PaneTint`: a hover fill that animates its colour (the Changes chip, the Changes cursor's
//   crossfade between ring and fill). `SegmentButton` owns its own hover; these are not
//   segments.
// - `ChevronTurn`: turns a shared `RowChevron` open or closed on `Theme.Motion.Disclosure`
//   (the quiet group's chevron, the tree's folders). The shared RowChevron takes `open` at
//   construction only; when it grows an animated `Open`, this goes.
// - `BarFill`: animates a shared `UsageBar`'s fill on the Usage tool's `BarFill` spec ("bars
//   fill 0.5 s after landing"); the shared UsageBar sets its fraction at once.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.StandIns;

/// A 1 pt vertical line that fills its slot's height (a lane line, a quote rule).
public sealed class VRule : Border
{
    public VRule(Brush brush, double width)
    {
        Background = brush;
        Width = width;
        VerticalAlignment = VerticalAlignment.Stretch;
    }
}

/// A fill whose colour animates (hover fills, the Changes cursor's crossfade).
public static class PaneTint
{
    /// A brush whose colour can animate.
    public static SolidColorBrush Live(Color color) => new(color);

    /// Animates a live brush's colour on `spec` (an ease; Reduce Motion: `Reduced`).
    public static void Tint(SolidColorBrush brush, Color to, MotionSpec spec)
    {
        if (brush.IsFrozen) return;
        var duration = spec.Kind == MotionKind.Ease && !Theme.Motion.ReduceMotion ? spec.Duration : Theme.Motion.Reduced.Duration;
        var animation = new ColorAnimation(to, new Duration(TimeSpan.FromSeconds(duration)))
        {
            EasingFunction = spec.Easing,
            BeginTime = TimeSpan.FromSeconds(spec.Delay),
        };
        brush.BeginAnimation(SolidColorBrush.ColorProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }
}

/// Turns a shared `RowChevron` to open (90°) or closed on `Theme.Motion.Disclosure`; at once
/// under Reduce Motion or when `animated` is false.
public static class ChevronTurn
{
    public static void Set(RowChevron chevron, bool open, bool animated = true)
    {
        if (chevron.Children.Count == 0 || chevron.Children[0] is not FrameworkElement glyph) return;
        if (glyph.RenderTransform is not RotateTransform rotation || rotation.IsFrozen)
        {
            rotation = new RotateTransform(open ? 0 : Theme.Motion.ChevronOpenDegrees);
            glyph.RenderTransformOrigin = new Point(0.5, 0.5);
            glyph.RenderTransform = rotation;
        }
        double to = open ? Theme.Motion.ChevronOpenDegrees : 0;
        if (animated && Theme.Motion.Disclosure is MotionSpec spec) Transitions.Animate(rotation, RotateTransform.AngleProperty, spec, to);
        else Transitions.Snap(rotation, RotateTransform.AngleProperty, to);
    }
}

/// Animates a shared `UsageBar`'s fill: `BarFill.Set(bar, 0.6, Theme.Motion.BarFill)`.
public static class BarFill
{
    public static readonly DependencyProperty FractionProperty = DependencyProperty.RegisterAttached(
        "Fraction", typeof(double), typeof(BarFill),
        new PropertyMetadata(0.0, (d, e) => { if (d is UsageBar bar) bar.Fraction = (double)e.NewValue; }));

    /// Sets the fill: at once, or on `spec` (never under Reduce Motion).
    public static void Set(UsageBar bar, double fraction, MotionSpec? spec = null)
    {
        double to = Math.Clamp(fraction, 0, 1);
        if (spec is MotionSpec s && !Theme.Motion.ReduceMotion) Transitions.Animate(bar, FractionProperty, s, to);
        else Transitions.Snap(bar, FractionProperty, to);
    }
}
