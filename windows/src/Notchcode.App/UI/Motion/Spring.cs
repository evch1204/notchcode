// Spring.cs
// The spring every shape move and every SwiftUI `.spring(response:dampingFraction:)` in the
// Theme runs on: mass 1, stiffness (2π / response)², damping 2·ζ·√stiffness, the same
// parametrisation SwiftUI uses. Solved in closed form, so a step of any length is exact
// (a stalled frame never makes the spring jump or blow up). No WPF types: unit-testable.

namespace Notchcode.UI;

public readonly struct Spring
{
    /// Seconds for one undamped oscillation (SwiftUI's `response`).
    public double Response { get; }
    /// ζ: 1 is critically damped (no overshoot), below 1 overshoots, above 1 creeps.
    public double DampingFraction { get; }
    /// k, for a mass of 1.
    public double Stiffness { get; }
    /// c, for a mass of 1.
    public double Damping { get; }

    /// Below this displacement (and ten times it in velocity, per second) a spring has settled.
    public const double DefaultEpsilon = 0.01;

    public Spring(double response, double dampingFraction)
    {
        Response = Math.Max(response, 1e-4);
        DampingFraction = Math.Max(dampingFraction, 0);
        Stiffness = Math.Pow(2 * Math.PI / Response, 2);
        Damping = 2 * DampingFraction * Math.Sqrt(Stiffness);
    }

    /// Displacement and velocity `t` seconds after starting at displacement `x0` (value minus
    /// target) with velocity `v0`. Closed form for the under-, critically and over-damped cases.
    public void Evaluate(double x0, double v0, double t, out double x, out double v)
    {
        if (t <= 0)
        {
            x = x0;
            v = v0;
            return;
        }
        double w0 = Math.Sqrt(Stiffness);
        double zeta = DampingFraction;
        if (Math.Abs(zeta - 1) < 1e-6)
        {
            // Critically damped: x = e^(−ω t) (x0 + B t), B = v0 + ω x0.
            double b = v0 + w0 * x0;
            double e = Math.Exp(-w0 * t);
            x = e * (x0 + b * t);
            v = e * (v0 - w0 * b * t);
        }
        else if (zeta < 1)
        {
            // Under-damped: x = e^(−a t) (A cos ωd t + B sin ωd t).
            double a = zeta * w0;
            double wd = w0 * Math.Sqrt(1 - zeta * zeta);
            double cA = x0;
            double cB = (v0 + a * x0) / wd;
            double e = Math.Exp(-a * t);
            double cos = Math.Cos(wd * t);
            double sin = Math.Sin(wd * t);
            x = e * (cA * cos + cB * sin);
            v = e * ((-a * cA + cB * wd) * cos + (-a * cB - cA * wd) * sin);
        }
        else
        {
            // Over-damped: x = C1 e^(r1 t) + C2 e^(r2 t).
            double root = Math.Sqrt(zeta * zeta - 1);
            double r1 = -w0 * (zeta - root);
            double r2 = -w0 * (zeta + root);
            double c2 = (v0 - r1 * x0) / (r2 - r1);
            double c1 = x0 - c2;
            double e1 = Math.Exp(r1 * t);
            double e2 = Math.Exp(r2 * t);
            x = c1 * e1 + c2 * e2;
            v = r1 * c1 * e1 + r2 * c2 * e2;
        }
    }

    /// Advances `value` and `velocity` toward `target` by `dt` seconds.
    public void Step(ref double value, ref double velocity, double target, double dt)
    {
        Evaluate(value - target, velocity, dt, out double x, out double v);
        value = target + x;
        velocity = v;
    }

    /// The value `t` seconds into a move from `from` to `to` that started with velocity `v0`.
    public double Sample(double from, double to, double v0, double t)
    {
        Evaluate(from - to, v0, t, out double x, out _);
        return to + x;
    }

    /// The velocity `t` seconds into a move from `from` to `to` that started with velocity `v0`.
    public double VelocityAt(double from, double to, double v0, double t)
    {
        Evaluate(from - to, v0, t, out _, out double v);
        return v;
    }

    /// Settled: within `epsilon` of the target and slower than `velocityEpsilon` per second
    /// (ten times `epsilon` when not given).
    public static bool IsSettled(double value, double velocity, double target, double epsilon = DefaultEpsilon, double? velocityEpsilon = null)
    {
        double ve = velocityEpsilon ?? epsilon * 10;
        return Math.Abs(value - target) < epsilon && Math.Abs(velocity) < ve;
    }

    /// How long a move from `from` to `to` (starting with `v0`) takes to settle, sampled at
    /// `step` seconds, never more than `max`.
    public double SettleTime(double from, double to, double v0 = 0, double epsilon = DefaultEpsilon, double step = 1.0 / 240, double max = 2)
    {
        for (double t = 0; t < max; t += step)
        {
            Evaluate(from - to, v0, t, out double x, out double v);
            if (Math.Abs(x) < epsilon && Math.Abs(v) < epsilon * 10) return t;
        }
        return max;
    }

    public override string ToString() => $"Spring(response: {Response}, damping: {DampingFraction})";
}
