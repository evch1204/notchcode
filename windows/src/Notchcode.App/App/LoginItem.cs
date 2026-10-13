// LoginItem.cs
// "Open at login" on Windows: a `notchcode` value under HKCU\Software\Microsoft\Windows\
// CurrentVersion\Run naming this exe (the macOS SMAppService.mainApp). Follows
// `prefs.OpenAtLogin`. Debug builds and the demo never write it, so a dev build in a worktree
// is not what starts at the next sign-in.

using Microsoft.Win32;

namespace Notchcode.App;

public static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "notchcode";

    /// Whether this build may change the Run value (Release, not the demo).
    public static bool Writable
    {
        get
        {
#if DEBUG
            return false;
#else
            return !App.DemoMode;
#endif
        }
    }

    /// Whether a Run value for notchcode exists.
    public static bool IsRegistered
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    /// Adds or removes the Run value so it matches `on`.
    public static void Apply(bool on)
    {
        if (!Writable)
        {
            DebugLog.Write($"login item {(on ? "on" : "off")} (not written by this build)");
            return;
        }
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on)
            {
                string exe = Environment.ProcessPath ?? "";
                if (exe.Length == 0) return;
                string value = "\"" + exe + "\"";
                if (key.GetValue(ValueName) as string != value) key.SetValue(ValueName, value);
            }
            else if (key.GetValue(ValueName) is not null)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            DebugLog.Write("login item: " + e.Message);
        }
    }
}
