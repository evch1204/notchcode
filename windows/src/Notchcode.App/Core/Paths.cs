// Paths.cs
// Port of the NotchcodePaths enum at the end of Sources/notchcode/Core/Contract.swift, with
// the Windows locations from windows/PLAN.md ("Paths and names on Windows").
// Linked into the hook project: no WPF types here.

using System.IO;
using System.Text;

namespace Notchcode.Core;

public static class NotchcodePaths
{
    /// %LOCALAPPDATA%\notchcode: the app's own state (macOS: ~/Library/Application Support/notchcode).
    public static string SupportDirectory
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "notchcode");

    /// "notchcode-&lt;username&gt;": the named pipe the hooks talk to (macOS: notchcode.sock).
    /// The user name keeps two accounts on one PC apart.
    public static string PipeName => "notchcode-" + Sanitize(Environment.UserName);

    /// The pipe's full path, \\.\pipe\notchcode-&lt;username&gt;.
    public static string PipePath => @"\\.\pipe\" + PipeName;

    /// The app's own copy of the hook exe, so hooks never point into the build output.
    public static string BinDirectory => Path.Combine(SupportDirectory, "bin");

    /// The hook exe the settings.json entries run.
    public static string HookExecutable => Path.Combine(BinDirectory, "notchcode-hook.exe");

    /// Claude Code's config folder: CLAUDE_CONFIG_DIR when set, else %USERPROFILE%\.claude.
    public static string ClaudeConfigDir
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (!string.IsNullOrWhiteSpace(env)) return env;
            return Path.Combine(UserProfile, ".claude");
        }
    }

    public static string ClaudeProjectsDirectory => Path.Combine(ClaudeConfigDir, "projects");
    public static string ClaudePlansDirectory => Path.Combine(ClaudeConfigDir, "plans");
    public static string ClaudeSettingsFile => Path.Combine(ClaudeConfigDir, "settings.json");

    /// Claude Code's own config, which caches the last `/usage` answer (`cachedUsageUtilization`).
    public static string ClaudeConfigFile => Path.Combine(UserProfile, ".claude.json");

    /// The working folder of the headless `claude -p /usage` run, so its transcript has a project of its own.
    public static string UsageRunDirectory => Path.Combine(SupportDirectory, "usage");

    /// The owner's choices (macOS keeps them in UserDefaults).
    public static string PreferencesFile => Path.Combine(SupportDirectory, "preferences.json");

    /// The status line the owner had before Connect, run after ours with the same stdin.
    public static string StatuslineChainFile => Path.Combine(SupportDirectory, "statusline-chain.json");

    /// One stamp per session: when the status line last forwarded (at most every 5 s).
    public static string StatuslineStampsDirectory => Path.Combine(SupportDirectory, "statusline-stamps");

    /// Shell-changed files per session, &lt;session&gt;.json.
    public static string ShellChangesDirectory => Path.Combine(SupportDirectory, "shell-changes");

    /// Claude Code's folder name for a project under `projects`: the cwd with every character
    /// that is not [A-Za-z0-9] replaced by '-' (C:\Users\evanc\x y → C--Users-evanc-x-y),
    /// truncated to 200 characters. Claude Code appends a hash to names past 200; that suffix
    /// is not implemented here, so a reader must match long names by prefix.
    public static string ProjectFolderName(string cwd)
    {
        var sb = new StringBuilder(cwd.Length);
        foreach (var c in cwd)
            sb.Append(c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') ? c : '-');
        var name = sb.ToString();
        return name.Length > 200 ? name[..200] : name;
    }

    private static string UserProfile => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// Keeps [A-Za-z0-9._-]; anything else becomes '-'. Empty becomes "user".
    private static string Sanitize(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
            sb.Append(c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '.' or '_' or '-' ? c : '-');
        return sb.Length == 0 ? "user" : sb.ToString();
    }
}
