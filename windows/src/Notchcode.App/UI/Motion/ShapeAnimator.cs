// ShapeAnimator.cs
// The one per-frame animator behind the black shape: named `double` channels (width,
// height, topRadius, bottomRadius, and any other a view adds), each on its own spring or
// ease, stepped from `CompositionTarget.Rendering`. A new target retargets a channel
// mid-flight and keeps its velocity, so every shape move is interruptible, as SwiftUI's
// springs are. `Changed` fires once per frame with every channel's current value.
// Reduce Motion: a spring becomes `Theme.Motion.Reduced` (a 0.2 s ease).

using System.Diagnostics;
using System.Windows.Media;

namespace Notchcode.UI;

public sealed class ShapeAnimator
{
    /// The channels the notch shape uses.
    public const string Width = "width";
    public const string Height = "height";
    public const string TopRadius = "topRadius";
    public const string BottomRadius = "bottomRadius";

    private sealed class Channel
    {
        public double Value;
        public double Velocity;
        public double Target;
        public double Epsilon = Spring.DefaultEpsilon;
        public MotionSpec Spec;
        public bool Moving;
        // Ease: from where, when it started (after the delay).
        public double EaseFrom;
        public double EaseStart;
        // A retarget waiting for its delay.
        public (double Target, MotionSpec Spec, double At)? Pending;
    }

    private readonly Dictionary<string, Channel> channels = new(StringComparer.Ordinal);
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private double lastFrame;
    private bool subscribed;

    /// Once per rendered frame while anything moves, and once after a `Set`.
    public event EventHandler? Changed;
    /// Every channel has come to rest.
    public event EventHandler? Settled;

    public ShapeAnimator() { }

    /// The four shape channels, at rest at these values.
    public ShapeAnimator(double width, double height, double topRadius, double bottomRadius)
    {
        Add(Width, width);
        Add(Height, height);
        Add(TopRadius, topRadius);
        Add(BottomRadius, bottomRadius);
    }

    /// Adds a channel at rest at `value` (or moves an existing one there at once).
    /// `epsilon`: how close counts as settled, in the channel's units.
    public void Add(string name, double value, double epsilon = Spring.DefaultEpsilon)
    {
        channels[name] = new Channel { Value = value, Target = value, Epsilon = epsilon };
    }

    /// A channel's current value.
    public double this[string name] => channels[name].Value;

    /// A channel's target (where it is heading, or resting).
    public double TargetOf(string name) => channels[name].Pending?.Target ?? channels[name].Target;

    /// A channel's current velocity, in units per second.
    public double VelocityOf(string name) => channels[name].Velocity;

    public IReadOnlyCollection<string> Names => channels.Keys;

    /// Whether any channel is moving or waiting on a delay.
    public bool IsAnimating => channels.Values.Any(c => c.Moving || c.Pending is not null);

    /// Jumps a channel to `value`, at rest, dropping any motion.
    public void Set(string name, double value)
    {
        if (!channels.TryGetValue(name, out var channel)) { Add(name, value); channel = channels[name]; }
        channel.Value = value;
        channel.Target = value;
        channel.Velocity = 0;
        channel.Moving = false;
        channel.Pending = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// Heads `name` for `target` on `spec`, `delay` seconds from now (on top of the spec's
    /// own delay). A spring keeps the channel's current velocity; an ease starts from the
    /// current value. Retargeting to the current target does nothing.
    public void Retarget(string name, double target, MotionSpec spec, double delay = 0)
    {
        if (!channels.TryGetValue(name, out var channel)) { Add(name, target); return; }
        // The delay is taken first: Reduce Motion swaps the curve but keeps the sequencing,
        // as `Theme.Motion.closeWidth.delay(axisDelay)` does on the Mac.
        double totalDelay = Math.Max(0, delay) + Math.Max(0, spec.Delay);
        if (Theme.Motion.ReduceMotion && spec.Kind == MotionKind.Spring) spec = Theme.Motion.Reduced;
        spec = spec with { Delay = 0 };
        double now = Now();
        if (totalDelay > 0)
        {
            channel.Pending = (target, spec, now + totalDelay);
        }
        else
        {
            channel.Pending = null;
            if (target == channel.Target && channel.Spec == spec && (channel.Moving || channel.Value == target)) return;
            Start(channel, target, spec, now);
        }
        Subscribe();
    }

    private static void Start(Channel channel, double target, MotionSpec spec, double now)
    {
        channel.Target = target;
        channel.Spec = spec;
        channel.Moving = true;
        if (spec.Kind == MotionKind.Ease)
        {
            channel.EaseFrom = channel.Value;
            channel.EaseStart = now;
        }
    }

    private double Now() => clock.Elapsed.TotalSeconds;

    private void Subscribe()
    {
        if (subscribed) return;
        subscribed = true;
        lastFrame = Now();
        CompositionTarget.Rendering += OnRendering;
    }

    private void Unsubscribe()
    {
        if (!subscribed) return;
        subscribed = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        double now = Now();
        Tick(now - lastFrame, now);
        lastFrame = now;
        Changed?.Invoke(this, EventArgs.Empty);
        if (!IsAnimating)
        {
            Unsubscribe();
            Settled?.Invoke(this, EventArgs.Empty);
        }
    }

    /// Advances every channel by `dt` seconds; `now` is the animator's clock. Public so tests
    /// can step it without a render loop.
    public void Tick(double dt, double? now = null)
    {
        double time = now ?? Now();
        foreach (var channel in channels.Values)
        {
            if (channel.Pending is { } pending && time >= pending.At)
            {
                channel.Pending = null;
                // The move starts at its due time, not at this frame: step only the overrun.
                Start(channel, pending.Target, pending.Spec, pending.At);
                Advance(channel, time - pending.At, time);
                continue;
            }
            if (channel.Moving) Advance(channel, dt, time);
        }
    }

    private static void Advance(Channel channel, double dt, double now)
    {
        if (channel.Spec.Kind == MotionKind.Spring)
        {
            var spring = channel.Spec.ToSpring();
            spring.Step(ref channel.Value, ref channel.Velocity, channel.Target, Math.Max(dt, 0));
            if (Spring.IsSettled(channel.Value, channel.Velocity, channel.Target, channel.Epsilon))
            {
                channel.Value = channel.Target;
                channel.Velocity = 0;
                channel.Moving = false;
            }
        }
        else
        {
            double duration = Math.Max(channel.Spec.Duration, 1e-6);
            double progress = Math.Clamp((now - channel.EaseStart) / duration, 0, 1);
            double eased = channel.Spec.Easing?.Ease(progress) ?? progress;
            double previous = channel.Value;
            channel.Value = channel.EaseFrom + (channel.Target - channel.EaseFrom) * eased;
            channel.Velocity = dt > 0 ? (channel.Value - previous) / dt : 0;
            if (progress >= 1)
            {
                channel.Value = channel.Target;
                channel.Velocity = 0;
                channel.Moving = false;
            }
        }
    }

    /// Stops the render loop; the channels keep their current values.
    public void Stop()
    {
        foreach (var channel in channels.Values)
        {
            channel.Moving = false;
            channel.Velocity = 0;
            channel.Pending = null;
            channel.Target = channel.Value;
        }
        Unsubscribe();
    }

    // MARK: - Plain WPF properties

    /// Animates a plain WPF property with a spring-sampled `DoubleAnimationUsingKeyFrames`
    /// (60 Hz, until settled, at most 2 s) or a `DoubleAnimation` for an ease. See
    /// `Transitions.Animate`, which this forwards to.
    public static void Animate(System.Windows.DependencyObject target, System.Windows.DependencyProperty property, MotionSpec spec, double to, Action? completed = null) =>
        Transitions.Animate(target, property, spec, to, completed);
}
