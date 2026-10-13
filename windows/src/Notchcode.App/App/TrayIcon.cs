// TrayIcon.cs
// The notification-area icon (windows/PLAN.md, "Window and shape"): a window-less Windows app
// has no other way to quit, so a tray icon with Open · Settings · Quit is on by default, with a
// switch in Settings (`prefs.ShowTrayIcon`). Shell_NotifyIcon through P/Invoke, on a hidden
// window of its own; the icon is drawn at runtime (the closed notch, black with a light edge
// so it reads on a dark taskbar). It also carries the balloons SystemNotifier posts.

using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Notchcode.Notch;
using Notchcode.UI;

namespace Notchcode.App;

public sealed class TrayIcon : IDisposable
{
    private const uint IconId = 1;
    private const int CallbackMessage = 0x8000 + 1; // WM_APP + 1
    private const uint OpenCommand = 1, SettingsCommand = 2, QuitCommand = 3;

    private readonly HwndSource window;
    private readonly IntPtr icon;
    private readonly int taskbarCreated;
    private readonly Action open;
    private readonly Action settings;
    private readonly Action quit;
    private bool added;
    private bool wanted;
    private System.Windows.Threading.DispatcherTimer? balloonOnlyTimer;

    public TrayIcon(Action open, Action settings, Action quit)
    {
        this.open = open;
        this.settings = settings;
        this.quit = quit;
        // A hidden popup window (not message-only: the menu needs a window that can be foreground).
        window = new HwndSource(new HwndSourceParameters("notchcode-tray")
        {
            WindowStyle = unchecked((int)0x80000000), // WS_POPUP, never shown
            Width = 0,
            Height = 0,
        });
        window.AddHook(WndProc);
        taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        icon = MakeIcon();
    }

    /// Shows or hides the icon (`prefs.ShowTrayIcon`).
    public bool Visible
    {
        get => wanted;
        set
        {
            wanted = value;
            if (value) Add();
            else if (balloonOnlyTimer is null) Delete();
        }
    }

    /// A balloon (NIF_INFO) for a blocking event. With the icon hidden it shows for the
    /// balloon's sake and goes away again after `PeekLifetime` × 3.
    public void ShowBalloon(string title, string body)
    {
        bool temporary = !wanted;
        Add();
        var data = Data(Native.NIF_INFO);
        data.szInfoTitle = Truncate(title, 63);
        data.szInfo = Truncate(body, 255);
        data.dwInfoFlags = Native.NIIF_INFO;
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref data);
        if (!temporary) return;
        balloonOnlyTimer?.Stop();
        balloonOnlyTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.PeekLifetime * 3) };
        balloonOnlyTimer.Tick += (_, _) =>
        {
            balloonOnlyTimer?.Stop();
            balloonOnlyTimer = null;
            if (!wanted) Delete();
        };
        balloonOnlyTimer.Start();
    }

    /// Takes a shown balloon away (the request was answered).
    public void ClearBalloon()
    {
        if (!added) return;
        var data = Data(Native.NIF_INFO);
        data.szInfo = "";
        data.szInfoTitle = "";
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref data);
    }

    private void Add()
    {
        if (added) return;
        var data = Data(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP);
        added = Native.Shell_NotifyIcon(Native.NIM_ADD, ref data);
    }

    private void Delete()
    {
        if (!added) return;
        var data = Data(0);
        Native.Shell_NotifyIcon(Native.NIM_DELETE, ref data);
        added = false;
    }

    private Native.NOTIFYICONDATAW Data(uint flags) => new()
    {
        cbSize = Marshal.SizeOf<Native.NOTIFYICONDATAW>(),
        hWnd = window.Handle,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = icon,
        szTip = "notchcode",
        szInfo = "",
        szInfoTitle = "",
    };

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == taskbarCreated && taskbarCreated != 0)
        {
            // Explorer restarted: the icon has to be added again.
            added = false;
            if (wanted) Add();
            return IntPtr.Zero;
        }
        if (msg != CallbackMessage) return IntPtr.Zero;
        handled = true;
        switch (lParam.ToInt32() & 0xFFFF)
        {
            case Native.WM_LBUTTONUP:
            case Native.NIN_BALLOONUSERCLICK:
                open();
                break;
            case Native.WM_RBUTTONUP:
            case Native.WM_CONTEXTMENU:
                ShowMenu();
                break;
        }
        return IntPtr.Zero;
    }

    private void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        Native.AppendMenu(menu, Native.MF_STRING, OpenCommand, "Open");
        Native.AppendMenu(menu, Native.MF_STRING, SettingsCommand, "Settings");
        Native.AppendMenu(menu, Native.MF_SEPARATOR, 0, null);
        Native.AppendMenu(menu, Native.MF_STRING, QuitCommand, "Quit notchcode");
        Native.GetCursorPos(out var point);
        // The menu closes on a click elsewhere only when its window is in the foreground.
        Native.SetForegroundWindow(window.Handle);
        uint command = Native.TrackPopupMenuEx(menu, Native.TPM_RETURNCMD | Native.TPM_RIGHTBUTTON | Native.TPM_NONOTIFY,
            point.X, point.Y, window.Handle, IntPtr.Zero);
        Native.PostMessage(window.Handle, 0, IntPtr.Zero, IntPtr.Zero);
        Native.DestroyMenu(menu);
        switch (command)
        {
            case OpenCommand: open(); break;
            case SettingsCommand: settings(); break;
            case QuitCommand: quit(); break;
        }
    }

    /// The closed notch (ears and corners) in the icon's box, as an HICON made from a PNG.
    private static IntPtr MakeIcon()
    {
        int size = Theme.Size.TrayIconLarge;
        double w = size * Theme.Size.TrayNotchWidthShare;
        double h = size * Theme.Size.TrayNotchHeightShare;
        // The closed radii in proportion to the closed height, so the ears and corners read.
        double scale = h / Theme.Size.FallbackNotchHeight;
        var geometry = NotchShapes.Shape(w, h, Theme.Radius.ClosedTop * scale, Theme.Radius.ClosedBottom * scale);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new TranslateTransform((size - w) / 2, (size - h) / 2));
            var pen = new Pen(Theme.Brushes.TrayNotchStroke, Theme.Size.TrayNotchStroke);
            dc.DrawGeometry(Theme.Brushes.Notch, pen, geometry);
            dc.Pop();
        }
        var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        byte[] png = stream.ToArray();
        return Native.CreateIconFromResourceEx(png, (uint)png.Length, true, 0x00030000, size, size, 0);
    }

    public void Dispose()
    {
        balloonOnlyTimer?.Stop();
        Delete();
        if (icon != IntPtr.Zero) Native.DestroyIcon(icon);
        window.RemoveHook(WndProc);
        window.Dispose();
    }

    private static class Native
    {
        public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2;
        public const uint NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4, NIF_INFO = 0x10;
        public const uint NIIF_INFO = 0x1;
        public const int WM_LBUTTONUP = 0x0202, WM_RBUTTONUP = 0x0205, WM_CONTEXTMENU = 0x007B;
        public const int NIN_BALLOONUSERCLICK = 0x0405;
        public const uint MF_STRING = 0x0, MF_SEPARATOR = 0x800;
        public const uint TPM_RIGHTBUTTON = 0x2, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct NOTIFYICONDATAW
        {
            public int cbSize;
            public IntPtr hWnd;
            public uint uID;
            public uint uFlags;
            public int uCallbackMessage;
            public IntPtr hIcon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
            public uint dwState;
            public uint dwStateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
            public uint uVersionOrTimeout;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
            public uint dwInfoFlags;
            public Guid guidItem;
            public IntPtr hBalloonIcon;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
        public static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATAW data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int RegisterWindowMessage(string name);

        [DllImport("user32.dll")]
        public static extern IntPtr CreatePopupMenu();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "AppendMenuW")]
        public static extern bool AppendMenu(IntPtr menu, uint flags, uint id, string? text);

        [DllImport("user32.dll")]
        public static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);

        [DllImport("user32.dll")]
        public static extern bool DestroyMenu(IntPtr menu);

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern IntPtr CreateIconFromResourceEx(byte[] data, uint size, bool icon, uint version, int cx, int cy, uint flags);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr icon);
    }
}
