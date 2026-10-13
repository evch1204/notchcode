// NotchGeometry.cs
// Port of Sources/notchcode/Notch/NotchGeometry.swift.
// Where the notch is, and how big the black shape is in each state. Windows PCs have no
// hardware notch: the notch is always the fallback box (180 × 32) at the top centre of the
// primary monitor. The structure is kept so a later "which monitor" choice slots in.

using System.Runtime.InteropServices;
using System.Windows;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

/// The notch on the primary monitor: always the fallback box, since no Windows screen has one.
/// `MonitorPixels` is the monitor's rect in physical pixels; `Scale` its DPI over 96.
public sealed record NotchGeometry(Int32Rect MonitorPixels, double Scale, double NotchWidth, double NotchHeight, bool HasNotch)
{
    /// Null when Windows reports no monitor at all (a remote session reconnecting).
    public static NotchGeometry? Current()
    {
        var monitor = Native.MonitorFromPoint(new Native.POINT { X = 0, Y = 0 }, Native.MONITOR_DEFAULTTOPRIMARY);
        if (monitor == IntPtr.Zero) return null;
        var info = new Native.MONITORINFO { cbSize = Marshal.SizeOf<Native.MONITORINFO>() };
        if (!Native.GetMonitorInfo(monitor, ref info)) return null;
        double scale = 1;
        if (Native.GetDpiForMonitor(monitor, 0, out uint dpiX, out _) == 0 && dpiX > 0) scale = dpiX / 96.0;
        var r = info.rcMonitor;
        return new NotchGeometry(
            new Int32Rect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top),
            scale,
            Theme.Size.FallbackNotchWidth,
            Theme.Size.FallbackNotchHeight,
            HasNotch: false);
    }

    private static class Native
    {
        public const uint MONITOR_DEFAULTTOPRIMARY = 1;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

        [DllImport("user32.dll")]
        public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);
    }
}

/// Shape sizes per state, derived from the notch size and the Theme.
/// "Body" is the part below the ears; the ears add `TopRadius` on each side.
public sealed record NotchLayout(double NotchWidth, double NotchHeight)
{
    public static readonly NotchLayout Fallback = new(Theme.Size.FallbackNotchWidth, Theme.Size.FallbackNotchHeight);

    public Size BodySize(NotchMode mode, double cardHeight) => mode switch
    {
        // Ears sit inside the notch width so the closed shape never leaves the notch box.
        NotchMode.Closed => new Size(Math.Max(0, NotchWidth - 2 * Theme.Radius.ClosedTop), NotchHeight),
        NotchMode.Resting => new Size(Widened(Theme.Size.RestingWidth, HoverWing), NotchHeight),
        NotchMode.Wings => new Size(Widened(Theme.Size.WingsWidth, HoverWing), NotchHeight),
        NotchMode.Peek => new Size(Widened(Theme.Size.PeekWidth), NotchHeight),
        NotchMode.Attention => new Size(Widened(Theme.Size.AttentionWidth, CardWing), NotchHeight + Theme.Size.AttentionExtraHeight),
        _ => new Size(Widened(Theme.Size.CardWidth, CardWing), NotchHeight + cardHeight),
    };

    public double TopRadius(NotchMode mode) => mode switch
    {
        NotchMode.Closed => Theme.Radius.ClosedTop,
        NotchMode.Resting => Theme.Radius.RestingTop,
        NotchMode.Wings => Theme.Radius.WingsTop,
        NotchMode.Peek => Theme.Radius.PeekTop,
        NotchMode.Attention => Theme.Radius.AttentionTop,
        _ => Theme.Radius.CardTop,
    };

    public double BottomRadius(NotchMode mode) => mode switch
    {
        NotchMode.Closed => Theme.Radius.ClosedBottom,
        NotchMode.Resting => Theme.Radius.RestingBottom,
        NotchMode.Wings => Theme.Radius.WingsBottom,
        NotchMode.Peek => Theme.Radius.PeekBottom,
        NotchMode.Attention => Theme.Radius.AttentionBottom,
        _ => Theme.Radius.CardBottom,
    };

    /// Full drawn size including the ears. This is also the clickable area.
    public Size OuterSize(NotchMode mode, double cardHeight)
    {
        var body = BodySize(mode, cardHeight);
        return new Size(body.Width + 2 * TopRadius(mode), body.Height);
    }

    /// Width a wing's content may use: the wing minus the inset kept free at its outer edge.
    public double WingContentWidth(double bodyWidth) => Math.Max(0, WingWidth(bodyWidth) - Theme.Size.WingEdgeInset);

    /// Width of one wing's content column for a given body width.
    public double WingWidth(double bodyWidth)
        => Math.Max(0, (bodyWidth - NotchWidth) / 2 - Theme.Size.SidePadding - Theme.Size.WingInnerGap);

    /// One side of the open card and the attention row (they share the width): the wider of
    /// the right wing's tools and the left wing's status. The card is symmetric, so one more
    /// tool widens both wings and nothing is clipped.
    private double CardWing => Math.Max(StripWing, StatusWing);

    /// The strip's tools, rule and gear, the slack that keeps the first tool's focus ring
    /// inside the clip, and the wing's paddings.
    private static double StripWing =>
        Theme.Size.StripToolsWidth + Theme.Size.StripToolsSlack + Theme.Size.WingEdgeInset
        + Theme.Size.SidePadding + Theme.Size.WingInnerGap;

    /// The status segment's minimum wing plus the wing's paddings (`WingWidth` subtracts them).
    private static double StatusWing => Theme.Size.StatusMinWidth + Theme.Size.SidePadding + Theme.Size.WingInnerGap;

    /// The collapsed strip's right wing on hover: the compact tools at full width, the outer
    /// inset and the paddings. Never below `MinWing`.
    private static double HoverWing =>
        Math.Max(Theme.Size.MinWing, Theme.Size.CompactToolsWidth + Theme.Size.WingEdgeInset
            + Theme.Size.SidePadding + Theme.Size.WingInnerGap);

    /// Keeps wings usable when the notch is wider than the design assumed.
    private double Widened(double width, double wing = Theme.Size.MinWing) => Math.Max(width, NotchWidth + 2 * wing);
}
