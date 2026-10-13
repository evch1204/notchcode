// DebugLog.cs
// Port of Sources/notchcode/App/DebugLog.swift: one line per call to
// %LOCALAPPDATA%\notchcode\debug.log, only when the app was launched with --debug-log. Used for
// the mode and frame trace a smoke run reads.

using System.IO;

namespace Notchcode.App;

public static class DebugLog
{
    private static readonly bool enabled =
        Environment.GetCommandLineArgs().Any(a => string.Equals(a, "--debug-log", StringComparison.OrdinalIgnoreCase));
    private static readonly object gate = new();

    /// Appends `text` with a timestamp when launched with --debug-log; otherwise nothing.
    public static void Write(string text)
    {
        if (!enabled) return;
        try
        {
            lock (gate)
            {
                Directory.CreateDirectory(NotchcodePaths.SupportDirectory);
                File.AppendAllText(Path.Combine(NotchcodePaths.SupportDirectory, "debug.log"),
                    $"{DateTime.UtcNow:O} {text}\n");
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
