// HotKey.cs
// Port of Sources/notchcode/App/HotKey.swift: a global hotkey through `RegisterHotKey`, on a
// message-only window of its own. Alt+Space first; when another app owns it (PowerToys Run
// does), Ctrl+Alt+Space. The live chord is written to `prefs.HotkeyChord` so Settings can say
// which one works. Needs no special permission.

using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Notchcode.App;

public sealed class HotKey : IDisposable
{
    /// "alt-space" or "ctrl-alt-space": the chord that was free, or null when neither was.
    public string? Chord { get; }

    private readonly HwndSource window;
    private readonly Action action;
    private const int Id = 0x4E43; // "NC"

    public HotKey(Action action)
    {
        this.action = action;
        // HWND_MESSAGE: a message-only window, never shown.
        window = new HwndSource(new HwndSourceParameters("notchcode-hotkey") { ParentWindow = new IntPtr(-3), Width = 0, Height = 0, WindowStyle = 0 });
        window.AddHook(WndProc);
        if (Native.RegisterHotKey(window.Handle, Id, Native.MOD_ALT | Native.MOD_NOREPEAT, Native.VK_SPACE))
            Chord = "alt-space";
        else if (Native.RegisterHotKey(window.Handle, Id, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, Native.VK_SPACE))
            Chord = "ctrl-alt-space";
        DebugLog.Write($"hotkey {Chord ?? "none"}");
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && wParam.ToInt32() == Id)
        {
            handled = true;
            action();
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (Chord is not null) Native.UnregisterHotKey(window.Handle, Id);
        window.RemoveHook(WndProc);
        window.Dispose();
    }

    private static class Native
    {
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x0001;
        public const uint MOD_CONTROL = 0x0002;
        public const uint MOD_NOREPEAT = 0x4000;
        public const uint VK_SPACE = 0x20;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);

        [DllImport("user32.dll")]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    }
}
