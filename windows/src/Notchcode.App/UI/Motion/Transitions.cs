// Transitions.cs
// The WPF side of SwiftUI's `Animation` and `AnyTransition`: `MotionSpec` (a spring or an
// ease, with its delay), `TransitionSpec` (how an element comes in and goes out), and the
// helpers the views use, ported from MotionModifiers.swift: rise-in, fade-in, the unfold,
// pop, shake, pulse, the pane slide with its parallax. Curves come from Theme.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Notchcode.UI;

public enum MotionKind
{
    /// A spring (`Response`, `Damping`); it runs as long as it takes to settle.
    Spring,
    /// A timed curve (`Duration`, `Easing`).
    Ease,
}

/// One SwiftUI `Animation`: a spring or a timed ease, an optional delay, optionally repeating.
public readonly record struct MotionSpec
{
    public MotionKind Kind { get; init; }
    /// Spring: seconds per undamped oscillation (SwiftUI's `response`).
    public double Response { get; init; }
    /// Spring: the damping fraction ζ.
    public double Damping { get; init; }
    /// Ease: seconds.
    public double Duration { get; init; }
    /// Seconds before it starts (SwiftUI's `.delay`).
    public double Delay { get; init; }
    /// Ease: the curve (null is linear).
    public IEasingFunction? Easing { get; init; }
    /// `.repeatForever(autoreverses:)`.
    public bool RepeatForever { get; init; }
    public bool AutoReverse { get; init; }

    /// SwiftUI's `.easeIn`, `.easeOut` and `.easeInOut` are these cubic Béziers.
    public static readonly IEasingFunction EaseInCurve = CubicBezierEase.Create(0.42, 0, 1, 1);
    public static readonly IEasingFunction EaseOutCurve = CubicBezierEase.Create(0, 0, 0.58, 1);
    public static readonly IEasingFunction EaseInOutCurve = CubicBezierEase.Create(0.42, 0, 0.58, 1);

    /// `.spring(response:dampingFraction:)`.
    public static MotionSpec Spring(double response, double dampingFraction) =>
        new() { Kind = MotionKind.Spring, Response = response, Damping = dampingFraction };
    /// `.easeIn(duration:)`.
    public static MotionSpec EaseIn(double duration) => new() { Kind = MotionKind.Ease, Duration = duration, Easing = EaseInCurve };
    /// `.easeOut(duration:)`.
    public static MotionSpec EaseOut(double duration) => new() { Kind = MotionKind.Ease, Duration = duration, Easing = EaseOutCurve };
    /// `.easeInOut(duration:)`.
    public static MotionSpec EaseInOut(double duration) => new() { Kind = MotionKind.Ease, Duration = duration, Easing = EaseInOutCurve };
    /// `.linear(duration:)`.
    public static MotionSpec Linear(double duration) => new() { Kind = MotionKind.Ease, Duration = duration };

    /// SwiftUI's `.delay(_:)`.
    public MotionSpec WithDelay(double delay) => this with { Delay = delay };
    /// SwiftUI's `.repeatForever(autoreverses:)`.
    public MotionSpec Repeating(bool autoreverses) => this with { RepeatForever = true, AutoReverse = autoreverses };

    /// The solver for a spring spec.
    public Spring ToSpring() => new(Response, Damping);

    /// Seconds from start (after the delay) to rest for a move of `from` → `to`.
    public double ActiveDuration(double from, double to, double initialVelocity = 0) =>
        Kind == MotionKind.Spring
            ? ToSpring().SettleTime(from, to, initialVelocity, Epsilon(from, to))
            : Duration;

    /// Settling tolerance: a thousandth of the distance, at most 0.01 (a hundredth of a DIP).
    public static double Epsilon(double from, double to) => Math.Clamp(Math.Abs(to - from) * 1e-3, 1e-5, 0.01);

    /// A frozen WPF timeline for `from` → `to`: a `DoubleAnimation` with the curve for an ease,
    /// or the spring sampled at 60 Hz into linear key frames until it settles (at most 2 s).
    /// The delay becomes `BeginTime` (once, before the first cycle of a repeating one).
    public AnimationTimeline ToTimeline(double from, double to, double initialVelocity = 0)
    {
        AnimationTimeline timeline;
        if (Kind == MotionKind.Spring)
        {
            var spring = ToSpring();
            var frames = new DoubleAnimationUsingKeyFrames();
            double eps = Epsilon(from, to);
            const double step = 1.0 / 60;
            const double max = 2;
            frames.KeyFrames.Add(new LinearDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            bool settled = false;
            for (int i = 1; i * step <= max; i++)
            {
                double t = i * step;
                spring.Evaluate(from - to, initialVelocity, t, out double x, out double v);
                settled = Math.Abs(x) < eps && Math.Abs(v) < eps * 10;
                frames.KeyFrames.Add(new LinearDoubleKeyFrame(settled ? to : to + x, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t))));
                if (settled) break;
            }
            if (!settled)
                frames.KeyFrames.Add(new LinearDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(max + step))));
            timeline = frames;
        }
        else
        {
            timeline = new DoubleAnimation(from, to, new Duration(TimeSpan.FromSeconds(Math.Max(Duration, 0))))
            {
                EasingFunction = Easing,
            };
        }
        // BeginTime offsets the start once; repetitions run inside the active period.
        timeline.BeginTime = TimeSpan.FromSeconds(Math.Max(Delay, 0));
        if (RepeatForever)
        {
            timeline.AutoReverse = AutoReverse;
            timeline.RepeatBehavior = RepeatBehavior.Forever;
        }
        timeline.Freeze();
        return timeline;
    }
}

/// A CSS / SwiftUI `cubic-bezier(x1, y1, x2, y2)` curve for WPF timelines.
public sealed class CubicBezierEase : EasingFunctionBase
{
    public double X1 { get; private set; }
    public double Y1 { get; private set; }
    public double X2 { get; private set; }
    public double Y2 { get; private set; }

    public CubicBezierEase()
    {
        // EaseIn mode hands `EaseInCore` the progress unchanged.
        EasingMode = EasingMode.EaseIn;
    }

    /// A frozen curve.
    public static CubicBezierEase Create(double x1, double y1, double x2, double y2)
    {
        var ease = new CubicBezierEase { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2 };
        ease.Freeze();
        return ease;
    }

    protected override double EaseInCore(double normalizedTime)
    {
        double x = Math.Clamp(normalizedTime, 0, 1);
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        return Bezier(SolveT(x), Y1, Y2);
    }

    private static double Bezier(double t, double p1, double p2)
    {
        double u = 1 - t;
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
    }

    /// The curve parameter whose x is `x`: Newton's method, bisection when it stalls.
    private double SolveT(double x)
    {
        double t = x;
        for (int i = 0; i < 8; i++)
        {
            double err = Bezier(t, X1, X2) - x;
            if (Math.Abs(err) < 1e-7) return t;
            double u = 1 - t;
            double d = 3 * u * u * X1 + 6 * u * t * (X2 - X1) + 3 * t * t * (1 - X2);
            if (Math.Abs(d) < 1e-6) break;
            t -= err / d;
        }
        double lo = 0, hi = 1;
        t = x;
        for (int i = 0; i < 50; i++)
        {
            double value = Bezier(t, X1, X2);
            if (Math.Abs(value - x) < 1e-7) break;
            if (value < x) lo = t; else hi = t;
            t = (lo + hi) / 2;
        }
        return t;
    }

    protected override Freezable CreateInstanceCore() => new CubicBezierEase();

    protected override void CloneCore(Freezable sourceFreezable)
    {
        base.CloneCore(sourceFreezable);
        CopyFrom((CubicBezierEase)sourceFreezable);
    }

    protected override void CloneCurrentValueCore(Freezable sourceFreezable)
    {
        base.CloneCurrentValueCore(sourceFreezable);
        CopyFrom((CubicBezierEase)sourceFreezable);
    }

    protected override void GetAsFrozenCore(Freezable sourceFreezable)
    {
        base.GetAsFrozenCore(sourceFreezable);
        CopyFrom((CubicBezierEase)sourceFreezable);
    }

    protected override void GetCurrentValueAsFrozenCore(Freezable sourceFreezable)
    {
        base.GetCurrentValueAsFrozenCore(sourceFreezable);
        CopyFrom((CubicBezierEase)sourceFreezable);
    }

    private void CopyFrom(CubicBezierEase source)
    {
        X1 = source.X1; Y1 = source.Y1; X2 = source.X2; Y2 = source.Y2;
    }
}

/// One SwiftUI `AnyTransition`: how an element comes in (`In`) and goes out (`Out`). Offsets
/// and scales are where the element sits when transitioned (inserted from, removed to); a
/// null `In` or `Out` is `.identity` (it appears, or leaves, at once).
public sealed record TransitionSpec
{
    public MotionSpec? In { get; init; }
    public MotionSpec? Out { get; init; }
    /// Coming in: opacity 0 → 1 (false: whole from the first frame).
    public bool InFade { get; init; } = true;
    /// Going out: opacity 1 → 0 (false: whole until removed).
    public bool OutFade { get; init; } = true;
    public double InDx { get; init; }
    public double InDy { get; init; }
    public double OutDx { get; init; }
    public double OutDy { get; init; }
    /// `.scale(scale:)`: the scale it is inserted from / removed to.
    public double InScale { get; init; } = 1;
    public double OutScale { get; init; } = 1;
    /// `TravelFade`: the departing copy is gone within this share of `Out` (1: over all of it).
    public double OutFadeShare { get; init; } = 1;
    /// `RowCollapse`: the height folds between 0 and this (0: no collapse).
    public double CollapseHeight { get; init; }
    /// `PaneParallax`: the slide's x offset is published to `ParallaxGroup` children.
    public bool Parallax { get; init; }

    /// Opacity only, both ways.
    public static TransitionSpec Opacity(MotionSpec? @in, MotionSpec? @out) => new() { In = @in, Out = @out };
}

/// The motion helpers views use. Each respects Reduce Motion as its Swift twin does.
public static class Transitions
{
    // MARK: - Transforms

    /// The element's `TranslateTransform` (in a `TransformGroup` with a scale), added the
    /// first time it is asked for.
    public static TranslateTransform Translate(UIElement element) => Group(element).Children.OfType<TranslateTransform>().First();

    /// The element's `ScaleTransform`, about its centre.
    public static ScaleTransform Scale(UIElement element)
    {
        element.RenderTransformOrigin = new Point(0.5, 0.5);
        return Group(element).Children.OfType<ScaleTransform>().First();
    }

    private static TransformGroup Group(UIElement element)
    {
        if (element.RenderTransform is TransformGroup existing && !existing.IsFrozen
            && existing.Children.OfType<ScaleTransform>().Any() && existing.Children.OfType<TranslateTransform>().Any())
            return existing;
        var group = new TransformGroup();
        group.Children.Add(new ScaleTransform(1, 1));
        group.Children.Add(new TranslateTransform(0, 0));
        element.RenderTransform = group;
        return group;
    }

    // MARK: - Running a spec

    private sealed record Running(long StartTicks, double From, double To, double V0, MotionSpec Spec);

    private static readonly ConditionalWeakTable<DependencyObject, Dictionary<DependencyProperty, Running>> running = new();

    /// Animates `property` of `target` (a `UIElement` or an `Animatable`) to `to` on `spec`,
    /// from its current, possibly animated, value. A spring interrupting a spring this helper
    /// started keeps the old one's velocity (a spring sampled at 60 Hz into key frames,
    /// until settled, at most 2 s). Under Reduce Motion a spring becomes `reduced`.
    public static void Animate(DependencyObject target, DependencyProperty property, MotionSpec spec, double to, Action? completed = null)
    {
        if (target is not IAnimatable animatable)
            throw new ArgumentException("The target must be a UIElement or an Animatable.", nameof(target));
        double from = target.GetValue(property) is double d && !double.IsNaN(d) ? d : to;
        if (Theme.Motion.ReduceMotion && spec.Kind == MotionKind.Spring) spec = Theme.Motion.Reduced.WithDelay(spec.Delay);

        double v0 = 0;
        var table = running.GetOrCreateValue(target);
        long now = Stopwatch.GetTimestamp();
        if (spec.Kind == MotionKind.Spring && table.TryGetValue(property, out var previous) && previous.Spec.Kind == MotionKind.Spring)
        {
            double elapsed = (now - previous.StartTicks) / (double)Stopwatch.Frequency - previous.Spec.Delay;
            if (elapsed > 0) v0 = previous.Spec.ToSpring().VelocityAt(previous.From, previous.To, previous.V0, elapsed);
        }
        table[property] = new Running(now, from, to, v0, spec);

        var timeline = spec.ToTimeline(from, to, v0);
        if (completed is not null)
        {
            timeline = timeline.Clone();
            timeline.Completed += (_, _) => completed();
        }
        animatable.BeginAnimation(property, timeline, HandoffBehavior.SnapshotAndReplace);
    }

    /// Sets `property` at once, dropping any animation on it.
    public static void Snap(DependencyObject target, DependencyProperty property, double value)
    {
        if (target is IAnimatable animatable) animatable.BeginAnimation(property, null);
        target.SetValue(property, value);
        if (running.TryGetValue(target, out var table)) table.Remove(property);
    }

    /// Calls `completed` once, after `count` calls of the returned action.
    private static Action? Countdown(int count, Action? completed)
    {
        if (completed is null) return null;
        int left = count;
        return () => { if (--left == 0) completed(); };
    }

    // MARK: - MotionModifiers.swift

    /// `RiseIn`: a card row that fades in and rises `contentRise`, 120 ms + 40 ms per row
    /// after it appears; rows past `cap` share its delay (the Git picker passes
    /// `rowStaggerCap`). Reduce Motion: one 0.2 s crossfade, no rise, no stagger.
    public static void RiseIn(UIElement element, int index, int cap = int.MaxValue)
    {
        bool reduce = Theme.Motion.ReduceMotion;
        var spec = reduce
            ? Theme.Motion.Reduced.WithDelay(Theme.Motion.ContentFadeDelay)
            : Theme.Motion.RowIn(Math.Min(index, cap));
        Snap(element, UIElement.OpacityProperty, 0);
        Animate(element, UIElement.OpacityProperty, spec, 1);
        var translate = Translate(element);
        Snap(translate, TranslateTransform.YProperty, reduce ? 0 : Theme.Motion.ContentRise);
        if (!reduce) Animate(translate, TranslateTransform.YProperty, spec, 0);
    }

    /// `FadeIn`: fades the content in once it appears (`contentIn`), no rise: the text inside
    /// a box that travels, so only the arriving copy shows. Reduce Motion: `reduced`.
    public static void FadeIn(UIElement element)
    {
        Snap(element, UIElement.OpacityProperty, 0);
        Animate(element, UIElement.OpacityProperty, Theme.Motion.ReduceMotion ? Theme.Motion.Reduced : Theme.Motion.ContentIn, 1);
    }

    /// Fades out on `contentOut` (Reduce Motion: `reduced`), then calls `completed`.
    public static void FadeOut(UIElement element, Action? completed = null) =>
        Animate(element, UIElement.OpacityProperty, Theme.Motion.ReduceMotion ? Theme.Motion.Reduced : Theme.Motion.ContentOut, 0, completed);

    /// `Unfold`: a strip segment starts `unfoldDistance` toward the camera and transparent,
    /// then springs into place, `index` × 30 ms after the first. `towardCamera` is +1 for the
    /// left wing and −1 for the right wing. Reduce Motion: opacity only.
    public static void Unfold(UIElement element, int index, double towardCamera)
    {
        var spec = Theme.Motion.Unfold(index);
        bool reduce = Theme.Motion.ReduceMotion;
        Snap(element, UIElement.OpacityProperty, 0);
        Animate(element, UIElement.OpacityProperty, spec, 1);
        var translate = Translate(element);
        Snap(translate, TranslateTransform.XProperty, reduce ? 0 : towardCamera * Theme.Motion.UnfoldDistance);
        if (!reduce) Animate(translate, TranslateTransform.XProperty, spec, 0);
    }

    /// Left wing: segments counted from the camera outward, sliding out to the left.
    public static void UnfoldLeft(UIElement element, int index) => Unfold(element, index, 1);
    /// Right wing: segments counted from the camera outward, sliding out to the right.
    public static void UnfoldRight(UIElement element, int index) => Unfold(element, index, -1);

    /// A pop: scale `start` → `overshoot` on `riseSpec`, then `settleSpec` (a spring) back to
    /// 1. Two plain animations, as `PopIn`, `CountPop` and the done check. Reduce Motion:
    /// scale 1 at once.
    public static void Pop(UIElement element, double start, double overshoot, MotionSpec riseSpec, MotionSpec settleSpec)
    {
        var scale = Scale(element);
        if (Theme.Motion.ReduceMotion)
        {
            Snap(scale, ScaleTransform.ScaleXProperty, 1);
            Snap(scale, ScaleTransform.ScaleYProperty, 1);
            return;
        }
        Snap(scale, ScaleTransform.ScaleXProperty, start);
        Snap(scale, ScaleTransform.ScaleYProperty, start);
        Animate(scale, ScaleTransform.ScaleYProperty, riseSpec, overshoot);
        Animate(scale, ScaleTransform.ScaleXProperty, riseSpec, overshoot, () =>
        {
            Animate(scale, ScaleTransform.ScaleXProperty, settleSpec, 1);
            Animate(scale, ScaleTransform.ScaleYProperty, settleSpec, 1);
        });
    }

    /// `CountPop`: a count that just moved pops 1 → `actionPopOvershoot` → 1. Reduce Motion: nothing.
    public static void CountPop(UIElement element) =>
        Pop(element, 1, Theme.Motion.ActionPopOvershoot, Theme.Motion.CountPopRise, Theme.Motion.ActionPopSettle);

    /// `Shake`: out `amplitude`, back past the middle, and so on for `halfCycles` swings, then
    /// home, `halfCycleDuration` each on an ease-in-out. Reduce Motion: none.
    public static void Shake(UIElement element, double amplitude, int halfCycles, double halfCycleDuration)
    {
        if (Theme.Motion.ReduceMotion || halfCycles <= 0) return;
        var translate = Translate(element);
        var frames = new DoubleAnimationUsingKeyFrames();
        frames.KeyFrames.Add(new LinearDoubleKeyFrame(translate.X, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        for (int i = 1; i <= halfCycles; i++)
        {
            double x = i % 2 == 1 ? amplitude : -amplitude;
            frames.KeyFrames.Add(new EasingDoubleKeyFrame(x, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(halfCycleDuration * i)), MotionSpec.EaseInOutCurve));
        }
        frames.KeyFrames.Add(new EasingDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(halfCycleDuration * (halfCycles + 1))), MotionSpec.EaseInOutCurve));
        frames.Freeze();
        translate.BeginAnimation(TranslateTransform.XProperty, frames, HandoffBehavior.SnapshotAndReplace);
    }

    /// The Theme's shake (a failed sync's pill, an invalid co-author): ±`pillShakeDistance`,
    /// two half-cycles of `pillShakeHalf`, home.
    public static void Shake(UIElement element) =>
        Shake(element, Theme.Motion.PillShakeDistance, 2, Theme.Motion.PillShakeHalf);

    /// The working spark's ring: scale `pulseStartScale` → `pulseScale` while its opacity
    /// falls from `pulseStart` to 0, on `pulse`, forever. Reduce Motion: no ring.
    public static void Pulse(UIElement ring)
    {
        if (Theme.Motion.ReduceMotion)
        {
            ring.Visibility = Visibility.Collapsed;
            return;
        }
        var scale = Scale(ring);
        var spec = Theme.Motion.Pulse;
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, spec.ToTimeline(Theme.Motion.PulseStartScale, Theme.Motion.PulseScale));
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, spec.ToTimeline(Theme.Motion.PulseStartScale, Theme.Motion.PulseScale));
        ring.BeginAnimation(UIElement.OpacityProperty, spec.ToTimeline(Theme.Opacity.PulseStart, 0));
    }

    /// A value breathing `from` → `to` and back on `breathe`, forever (the attention
    /// triangle's glow, dim to bright). Reduce Motion: held at `from`.
    public static void Breathe(DependencyObject target, DependencyProperty property, double from, double to)
    {
        if (Theme.Motion.ReduceMotion)
        {
            Snap(target, property, from);
            return;
        }
        ((IAnimatable)target).BeginAnimation(property, Theme.Motion.Breathe.ToTimeline(from, to));
    }

    /// Stops what `Pulse`, `Shake` or a transition left running on the element.
    public static void Stop(UIElement element)
    {
        element.BeginAnimation(UIElement.OpacityProperty, null);
        if (element.RenderTransform is TransformGroup group && !group.IsFrozen)
            foreach (var child in group.Children)
            {
                if (child is TranslateTransform t)
                {
                    t.BeginAnimation(TranslateTransform.XProperty, null);
                    t.BeginAnimation(TranslateTransform.YProperty, null);
                }
                else if (child is ScaleTransform s)
                {
                    s.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                    s.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                }
            }
    }

    // MARK: - Pane parallax

    /// The horizontal offset of the tab pane sliding in or out, in DIPs, inherited by its
    /// children. Inset groups read it to move a little further than the pane (parallax).
    public static readonly DependencyProperty PaneOffsetProperty = DependencyProperty.RegisterAttached(
        "PaneOffset", typeof(double), typeof(Transitions),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.Inherits, OnParallaxChanged));

    public static double GetPaneOffset(DependencyObject d) => (double)d.GetValue(PaneOffsetProperty);
    public static void SetPaneOffset(DependencyObject d, double value) => d.SetValue(PaneOffsetProperty, value);

    /// `ParallaxGroup`: the element moves by `tabParallax` of the enclosing pane's slide, on
    /// top of the pane's own offset.
    public static readonly DependencyProperty ParallaxGroupProperty = DependencyProperty.RegisterAttached(
        "ParallaxGroup", typeof(bool), typeof(Transitions), new PropertyMetadata(false, OnParallaxChanged));

    public static bool GetParallaxGroup(DependencyObject d) => (bool)d.GetValue(ParallaxGroupProperty);
    public static void SetParallaxGroup(DependencyObject d, bool value) => d.SetValue(ParallaxGroupProperty, value);

    private static void OnParallaxChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not UIElement element || !GetParallaxGroup(d)) return;
        Translate(element).X = GetPaneOffset(d) * Theme.Motion.TabParallax;
    }

    /// A pane sliding by `dx` while it fades (`Theme.Motion.Slide(dx)`), its offset published
    /// to its `ParallaxGroup` children. Inserting: from `dx` to 0; removing: 0 to `dx`, then
    /// `completed`. Reduce Motion: a crossfade, no offset.
    public static void PaneSlide(FrameworkElement pane, double dx, TransitionSpec spec, bool inserting = true, Action? completed = null)
    {
        var moved = spec with { InDx = dx, OutDx = dx, Parallax = true };
        if (inserting) Insert(pane, moved, completed);
        else Remove(pane, moved, completed);
    }

    // MARK: - Applying a TransitionSpec

    /// Plays `spec`'s insertion on an element just added to the tree.
    public static void Insert(FrameworkElement element, TransitionSpec spec, Action? completed = null) =>
        Play(element, spec, inserting: true, completed);

    /// Plays `spec`'s removal; `completed` is where the caller takes the element out of the tree.
    public static void Remove(FrameworkElement element, TransitionSpec spec, Action? completed = null) =>
        Play(element, spec, inserting: false, completed);

    private static void Play(FrameworkElement element, TransitionSpec spec, bool inserting, Action? completed)
    {
        bool reduce = Theme.Motion.ReduceMotion;
        var translate = Translate(element);
        var scale = Scale(element);

        if ((inserting ? spec.In : spec.Out) is not MotionSpec motion)
        {
            // `.identity`: in place at once (inserting), gone at once (removing).
            Snap(element, UIElement.OpacityProperty, 1);
            Snap(translate, TranslateTransform.XProperty, 0);
            Snap(translate, TranslateTransform.YProperty, 0);
            Snap(scale, ScaleTransform.ScaleXProperty, 1);
            Snap(scale, ScaleTransform.ScaleYProperty, 1);
            if (spec.Parallax) Snap(element, PaneOffsetProperty, 0);
            completed?.Invoke();
            return;
        }

        double dx = reduce ? 0 : inserting ? spec.InDx : spec.OutDx;
        double dy = reduce ? 0 : inserting ? spec.InDy : spec.OutDy;
        double scaled = reduce ? 1 : inserting ? spec.InScale : spec.OutScale;
        bool fade = inserting ? spec.InFade : spec.OutFade;

        if (inserting)
        {
            Snap(element, UIElement.OpacityProperty, fade ? 0 : 1);
            Snap(translate, TranslateTransform.XProperty, dx);
            Snap(translate, TranslateTransform.YProperty, dy);
            Snap(scale, ScaleTransform.ScaleXProperty, scaled);
            Snap(scale, ScaleTransform.ScaleYProperty, scaled);
            if (spec.Parallax) Snap(element, PaneOffsetProperty, dx);
            if (spec.CollapseHeight > 0) Snap(element, FrameworkElement.HeightProperty, 0);
        }
        else if (spec.CollapseHeight > 0 && double.IsNaN(element.Height))
        {
            Snap(element, FrameworkElement.HeightProperty, spec.CollapseHeight);
        }

        double endX = inserting ? 0 : dx;
        double endY = inserting ? 0 : dy;
        double endScale = inserting ? 1 : scaled;
        double endOpacity = inserting || !fade ? 1 : 0;

        // The departing copy of a travelling box fades within `OutFadeShare` of the travel.
        var opacitySpec = motion;
        if (!inserting && fade && spec.OutFadeShare < 1)
        {
            double whole = motion.Kind == MotionKind.Spring ? motion.ToSpring().SettleTime(0, 1) : motion.Duration;
            opacitySpec = MotionSpec.Linear(whole * Math.Max(spec.OutFadeShare, 0)).WithDelay(motion.Delay);
        }

        var jobs = new List<(DependencyObject Target, DependencyProperty Property, MotionSpec Spec, double To)>
        {
            (element, UIElement.OpacityProperty, opacitySpec, endOpacity),
            (translate, TranslateTransform.XProperty, motion, endX),
            (translate, TranslateTransform.YProperty, motion, endY),
            (scale, ScaleTransform.ScaleXProperty, motion, endScale),
            (scale, ScaleTransform.ScaleYProperty, motion, endScale),
        };
        if (spec.Parallax) jobs.Add((element, PaneOffsetProperty, motion, endX));
        if (spec.CollapseHeight > 0)
        {
            element.ClipToBounds = true;
            jobs.Add((element, FrameworkElement.HeightProperty, motion, inserting ? spec.CollapseHeight : 0));
        }

        var done = Countdown(jobs.Count, completed);
        foreach (var job in jobs) Animate(job.Target, job.Property, job.Spec, job.To, done);
    }
}
