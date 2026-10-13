// NotchWindow.cs
// Port of Sources/notchcode/Notch/NotchPanel.swift and the panel half of AppDelegate.swift.
// A borderless, per-pixel transparent, topmost tool window at the top centre of the primary
// monitor (windows/PLAN.md, "Window and shape"). It is a fixed box; NotchRootView draws the
// shape at its top centre. Everything outside the drawn shape lets the mouse through, so
// clicks reach the apps underneath. It never activates, except while the card is open: then
// it takes the keys, and hands focus back to the window it took them from when the card
// closes (unless a teleport brought a terminal forward).

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class NotchWindow : Window
{
    private readonly AppState state;
    private readonly NotchRootView root;
    private IntPtr hwnd;
    private HwndSource? source;
    private readonly DispatcherTimer mouseTimer;
    private readonly DispatcherTimer topmostTimer;
    private bool scheduled;
    private NotchMode lastMode = NotchMode.Closed;
    private bool passThrough;
    private Native.POINT lastCursor = new() { X = int.MinValue, Y = int.MinValue };

    /// The window that had the keys before the card took them.
    private IntPtr previousForeground;
    private bool mouseInside;
    private DispatcherTimer? hoverOpenWork;
    private DispatcherTimer? hoverCloseWork;
    /// Mouse over the shape right now, and the pending dwell before the rim lights.
    private bool rimInside;
    private DispatcherTimer? rimWork;

    /// Outer size of the shape (including ears), anchored at the top centre: the clickable area.
    public Size InteractiveSize { get; private set; }

    /// True only while the card is open, so keys reach the card and focus otherwise stays put.
    public bool AllowsKey { get; private set; }

    public NotchWindow(AppState state)
    {
        this.state = state;
        Title = "notchcode";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = 0;
        Top = 0;
        Width = Theme.Size.PanelWidth;
        Height = Theme.Size.PanelHeight;
        UseLayoutRounding = false;
        Focusable = true;

        root = new NotchRootView(state);
        Content = root;

        SourceInitialized += OnSourceInitialized;
        Deactivated += (_, _) => ClickedElsewhere();
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Reposition);
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        Closed += (_, _) =>
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            mouseTimer?.Stop();
            topmostTimer?.Stop();
        };

        // The macOS global mouse-moved monitor: read the cursor and decide who gets the mouse.
        // A still cursor needs no work: the shape changing under it runs the same check from
        // SyncPanel, so the poll only acts when the cursor moved.
        mouseTimer = new DispatcherTimer(TimeSpan.FromSeconds(Theme.Timing.MousePoll), DispatcherPriority.Input,
            (_, _) =>
            {
                Native.GetCursorPos(out var cursor);
                if (cursor.X == lastCursor.X && cursor.Y == lastCursor.Y) return;
                lastCursor = cursor;
                UpdateMousePassthrough();
            }, Dispatcher);
        topmostTimer = new DispatcherTimer(TimeSpan.FromSeconds(Theme.Timing.TopmostReassert), DispatcherPriority.Background,
            (_, _) => AssertTopmost(), Dispatcher);

        state.PropertyChanged += OnStateChanged;
        SyncPanel();
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(Reposition);

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        hwnd = new WindowInteropHelper(this).Handle;
        source = HwndSource.FromHwnd(hwnd);
        source?.AddHook(WndProc);
        long ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
        ex |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
        Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(ex));
        Reposition();
        mouseTimer.Start();
        topmostTimer.Start();
    }

    // MARK: Position

    /// Centres the window on the primary monitor's top edge, in physical pixels.
    public void Reposition()
    {
        if (hwnd == IntPtr.Zero) return;
        // No monitor (a remote session reconnecting): keep the last frame until one returns.
        if (NotchGeometry.Current() is not { } geometry) return;
        state.SetNotch(geometry.NotchWidth, geometry.NotchHeight);
        Native.GetWindowRect(hwnd, out var rect);
        int width = rect.Right - rect.Left;
        var monitor = geometry.MonitorPixels;
        int x = monitor.X + (monitor.Width - width) / 2;
        int y = monitor.Y;
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
        App.DebugLog.Write($"panel=({x},{y}) {width}px monitor={monitor} scale={geometry.Scale}");
    }

    /// Another topmost window can rise above the notch; put it back on top.
    private void AssertTopmost()
    {
        if (hwnd == IntPtr.Zero) return;
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
            Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
    }

    // MARK: Window messages

    private IntPtr WndProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_NCHITTEST:
            {
                int sx = unchecked((short)(lParam.ToInt64() & 0xFFFF));
                int sy = unchecked((short)((lParam.ToInt64() >> 16) & 0xFFFF));
                if (!ContainsScreenPoint(sx, sy))
                {
                    handled = true;
                    return new IntPtr(Native.HTTRANSPARENT);
                }
                break;
            }
            case Native.WM_MOUSEACTIVATE:
                if (!AllowsKey)
                {
                    handled = true;
                    return new IntPtr(Native.MA_NOACTIVATE);
                }
                break;
            case Native.WM_WINDOWPOSCHANGING:
            {
                // Keep the window topmost when something asks to move it down the z-order.
                var pos = Marshal.PtrToStructure<Native.WINDOWPOS>(lParam);
                if ((pos.flags & Native.SWP_NOZORDER) == 0 && pos.hwndInsertAfter != Native.HWND_TOPMOST)
                {
                    pos.hwndInsertAfter = Native.HWND_TOPMOST;
                    Marshal.StructureToPtr(pos, lParam, false);
                }
                break;
            }
            case Native.WM_DISPLAYCHANGE:
                Dispatcher.BeginInvoke(Reposition);
                break;
        }
        return IntPtr.Zero;
    }

    /// Whether a screen point (physical pixels) is over the drawn shape (plus `HitSlop`).
    private bool ContainsScreenPoint(int sx, int sy)
    {
        if (hwnd == IntPtr.Zero) return false;
        Native.GetWindowRect(hwnd, out var rect);
        double scale = Math.Max(0.1, VisualTreeHelper.GetDpi(this).DpiScaleX);
        double x = (sx - rect.Left) / scale;
        double y = (sy - rect.Top) / scale;
        var size = InteractiveSize;
        double left = (Theme.Size.PanelWidth - size.Width) / 2;
        return x >= left && x <= left + size.Width && y >= 0 && y <= size.Height + Theme.Size.HitSlop;
    }

    // MARK: State

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (scheduled) return;
        scheduled = true;
        Dispatcher.BeginInvoke(DispatcherPriority.DataBind, () =>
        {
            scheduled = false;
            SyncPanel();
        });
    }

    /// The clickable size follows the mode; the keys follow the card.
    private void SyncPanel()
    {
        var mode = state.Mode;
        InteractiveSize = state.Layout.OuterSize(mode, state.CardHeight);
        if (hwnd != IntPtr.Zero) UpdateMousePassthrough();
        if (mode == lastMode) return;
        lastMode = mode;
        UpdateKeyFocus(mode);
    }

    /// The window takes the mouse only over the drawn shape; everywhere else it is
    /// `WS_EX_TRANSPARENT`, so clicks fall through to whatever is underneath.
    private void UpdateMousePassthrough()
    {
        if (hwnd == IntPtr.Zero) return;
        Native.GetCursorPos(out var cursor);
        bool inside = ContainsScreenPoint(cursor.X, cursor.Y);
        if (passThrough == inside)
        {
            passThrough = !inside;
            long ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
            ex = passThrough ? ex | Native.WS_EX_TRANSPARENT : ex & ~Native.WS_EX_TRANSPARENT;
            Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(ex));
        }
        UpdateRim(inside);
        UpdateHover(inside);
    }

    // MARK: Hover rim

    /// After the mouse rests on the shape for `RimDelay`, `Hovering` turns on; leaving turns it
    /// off at once. Hover-to-open owners skip it: the same dwell opens the card.
    private void UpdateRim(bool inside)
    {
        if (inside == rimInside) return;
        rimInside = inside;
        rimWork?.Stop();
        rimWork = null;
        if (inside)
        {
            rimWork = After(Theme.Motion.RimDelay, () =>
            {
                rimWork = null;
                if (!rimInside || state.Prefs.OpenGesture == OpenGesture.Hover) return;
                state.SetHovering(true);
            });
        }
        else
        {
            state.SetHovering(false);
        }
    }

    // MARK: Hover to open

    /// Open after the mouse rests on the shape; close after it has left the card.
    private void UpdateHover(bool inside)
    {
        if (state.Prefs.OpenGesture != OpenGesture.Hover)
        {
            CancelHover();
            mouseInside = false;
            return;
        }
        bool changed = inside != mouseInside;
        mouseInside = inside;
        bool open = state.Mode == NotchMode.Card;

        if (inside)
        {
            hoverCloseWork?.Stop();
            hoverCloseWork = null;
            // The attention row answers in one press; opening under the pointer on its way to
            // Allow would move the button away. Click row 1 (or the hotkey) opens it instead.
            if (open || state.Mode == NotchMode.Attention || !(changed || hoverOpenWork is null)) return;
            hoverOpenWork?.Stop();
            hoverOpenWork = After(Theme.Timing.HoverOpenDelay, () =>
            {
                hoverOpenWork = null;
                if (!mouseInside || state.Mode == NotchMode.Card || state.Mode == NotchMode.Attention
                    || state.Prefs.OpenGesture != OpenGesture.Hover) return;
                state.ToggleFromNotchTap();
            });
        }
        else
        {
            hoverOpenWork?.Stop();
            hoverOpenWork = null;
            if (!open || hoverCloseWork is not null) return;
            hoverCloseWork = After(Theme.Timing.HoverCloseDelay, () =>
            {
                hoverCloseWork = null;
                if (mouseInside || state.Mode != NotchMode.Card || state.Prefs.OpenGesture != OpenGesture.Hover) return;
                state.CloseCard();
            });
        }
    }

    private void CancelHover()
    {
        hoverOpenWork?.Stop();
        hoverOpenWork = null;
        hoverCloseWork?.Stop();
        hoverCloseWork = null;
    }

    /// A one-shot timer on the UI thread; `Stop` cancels it.
    private DispatcherTimer After(double seconds, Action action)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal, Dispatcher) { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
        return timer;
    }

    // MARK: Keys

    /// The window takes the keys only while the card is open, so ⏎, ⌫ and friends work
    /// there; otherwise focus stays in the terminal.
    private void UpdateKeyFocus(NotchMode mode)
    {
        if (hwnd == IntPtr.Zero) return;
        if (mode == NotchMode.Card)
        {
            if (AllowsKey) return;
            // Only another app's window: the tray's own (hidden) menu window must not get the
            // focus back (AppDelegate.swift: the frontmost app unless it is this one).
            var front = Native.GetForegroundWindow();
            Native.GetWindowThreadProcessId(front, out uint frontProcess);
            if (front != IntPtr.Zero && frontProcess != (uint)Environment.ProcessId) previousForeground = front;
            AllowsKey = true;
            SetNoActivate(false);
            TakeForeground();
        }
        else if (AllowsKey)
        {
            AllowsKey = false;
            SetNoActivate(true);
            // Teleport already brought a terminal forward; do not steal focus back from it.
            if (state.TakeSkipFocusReturn()) previousForeground = IntPtr.Zero;
            // A click in another app closed the card: that app has the focus now, keep it there.
            bool stillFront = Native.GetForegroundWindow() == hwnd;
            if (stillFront && previousForeground != IntPtr.Zero && Native.IsWindow(previousForeground))
                Native.SetForegroundWindow(previousForeground);
            previousForeground = IntPtr.Zero;
        }
    }

    private void SetNoActivate(bool on)
    {
        long ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
        ex = on ? ex | Native.WS_EX_NOACTIVATE : ex & ~Native.WS_EX_NOACTIVATE;
        Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(ex));
    }

    /// `SetForegroundWindow` is allowed after our click or hotkey; when Windows still refuses,
    /// attach to the foreground thread's input for the call.
    private void TakeForeground()
    {
        if (!Native.SetForegroundWindow(hwnd) || Native.GetForegroundWindow() != hwnd)
        {
            var front = Native.GetForegroundWindow();
            uint frontThread = Native.GetWindowThreadProcessId(front, out _);
            uint ours = Native.GetCurrentThreadId();
            bool attached = frontThread != 0 && frontThread != ours && Native.AttachThreadInput(ours, frontThread, true);
            Native.BringWindowToTop(hwnd);
            Native.SetForegroundWindow(hwnd);
            if (attached) Native.AttachThreadInput(ours, frontThread, false);
        }
        Activate();
        Focus();
        System.Windows.Input.Keyboard.Focus(this);
    }

    /// A click in another app takes the foreground from the open card: close it.
    private void ClickedElsewhere()
    {
        if (!AllowsKey || state.Mode != NotchMode.Card) return;
        App.DebugLog.Write($"card closed: deactivated (front={Native.GetForegroundWindow()})");
        state.CloseCard();
    }

    // MARK: Win32

    private static class Native
    {
        public const int GWL_EXSTYLE = -20;
        public const long WS_EX_TOPMOST = 0x00000008;
        public const long WS_EX_TRANSPARENT = 0x00000020;
        public const long WS_EX_TOOLWINDOW = 0x00000080;
        public const long WS_EX_NOACTIVATE = 0x08000000;
        public const int WM_NCHITTEST = 0x0084;
        public const int WM_MOUSEACTIVATE = 0x0021;
        public const int WM_WINDOWPOSCHANGING = 0x0046;
        public const int WM_DISPLAYCHANGE = 0x007E;
        public const int HTTRANSPARENT = -1;
        public const int MA_NOACTIVATE = 3;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_NOOWNERZORDER = 0x0200;
        public static readonly IntPtr HWND_TOPMOST = new(-1);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct WINDOWPOS
        {
            public IntPtr hwnd;
            public IntPtr hwndInsertAfter;
            public int x, y, cx, cy;
            public uint flags;
        }

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
        public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    }
}
