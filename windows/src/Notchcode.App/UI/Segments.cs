// Segments.cs
// Port of Sources/notchcode/UI/Segments.swift: the segment look shared by the strip, the Git
// header's pills and the Settings pills (hover lift, press depress), the pop-in an arriving
// segment does, and the action segment by role (Allow, Deny, neutral) with the countdown
// bar Allow drains along its bottom edge. Wave 0b declared `ActionRole`; wave 1b added the views.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Notchcode.Core;

namespace Notchcode.UI;

/// An action segment's role: Allow is the white primary, Deny is red, the rest neutral.
public enum ActionRole { Allow, Deny, Neutral }

// MARK: - Segment

/// `SegmentStyle` / `SegmentBody`: any label in a segment that lifts on hover (`SegmentHover`
/// fill) and depresses on press (scale `PressScale`, `SegmentPressed` fill). A `Fill` gives it
/// a fixed colour (action segments, the white pill), pressed at `Opacity.Pressed`; without one
/// it is invisible at rest. `Capsule` rounds it fully (the Settings pills). `Click` fires on a
/// release inside. Reduce Motion: no press scale.
public class SegmentButton : Border
{
    private readonly Brush? fill;
    private bool hovered;
    private bool pressed;
    private bool enabled = true;

    /// Fired on a left click (press and release inside).
    public event Action? Click;

    public SegmentButton(UIElement label, Brush? fill = null, bool capsule = false, Action? click = null)
    {
        this.fill = fill;
        Child = label;
        Capsule = capsule;
        Background = BackgroundFor();
        SnapsToDevicePixels = false;
        Focusable = false;
        if (click is not null) Click += click;
        Transitions.Scale(this);
        SizeChanged += (_, _) => { if (Capsule) CornerRadius = new CornerRadius(ActualHeight / 2); };
        CornerRadius = new CornerRadius(Theme.Radius.Segment);
    }

    public bool Capsule { get; }

    /// `.disabled(!enabled)`: dimmed by the caller, ignores the mouse.
    public bool Enabled
    {
        get => enabled;
        set { enabled = value; IsHitTestVisible = value; }
    }

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        hovered = true;
        Restyle(Theme.Motion.HoverLift);
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        hovered = false;
        SetPressed(false);
        Restyle(Theme.Motion.HoverLift);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (!enabled) return;
        e.Handled = true;
        SetPressed(true);
        CaptureMouse();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (!pressed) return;
        e.Handled = true;
        ReleaseMouseCapture();
        bool inside = new Rect(0, 0, ActualWidth, ActualHeight).Contains(e.GetPosition(this));
        SetPressed(false);
        if (inside) Click?.Invoke();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        SetPressed(false);
    }

    private void SetPressed(bool value)
    {
        if (pressed == value) return;
        pressed = value;
        Restyle(Theme.Motion.Press);
        if (Theme.Motion.ReduceMotion) return;
        var scale = Transitions.Scale(this);
        double to = pressed ? Theme.Motion.PressScale : 1;
        Transitions.Animate(scale, ScaleTransform.ScaleXProperty, Theme.Motion.Press, to);
        Transitions.Animate(scale, ScaleTransform.ScaleYProperty, Theme.Motion.Press, to);
    }

    /// The fill this segment owns, so the hover lift and the press fade in on their curves
    /// (`.animation(hoverLift, value: hovered)`, `.animation(press, value: pressed)`) instead
    /// of switching.
    private SolidColorBrush? liveFill;

    private void Restyle(MotionSpec spec)
    {
        if (BackgroundFor() is not SolidColorBrush target)
        {
            liveFill = null;
            Background = BackgroundFor();
            return;
        }
        if (liveFill is null || !ReferenceEquals(Background, liveFill))
        {
            liveFill = new SolidColorBrush(Background is SolidColorBrush current ? current.Color : target.Color);
            Background = liveFill;
        }
        var animation = new System.Windows.Media.Animation.ColorAnimation(target.Color,
            new Duration(TimeSpan.FromSeconds(Math.Max(spec.Duration, 0))))
        {
            EasingFunction = spec.Easing,
        };
        liveFill.BeginAnimation(SolidColorBrush.ColorProperty, animation, System.Windows.Media.Animation.HandoffBehavior.SnapshotAndReplace);
    }

    private Brush BackgroundFor()
    {
        if (fill is not null)
        {
            if (!pressed) return fill;
            return fill is SolidColorBrush solid
                ? Theme.Brush(solid.Color.WithOpacity(Theme.Opacity.Pressed))
                : fill;
        }
        if (pressed) return Theme.Brushes.SegmentPressed;
        if (hovered) return Theme.Brushes.SegmentHover;
        // Transparent, not null: the segment must still take the mouse at rest.
        return Theme.Brushes.HitTarget;
    }
}

/// `PopIn`: scales `ActionPopStart` → `ActionPopOvershoot` → 1 once it appears, after the
/// unfold delay (Allow arriving). Reduce Motion: nothing.
public static class PopIn
{
    public static T Apply<T>(T element) where T : FrameworkElement
    {
        if (Theme.Motion.ReduceMotion) return element;
        var scale = Transitions.Scale(element);
        scale.ScaleX = Theme.Motion.ActionPopStart;
        scale.ScaleY = Theme.Motion.ActionPopStart;
        element.Loaded += (_, _) => Transitions.Pop(element, Theme.Motion.ActionPopStart, Theme.Motion.ActionPopOvershoot,
            Theme.Motion.ActionPopRise, Theme.Motion.ActionPopSettle);
        return element;
    }
}

// MARK: - Action segment

/// One action segment: the title, an optional count ("Push 3", coloured like the keycap
/// text), an optional keycap. Allow carries the countdown draining along its bottom edge.
public sealed class ActionSegment : SegmentButton
{
    public ActionSegment(string title, string? key, ActionRole role, Action action, int? count = null,
        PendingRequest? countdown = null)
        : base(Build(title, key, role, count, countdown), Theme.Brushes.Action(role).Fill, click: action)
    {
        Height = Theme.Size.ActionHeight;
        VerticalAlignment = VerticalAlignment.Center;
    }

    private static UIElement Build(string title, string? key, ActionRole role, int? count, PendingRequest? countdown)
    {
        var colors = Theme.Brushes.Action(role);
        var titles = new HStack { Spacing = Theme.Size.SpaceS };
        titles.Children.Add(Ui.Text(title, Theme.Fonts.Action, colors.Text).Fixed());
        if (count is int n)
            titles.Children.Add(Ui.Text(n.ToString(System.Globalization.CultureInfo.InvariantCulture), Theme.Fonts.CaptionMedium,
                role == ActionRole.Allow ? Theme.Brushes.KeycapTextOnLight : Theme.Brushes.InkSecondary).Fixed());
        var row = new HStack { Spacing = Theme.Size.ActionKeyGap };
        row.Children.Add(titles);
        if (key is not null) row.Children.Add(new Keycap(key, onLight: role == ActionRole.Allow));

        var grid = new Grid { Height = Theme.Size.ActionHeight };
        row.Margin = new Thickness(Theme.Size.ActionHPadding, 0, Theme.Size.ActionHPadding, 0);
        row.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(row);
        if (countdown is not null)
        {
            var bar = new CountdownBar(countdown, colors.Bar)
            {
                Margin = new Thickness(Theme.Size.CountdownBarInset, 0, Theme.Size.CountdownBarInset, Theme.Size.SpaceXS),
                VerticalAlignment = VerticalAlignment.Bottom,
            };
            grid.Children.Add(bar);
        }
        return grid;
    }
}

/// A bar that drains from full to empty over the request's deadline, read from the deadline
/// every frame (Reduce Motion: once a second).
public sealed class CountdownBar : Grid
{
    public CountdownBar(PendingRequest request, Brush? tint = null)
    {
        Height = Theme.Size.CountdownBar;
        var bar = Ui.Capsule(tint ?? Theme.Brushes.AllowBar, Theme.Size.CountdownBar);
        bar.HorizontalAlignment = HorizontalAlignment.Left;
        Children.Add(bar);
        double fraction = 1;
        _ = new RequestTicker(this, request, (f, _) =>
        {
            fraction = f;
            bar.Width = ActualWidth * fraction;
        });
        SizeChanged += (_, _) => bar.Width = ActualWidth * fraction;
    }
}
