// Launcher.cs
// `notchcode-hook.exe launch`: the SessionStart command that wakes the app, the Windows form
// of `pgrep -xq notchcode || open -g -b com.evch.notchcode`. When no server owns the pipe,
// it starts the app named in `app-path.txt` beside this exe (written by the app at every
// launch), with DOTNET_ROOT from `dotnet-root.txt` when present, detached and windowless.

using System.Text;

namespace Notchcode.Hook;

internal static class Launcher
{
    public static void LaunchIfNeeded()
    {
        if (Native.PipeExists(Program.PipePath)) return;
        var here = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
        var app = ReadLine(Path.Combine(here, "app-path.txt"));
        if (string.IsNullOrEmpty(app) || !File.Exists(app)) return;
        if (ReadLine(Path.Combine(here, "dotnet-root.txt")) is { Length: > 0 } root)
            Environment.SetEnvironmentVariable("DOTNET_ROOT", root);   // the child inherits this block
        Native.StartDetached(app, Path.GetDirectoryName(app));
    }

    private static string? ReadLine(string path)
    {
        try { return File.ReadAllText(path, Encoding.UTF8).Trim(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}
