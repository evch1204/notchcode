// NotchRootView.xaml.cs
// Port of Sources/notchcode/Notch/NotchRootView.swift.
// One black shape that morphs between states. Width leads on the way out, height leads on
// the way back. Content fades and rises in after the shape moves. Inside one state the shape
// re-targets with one spring (the card changing tool). Around the shape: the hover rim light
// (closed and resting), the attention clay bleed, and the teleport fold. Every light sits
// outside the black silhouette, never under the centre 180 pt.
//
// The four shape values are `ShapeAnimator` channels; every frame they move, the shape, the
// content's clip, the rim and the bleed are laid out again. The content is laid out for the
// target size and clipped by the animating shape, so text never reflows mid-spring.

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public partial class NotchRootView : UserControl
{
    private readonly AppState state;
    private readonly ShapeAnimator animator;
    private NotchMode shownMode = NotchMode.Closed;
    private NotchLayout lastLayout;
    private NotchMode lastMode;
    private double lastCardHeight;
    private bool scheduled;

    private FrameworkElement? content;
    private string contentKey = "";

    /// Guards the delayed bleed settle against a newer arrival or departure.
    private int bleedGeneration;
    private bool rimOn;

    public NotchRootView(AppState state)
    {
        this.state = state;
        InitializeComponent();
        Width = Theme.Size.PanelWidth;
        Height = Theme.Size.PanelHeight;

        // The rim: the M7 crescent at 50% white, and behind it the glow (the shape at 12%,
        // dropped and blurred). Reduce Motion: the crescent only.
        RimCrescent.Fill = Theme.Brushes.Rim;
        RimGlow.Fill = Theme.Brushes.RimGlow;
        RimGlow.Effect = new BlurEffect { Radius = Theme.Size.RimGlowRadius * 2, RenderingBias = RenderingBias.Performance };
        Canvas.SetTop(RimGlow, Theme.Size.RimGlowDrop);
        if (Theme.Motion.ReduceMotion) RimGlow.Visibility = Visibility.Collapsed;

        // The bleed: a blurred clay ellipse centred below the bottom edge, wider than the shape.
        Bleed.Fill = Theme.Brushes.AttentionBleed;
        Bleed.Height = Theme.Size.BleedHeight;
        Bleed.Effect = new BlurEffect { Radius = Theme.Size.BleedBlur * 2, RenderingBias = RenderingBias.Performance };

        lastLayout = state.Layout;
        lastMode = state.Mode;
        lastCardHeight = state.CardHeight;
        var outer = lastLayout.OuterSize(lastMode, lastCardHeight);
        animator = new ShapeAnimator(outer.Width, outer.Height, lastLayout.TopRadius(lastMode), lastLayout.BottomRadius(lastMode));
        animator.Changed += (_, _) => Render();

        state.PropertyChanged += OnStateChanged;
        Morph(state.Mode, animated: false);
        UpdateContent();
        Render();
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (scheduled) return;
        scheduled = true;
        Dispatcher.BeginInvoke(DispatcherPriority.DataBind, () =>
        {
            scheduled = false;
            Sync();
        });
    }

    /// `.onChange(of: mode / layout / cardHeight)`, then the content and the rim.
    private void Sync()
    {
        var layout = state.Layout;
        var mode = state.Mode;
        double cardHeight = state.CardHeight;
        if (layout != lastLayout)
        {
            lastLayout = layout;
            Morph(mode, animated: false);
        }
        else if (mode != lastMode || cardHeight != lastCardHeight)
        {
            Morph(mode, animated: true);
        }
        lastMode = mode;
        lastCardHeight = cardHeight;
        UpdateContent();
        UpdateRim();
        Render();
    }

    // MARK: Morph

    private void Morph(NotchMode mode, bool animated)
    {
        var layout = state.Layout;
        var outer = layout.OuterSize(mode, state.CardHeight);
        double top = layout.TopRadius(mode);
        double bottom = layout.BottomRadius(mode);
        bool arriving = mode == NotchMode.Attention && shownMode != NotchMode.Attention;
        bool leaving = mode != NotchMode.Attention && shownMode == NotchMode.Attention;
        App.DebugLog.Write($"mode={mode} size={outer.Width}x{outer.Height} card={state.CardHeight} shown={shownMode} animated={animated}");

        if (!animated)
        {
            animator.Set(ShapeAnimator.Width, outer.Width);
            animator.Set(ShapeAnimator.Height, outer.Height);
            animator.Set(ShapeAnimator.TopRadius, top);
            animator.Set(ShapeAnimator.BottomRadius, bottom);
            shownMode = mode;
            Transitions.Snap(Bleed, OpacityProperty, mode == NotchMode.Attention ? Theme.Opacity.BleedRest : 0);
            return;
        }

        double shapeWidth = animator.TargetOf(ShapeAnimator.Width);
        double shapeHeight = animator.TargetOf(ShapeAnimator.Height);
        // `mode` and `cardHeight` often change in one update (opening lands on another tool,
        // closing resets it). The first call already set these targets with the sequenced
        // springs; a second must not replace them with the re-target spring.
        if (mode == shownMode && outer.Width == shapeWidth && outer.Height == shapeHeight
            && top == animator.TargetOf(ShapeAnimator.TopRadius) && bottom == animator.TargetOf(ShapeAnimator.BottomRadius))
            return;

        if (mode == shownMode && !state.TeleportFold)
        {
            // Same state, new size: the card re-targets its height for another tool or a
            // request's diff. One spring, no axis sequencing.
            var retarget = Theme.Motion.PanelRetarget;
            animator.Retarget(ShapeAnimator.Width, outer.Width, retarget);
            animator.Retarget(ShapeAnimator.Height, outer.Height, retarget);
            animator.Retarget(ShapeAnimator.TopRadius, top, retarget);
            animator.Retarget(ShapeAnimator.BottomRadius, bottom, retarget);
            return;
        }

        if (arriving) AttentionArrived();
        if (leaving) AttentionLeft();

        if (state.TeleportFold)
        {
            // Teleport: height folds up first (ease-in), then the width settles with a small bounce.
            var fold = Theme.Motion.FoldHeight;
            animator.Retarget(ShapeAnimator.Height, outer.Height, fold);
            animator.Retarget(ShapeAnimator.TopRadius, top, fold);
            animator.Retarget(ShapeAnimator.BottomRadius, bottom, fold);
            animator.Retarget(ShapeAnimator.Width, outer.Width, Theme.Motion.FoldWidth);
            shownMode = mode;
            return;
        }

        // Growing: sideways first, then down. Shrinking: up first, then in, faster.
        bool growing = outer.Height >= shapeHeight;
        var widthSpec = growing ? Theme.Motion.Width : Theme.Motion.CloseWidth.WithDelay(Theme.Motion.AxisDelay);
        var heightSpec = growing ? Theme.Motion.Height.WithDelay(Theme.Motion.AxisDelay) : Theme.Motion.CloseHeight;
        animator.Retarget(ShapeAnimator.Width, outer.Width, widthSpec);
        animator.Retarget(ShapeAnimator.Height, outer.Height, heightSpec);
        animator.Retarget(ShapeAnimator.TopRadius, top, heightSpec);
        animator.Retarget(ShapeAnimator.BottomRadius, bottom, heightSpec);
        shownMode = mode;
    }

    /// The clay bleed: 0 → 100% in 0.3 s, then 40% by 1 s. No breath: the shape growing to two
    /// rows is the signal. Reduce Motion: a static 40% bleed.
    private void AttentionArrived()
    {
        int generation = ++bleedGeneration;
        if (Theme.Motion.ReduceMotion)
        {
            Transitions.Animate(Bleed, OpacityProperty, Theme.Motion.Reduced, Theme.Opacity.BleedRest);
            return;
        }
        Transitions.Animate(Bleed, OpacityProperty, Theme.Motion.BleedIn, Theme.Opacity.BleedPeak, () =>
        {
            if (generation != bleedGeneration) return;
            Transitions.Animate(Bleed, OpacityProperty, Theme.Motion.BleedSettle, Theme.Opacity.BleedRest);
        });
    }

    private void AttentionLeft()
    {
        bleedGeneration++;
        Transitions.Animate(Bleed, OpacityProperty, Theme.Motion.ReduceMotion ? Theme.Motion.Reduced : Theme.Motion.ContentOut, 0);
    }

    // MARK: Rim

    /// After the hover dwell on the closed or resting shape (click-to-open owners: the window
    /// only sets `Hovering` for them), the rim fades in; leaving fades it out.
    private void UpdateRim()
    {
        bool on = state.Hovering && (shownMode == NotchMode.Closed || shownMode == NotchMode.Resting);
        if (on == rimOn) return;
        rimOn = on;
        Transitions.Animate(RimLayer, OpacityProperty, on ? Theme.Motion.HoverIn : Theme.Motion.HoverOut, on ? 1 : 0);
    }

    // MARK: Content

    /// The content for the shown state, keyed so a new peek or request builds a new view.
    private void UpdateContent()
    {
        var body = state.Layout.BodySize(shownMode, state.CardHeight);
        string key = shownMode switch
        {
            NotchMode.Peek => "peek:" + (state.Peek?.Id.ToString() ?? "wings"),
            NotchMode.Attention => "attention:" + (state.CurrentPending?.Id ?? "none"),
            _ => shownMode.ToString(),
        };
        if (key == contentKey)
        {
            // Same state, new size (the card's tool changed): the content follows at once.
            if (content is not null && (content.Width != body.Width || content.Height != body.Height))
            {
                content.Width = body.Width;
                content.Height = body.Height;
            }
            return;
        }
        contentKey = key;

        var old = content;
        content = Build(shownMode, body);
        content.Width = body.Width;
        content.Height = body.Height;
        content.VerticalAlignment = VerticalAlignment.Top;
        Canvas.SetTop(content, 0);
        ContentHost.Children.Add(content);
        // The card's rows rise one by one; everything else rises as one.
        var transition = Theme.Motion.ContentTransition(rise: shownMode != NotchMode.Card);
        Transitions.Insert(content, transition);
        if (old is not null)
        {
            old.IsHitTestVisible = false;
            Transitions.Remove(old, transition, () => ContentHost.Children.Remove(old));
        }
        PlaceContent();
    }

    private FrameworkElement Build(NotchMode mode, Size body)
    {
        switch (mode)
        {
            case NotchMode.Resting:
                return new RestingView(state, body);
            case NotchMode.Wings:
                return new WingsView(state, body);
            case NotchMode.Peek:
                return state.Peek is { } peek ? new PeekView(state, peek, body) : new WingsView(state, body);
            case NotchMode.Attention:
                return state.CurrentPending is { } request ? new AttentionView(state, request, body) : new Grid();
            case NotchMode.Card:
                return new CardView(state, body);
            default:
                // Closed: nothing drawn, but a click toggles the card.
                return new Border { Background = Theme.Brushes.HitTarget }.OnTap(state.ToggleFromNotchTap);
        }
    }

    // MARK: Render

    /// Lays the shape, the clip, the rim and the bleed out for the animator's current values.
    private void Render()
    {
        double w = Math.Max(0, animator[ShapeAnimator.Width]);
        double h = Math.Max(0, animator[ShapeAnimator.Height]);
        double top = animator[ShapeAnimator.TopRadius];
        double bottom = animator[ShapeAnimator.BottomRadius];
        double x = (Theme.Size.PanelWidth - w) / 2;

        Canvas.SetLeft(Shape, x);
        Canvas.SetTop(Shape, 0);
        Shape.Width = w;
        Shape.Height = h;
        Shape.SetRadii(top, bottom);
        Shape.Raised = shownMode is NotchMode.Card or NotchMode.Attention;

        Canvas.SetLeft(ContentHost, x);
        ContentHost.Width = w;
        ContentHost.Height = h;
        ContentHost.Clip = NotchShapes.Shape(w, h, top, bottom);
        PlaceContent();

        if (rimOn || RimLayer.Opacity > 0)
        {
            Canvas.SetLeft(RimLayer, x);
            RimCrescent.Data = NotchShapes.Rim(w, h, top, bottom);
            RimGlow.Data = NotchShapes.Shape(w, h, top, bottom);
        }

        double bleedWidth = w * Theme.Size.BleedWidthFactor;
        Bleed.Width = bleedWidth;
        Canvas.SetLeft(Bleed, x + (w - bleedWidth) / 2);
        Canvas.SetTop(Bleed, h - Theme.Size.BleedHeight / 2 + Theme.Size.BleedDrop);
    }

    /// Centres each content layer (the shown one, and any still fading out) on the shape.
    private void PlaceContent()
    {
        double w = ContentHost.Width;
        if (double.IsNaN(w)) return;
        foreach (UIElement child in ContentHost.Children)
            if (child is FrameworkElement fe && !double.IsNaN(fe.Width))
                Canvas.SetLeft(fe, (w - fe.Width) / 2);
    }
}
