// HooksInstaller.cs
// Port of Sources/notchcode/ClaudeCode/HooksInstaller.swift, for Windows.
// Adds and removes notchcode's hooks in %USERPROFILE%\.claude\settings.json, so Settings can
// connect and disconnect without Node. Same rules as scripts/lib/settings.mjs:
//
//   - back up to settings.json.notchcode-backup-<timestamp> before any write; keep the newest 5
//   - a symlinked settings.json stays a link: the file it points at is rewritten
//   - add or replace only hook entries whose command contains "notchcode-hook"
//   - never touch any other entry (Orca's `"shell": "powershell"` / -EncodedCommand hooks,
//     BurntToast, sidecar-pane); an event key is removed only when it ends up empty
//   - 2-space pretty print, top-level and nested key order kept exactly; a file written with
//     CRLF line breaks or a UTF-8 BOM keeps them
//   - statusLine: ours (`notchcode-hook.exe statusline`) replaces whatever was there, which is
//     saved first in %LOCALAPPDATA%\notchcode\statusline-chain.json as
//     {"previous": <old statusLine>, "shell": "bash"|"powershell"} and keeps running through
//     ours, through the shell Claude Code would have used. Disconnect puts it back (or removes
//     the key when there was none) and deletes the chain file.
//   - hooks point at the app's copy of the hook exe in %LOCALAPPDATA%\notchcode\bin\, never
//     into the build output, so moving or updating the app never breaks them. The app
//     refreshes the copy at every launch.
//
// Windows differences (windows/PLAN.md, "Hooks on Windows"): every hook entry uses the exec
// form, `"command": "C:/Users/<me>/AppData/Local/notchcode/bin/notchcode-hook.exe",
// "args": ["permission"]`, which Claude Code spawns directly, with no shell (forward slashes
// so Git Bash never eats a backslash). The status line has no exec form: its command is the
// exe path and `statusline`, quoted for the shell that runs it only when the path needs it.
// SessionStart gets a first command, `notchcode-hook.exe launch`, which starts the app.
//
// The table of hooks must match wantedHooks() in scripts/lib/settings.mjs; the statusLine
// logic matches planStatusLine() there.

using System.IO;
using System.Text;

namespace Notchcode.ClaudeCode;

/// Stale: ours are all there, but they point somewhere other than the bin copy, or at a copy
/// that is gone, or use the string form instead of the exec form, or our PermissionRequest
/// entry still has an older timeout (65 s, before plans).
public enum HooksInstallerStatus { Connected, NotConnected, Partial, Stale }

/// Swift's HooksInstaller.InstallError: the message is what Settings shows.
public sealed class HooksInstallerException(string message) : Exception(message)
{
    public static HooksInstallerException InvalidJson(string why) => new("settings.json is not valid JSON: " + why);
    public static HooksInstallerException NotAnObject(string what) => new(what + " in settings.json is not a JSON object; not touching it");
    public static HooksInstallerException HookExeMissing(string path) => new("hook program missing: " + path);
    public static HooksInstallerException ChainUnreadable(string path) => new("the saved status line in " + path + " is not readable; not touching the status line");
}

/// The files Connect reads and writes. `Default` is the real ones; tests pass copies.
public sealed record HookInstallPaths(string SettingsFile, string ChainFile, string BinDirectory)
{
    public static HookInstallPaths Default
        => new(NotchcodePaths.ClaudeSettingsFile, NotchcodePaths.StatuslineChainFile, NotchcodePaths.BinDirectory);

    /// The copy of the hook exe that settings.json names.
    public string HookExecutable => Path.Combine(BinDirectory, HooksInstaller.HookExeName);

    /// The exe path as settings.json writes it: forward slashes.
    public string HookCommandPath => HookExecutable.Replace('\\', '/');
}

public static class HooksInstaller
{
    /// What makes an entry ours: the hook exe's name, in the string form or the exec form.
    public const string Marker = "notchcode-hook";
    public const string HookExeName = "notchcode-hook.exe";
    /// Keys of the previous statusLine that shape how it looks; ours copies them (same order as settings.mjs).
    private static readonly string[] CarriedStatusLineKeys = ["padding", "refreshInterval"];
    /// Backups kept next to settings.json; older ones we made are deleted. Same in settings.mjs.
    public const int KeptBackups = 5;
    /// The PermissionRequest entry's timeout, in seconds: a plan waits 298 s in the app, the
    /// hook 299 s. scripts/lib/settings.mjs and plugin/hooks/hooks.json say the same.
    public const int PermissionTimeout = 305;

    // MARK: Public

    /// Copies `notchcode-hook.exe` into the bin folder when it is missing or its bytes differ,
    /// and writes `app-path.txt` (this app's exe, for `notchcode-hook.exe launch`) and
    /// `dotnet-root.txt` (DOTNET_ROOT when set) beside it. Runs at every launch and before
    /// every connect. Never throws: a failure is skipped and the next launch or connect tries again.
    /// `sources` (tests) replaces the places the exe is looked for.
    public static void InstallScripts(HookInstallPaths? paths = null, IEnumerable<string>? sources = null)
    {
        paths ??= HookInstallPaths.Default;
        try { Directory.CreateDirectory(paths.BinDirectory); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }

        var source = (sources ?? HookExeCandidates()).FirstOrDefault(File.Exists);
        if (source is not null)
        {
            try
            {
                var data = File.ReadAllBytes(source);
                var target = paths.HookExecutable;
                if (!File.Exists(target) || !File.ReadAllBytes(target).AsSpan().SequenceEqual(data))
                {
                    var tmp = target + ".tmp-" + Environment.ProcessId;
                    File.WriteAllBytes(tmp, data);
                    try { File.Move(tmp, target, overwrite: true); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        // A running hook holds the old copy open: it stays until the next launch.
                        TryDelete(tmp);
                    }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }

        WriteIfChanged(Path.Combine(paths.BinDirectory, "app-path.txt"), Environment.ProcessPath);
        var dotnetRoot = Environment.GetEnvironmentVariable("DOTNET_ROOT");
        if (string.IsNullOrEmpty(dotnetRoot)) TryDelete(Path.Combine(paths.BinDirectory, "dotnet-root.txt"));
        else WriteIfChanged(Path.Combine(paths.BinDirectory, "dotnet-root.txt"), dotnetRoot);
    }

    /// Where a built hook exe can be: beside the app (a release, or the build copied it), then
    /// the hook project's single-file publish output in this source tree (newest first). A plain
    /// `dotnet build` of the hook is not a candidate: its exe needs the dll beside it.
    public static IEnumerable<string> HookExeCandidates()
    {
        var baseDir = AppContext.BaseDirectory;
        yield return Path.Combine(baseDir, HookExeName);
        var dir = new DirectoryInfo(baseDir);
        while (dir is not null)
        {
            var hookBin = Path.Combine(dir.FullName, "src", "Notchcode.Hook", "bin");
            if (Directory.Exists(hookBin))
            {
                List<FileInfo> found;
                try
                {
                    found = new DirectoryInfo(hookBin).EnumerateFiles(HookExeName, SearchOption.AllDirectories)
                        .Where(f => string.Equals(f.Directory?.Name, "publish", StringComparison.OrdinalIgnoreCase))
                        .OrderByDescending(f => f.LastWriteTimeUtc)
                        .ToList();
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { found = []; }
                foreach (var f in found) yield return f.FullName;
                yield break;
            }
            dir = dir.Parent;
        }
    }

    /// Connected means every hook and the statusLine are ours; partial means some are.
    /// Either one turns stale when an entry of ours does not name the bin folder, names a
    /// copy that is not there, or is not in the exec form.
    public static HooksInstallerStatus Status(HookInstallPaths? paths = null)
    {
        paths ??= HookInstallPaths.Default;
        SettingsFile file;
        try { file = ReadSettings(paths.SettingsFile); }
        catch (Exception e) when (e is HooksInstallerException or IOException or UnauthorizedAccessException)
        {
            return HooksInstallerStatus.NotConnected;
        }
        if (file.Root.Members is not { } top) return HooksInstallerStatus.NotConnected;
        var hooks = Get(top, "hooks")?.Members ?? [];
        var events = WantedEventNames;
        int present = events.Count(evt => Get(hooks, evt)?.Items is { } list && list.Any(GroupHasOurs));
        var line = Get(top, "statusLine");
        bool lineOurs = line is not null && IsOurStatusLine(line);
        int count = present + (lineOurs ? 1 : 0);
        if (count == 0) return HooksInstallerStatus.NotConnected;
        if (IsStale(hooks, lineOurs ? line : null, paths)) return HooksInstallerStatus.Stale;
        return count == events.Count + 1 ? HooksInstallerStatus.Connected : HooksInstallerStatus.Partial;
    }

    /// True when one of our commands does not point into the bin folder, the copy it runs is
    /// missing, a hook of ours is in the string form, or our PermissionRequest hook's timeout
    /// is not the wanted one (a plan needs 305 s).
    private static bool IsStale(IReadOnlyList<OJMember> hooks, OJ? line, HookInstallPaths paths)
    {
        var bin = NormalizeForCompare(paths.BinDirectory);
        var hookCommands = new List<string>();
        foreach (var member in hooks)
        {
            if (member.Value.Items is not { } groups) continue;
            foreach (var group in groups)
            {
                foreach (var hook in HooksList(group) ?? [])
                {
                    if (!IsOurs(hook)) continue;
                    if (Command(hook) is { } c) hookCommands.Add(c);
                    if (hook["args"]?.Items is null) return true;
                    if (member.Key == "PermissionRequest" && Timeout(hook) != PermissionTimeout) return true;
                }
            }
        }
        if (hookCommands.Any(c => !NormalizeForCompare(c).Contains(bin, StringComparison.Ordinal))) return true;
        if (hookCommands.Count > 0 && !File.Exists(paths.HookExecutable)) return true;
        if (line is not null && Command(line) is { } lc)
        {
            if (!NormalizeForCompare(lc).Contains(bin, StringComparison.Ordinal)) return true;
            if (!File.Exists(paths.HookExecutable)) return true;
        }
        return false;
    }

    /// Adds our hooks and status line. `shell` (tests) overrides which shell the chained status
    /// line runs through: "bash" when Git Bash is installed, else "powershell".
    public static void Connect(HookInstallPaths? paths = null, string? shell = null)
    {
        paths ??= HookInstallPaths.Default;
        var path = paths.SettingsFile;
        // Hooks name the bin copy, so make sure it is there and current first.
        InstallScripts(paths);
        if (!File.Exists(paths.HookExecutable)) throw HooksInstallerException.HookExeMissing(paths.HookExecutable);
        shell ??= StatusLineShell();

        var exe = paths.HookCommandPath;
        var wanted = WantedHooks(exe);
        var lineCommand = StatusLineCommand(exe, shell);

        var file = ReadSettings(path);
        if (file.Root.Members is not { } topList) throw HooksInstallerException.NotAnObject("the top level");
        var top = topList.ToList();
        var before = file.Root;

        var hooks = new List<OJMember>();
        int hooksIndex = top.FindIndex(m => m.Key == "hooks");
        if (hooksIndex >= 0)
        {
            if (top[hooksIndex].Value.Members is not { } h) throw HooksInstallerException.NotAnObject("\"hooks\"");
            hooks = h.ToList();
        }

        foreach (var (evt, group) in wanted)
        {
            int existingIndex = hooks.FindIndex(m => m.Key == evt);
            IReadOnlyList<OJ> existing = existingIndex >= 0 ? hooks[existingIndex].Value.Items ?? [] : [];
            var stripped = StripOurs(existing);
            var oldOurs = existing.Where(GroupHasOurs).ToList();
            int wantedCount = HooksList(group)?.Count ?? 0;
            if (stripped.Removed == wantedCount && oldOurs.Count == 1 && oldOurs[0].Canonical == group.Canonical) continue;

            var groups = stripped.Groups;
            groups.Insert(stripped.FirstIndex ?? groups.Count, group);
            if (existingIndex >= 0)
                hooks[existingIndex] = hooks[existingIndex] with { Value = OJ.Array(groups) };
            else
                hooks.Add(new OJMember(evt, OJ.Array(groups)));
        }

        // Our entries on events we no longer install (older versions).
        var wantedNames = wanted.Select(w => w.Event).ToHashSet();
        hooks = hooks.Select(member =>
        {
            if (wantedNames.Contains(member.Key) || member.Value.Items is not { } a) return member;
            var stripped = StripOurs(a);
            if (stripped.Removed == 0) return member;
            if (stripped.Groups.Count == 0) return null;
            return member with { Value = OJ.Array(stripped.Groups) };
        }).OfType<OJMember>().ToList();

        if (hooksIndex >= 0) top[hooksIndex] = top[hooksIndex] with { Value = OJ.Object(hooks) };
        else top.Add(new OJMember("hooks", OJ.Object(hooks)));

        // statusLine: ours, with the previous one chained.
        OJ? chainWrite = null;
        bool chainRemove = false;
        int lineIndex = top.FindIndex(m => m.Key == "statusLine");
        if (lineIndex >= 0 && IsOurStatusLine(top[lineIndex].Value))
        {
            // Already ours: only bring the command up to date.
            if (top[lineIndex].Value.Members is { } m)
            {
                var list = m.ToList();
                int c = list.FindIndex(x => x.Key == "command");
                if (c >= 0 && list[c].Value.Canonical != OJ.String(lineCommand).Canonical)
                {
                    list[c] = list[c] with { Value = OJ.String(lineCommand) };
                    top[lineIndex] = top[lineIndex] with { Value = OJ.Object(list) };
                }
            }
        }
        else
        {
            var ours = new List<OJMember>
            {
                new("type", OJ.String("command")),
                new("command", OJ.String(lineCommand)),
            };
            if (lineIndex >= 0 && top[lineIndex].Value.Members is { } old)
            {
                foreach (var key in CarriedStatusLineKeys)
                    if (old.FirstOrDefault(x => x.Key == key) is { } carried) ours.Add(new OJMember(key, carried.Value));
            }
            if (lineIndex >= 0)
            {
                chainWrite = top[lineIndex].Value;
                top[lineIndex] = top[lineIndex] with { Value = OJ.Object(ours) };
            }
            else
            {
                chainRemove = true;
                top.Add(new OJMember("statusLine", OJ.Object(ours)));
            }
        }

        file = file with { Root = OJ.Object(top) };
        if (file.Existed && file.Root.Canonical == before.Canonical) return;
        // Chain file first: the status line must never point at ours before the old one is saved.
        if (chainWrite is not null) WriteChain(paths.ChainFile, chainWrite, shell);
        else if (chainRemove) TryDelete(paths.ChainFile);
        WriteSettings(path, file);
    }

    public static void Disconnect(HookInstallPaths? paths = null)
    {
        paths ??= HookInstallPaths.Default;
        var path = paths.SettingsFile;
        var file = ReadSettings(path);
        if (!file.Existed) return;
        if (file.Root.Members is not { } topList) throw HooksInstallerException.NotAnObject("the top level");
        var top = topList.ToList();

        bool changed = false;
        bool restored = false;

        // statusLine: put back the saved one, or remove ours when there was none.
        // A statusLine that is not ours (changed by hand since) is left alone.
        int li = top.FindIndex(m => m.Key == "statusLine");
        if (li >= 0 && IsOurStatusLine(top[li].Value))
        {
            if (ReadChain(paths.ChainFile) is { } previous)
                top[li] = top[li] with { Value = previous };
            else
                top.RemoveAt(li);
            changed = true;
            restored = true;
        }

        int hi = top.FindIndex(m => m.Key == "hooks");
        if (hi >= 0 && top[hi].Value.Members is { } hooks)
        {
            bool hooksChanged = false;
            var kept = hooks.Select(member =>
            {
                if (member.Value.Items is not { } a) return member;
                var stripped = StripOurs(a);
                if (stripped.Removed == 0) return member;
                hooksChanged = true;
                if (stripped.Groups.Count == 0) return null;
                return member with { Value = OJ.Array(stripped.Groups) };
            }).OfType<OJMember>().ToList();
            if (hooksChanged)
            {
                // Emptied by taking ours out: the key goes, so a file that had no "hooks" before
                // Connect comes back byte for byte. (disconnect.mjs leaves {}; an owner's own
                // empty "hooks": {} is never touched, since nothing of ours was in it.)
                if (kept.Count == 0) top.RemoveAt(hi);
                else top[hi] = top[hi] with { Value = OJ.Object(kept) };
                changed = true;
            }
        }
        if (!changed) return;
        WriteSettings(path, file with { Root = OJ.Object(top) });
        // Chain file last: until settings.json is written, ours may still run and needs it.
        if (restored) TryDelete(paths.ChainFile);
    }

    /// `--connect` / `--disconnect` / `--hooks-status` on the app's command line, for
    /// scripts/connect.ps1 and disconnect.ps1. Returns the exit code, or null when none of
    /// them is given (the app starts normally). The app's startup calls it before any window.
    ///
    /// Exit codes: `--connect` and `--disconnect` 0 when done, 1 when settings.json was left
    /// as it was (the reason on stderr). `--hooks-status` prints one word on stdout
    /// (`connected`, `not-connected`, `partial`, `stale`) and exits with the status's number
    /// (0, 1, 2, 3). A WinExe has a stdout only when the caller redirects it
    /// (`notchcode.exe --hooks-status | Write-Output`). `paths` (tests) replaces the real files.
    public static int? HandleCommandLine(IReadOnlyList<string> args, HookInstallPaths? paths = null)
    {
        bool Has(string flag) => args.Any(a => string.Equals(a, flag, StringComparison.OrdinalIgnoreCase));
        try
        {
            if (Has("--connect")) { Connect(paths); return 0; }
            if (Has("--disconnect")) { Disconnect(paths); return 0; }
            if (Has("--hooks-status"))
            {
                var status = Status(paths);
                try { Console.Out.WriteLine(StatusWord(status)); Console.Out.Flush(); } catch (IOException) { }
                return (int)status;
            }
        }
        // Anything else that goes wrong must still end the run with an exit code, never as an
        // unhandled exception in the app's startup.
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            try { Console.Error.WriteLine(e.Message); } catch (IOException) { }
            return 1;
        }
        return null;
    }

    /// The word `--hooks-status` prints.
    public static string StatusWord(HooksInstallerStatus status) => status switch
    {
        HooksInstallerStatus.Connected => "connected",
        HooksInstallerStatus.Partial => "partial",
        HooksInstallerStatus.Stale => "stale",
        _ => "not-connected",
    };

    // MARK: The hooks we install

    private static IReadOnlyList<string> WantedEventNames => WantedHooks("x").Select(w => w.Event).ToList();

    /// Mirrors wantedHooks() in scripts/lib/settings.mjs, same order, same key order, in the
    /// exec form (`command` is the exe, `args` the kind). SessionStart also launches the app first.
    private static List<(string Event, OJ Group)> WantedHooks(string exe)
    {
        OJ Handler(string kind, int timeout, bool async, string? ifRule = null)
        {
            var m = new List<OJMember> { new("type", OJ.String("command")) };
            if (ifRule is not null) m.Add(new OJMember("if", OJ.String(ifRule)));
            m.Add(new OJMember("command", OJ.String(exe)));
            m.Add(new OJMember("args", OJ.Array([OJ.String(kind)])));
            m.Add(new OJMember("timeout", OJ.Number(timeout.ToString(System.Globalization.CultureInfo.InvariantCulture))));
            if (async) m.Add(new OJMember("async", OJ.Bool(true)));
            return OJ.Object(m);
        }
        OJ Group(string? matcher, params OJ[] handlers)
        {
            var m = new List<OJMember>();
            if (matcher is not null) m.Add(new OJMember("matcher", OJ.String(matcher)));
            m.Add(new OJMember("hooks", OJ.Array(handlers)));
            return OJ.Object(m);
        }
        OJ Passive(string kind) => Handler(kind, 5, async: true);
        return
        [
            ("PermissionRequest", Group(null, Handler("permission", PermissionTimeout, async: false))),
            ("PreToolUse", Group("Bash", Handler("pre_tool", 65, async: false, ifRule: "Bash(git commit *)"))),
            ("PostToolUse", Group("Edit|Write|MultiEdit|Bash", Passive("post_tool"))),
            ("Notification", Group(null, Passive("notification"))),
            ("Stop", Group(null, Passive("stop"))),
            ("SessionStart", Group(null, Passive("launch"), Passive("session_start"))),
            ("SessionEnd", Group(null, Passive("session_end"))),
            ("UserPromptSubmit", Group(null, Passive("user_prompt"))),
            ("SubagentStart", Group(null, Passive("subagent_start"))),
            ("SubagentStop", Group(null, Passive("subagent_stop"))),
        ];
    }

    /// The status line command: the exe and `statusline`. A path with nothing a shell treats
    /// specially goes as is (true for most user names), which both Git Bash and PowerShell run.
    /// Otherwise it is quoted for the shell that will run it: '…' for bash, & '…' for PowerShell.
    public static string StatusLineCommand(string exe, string shell)
    {
        bool safe = exe.Length > 0 && exe.All(c => char.IsAsciiLetterOrDigit(c) || "_./:@%+=-".Contains(c));
        if (safe) return exe + " statusline";
        if (shell == "bash") return "'" + exe.Replace("'", "'\\''") + "' statusline";
        return "& '" + exe.Replace("'", "''") + "' statusline";
    }

    /// The shell Claude Code runs a string command through on this PC: Git Bash when it is
    /// installed, else PowerShell.
    public static string StatusLineShell() => FindBash() is not null ? "bash" : "powershell";

    /// Git Bash: CLAUDE_CODE_GIT_BASH_PATH, then bash.exe on PATH (never System32's WSL
    /// launcher), then the Git for Windows default folder. Null when none exists.
    public static string? FindBash()
    {
        var env = Environment.GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env)) return env;
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim().Trim('"'), "bash.exe");
                if (!File.Exists(candidate)) continue;
                var full = Path.GetFullPath(candidate);
                if (full.StartsWith(system, StringComparison.OrdinalIgnoreCase)) continue;
                if (full.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase)) continue;
                return full;
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var git = Path.Combine(programFiles, "Git", "bin", "bash.exe");
        return File.Exists(git) ? git : null;
    }

    // MARK: Ours vs theirs

    private static OJ? Get(IReadOnlyList<OJMember> members, string key) => members.FirstOrDefault(m => m.Key == key)?.Value;

    /// The "command" string of a hook or a statusLine object.
    private static string? Command(OJ entry) => entry["command"]?.StringValue;

    /// The "timeout" number of a hook, in seconds.
    private static double? Timeout(OJ hook)
        => hook["timeout"]?.NumberLiteral is { } n
           && double.TryParse(n, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d)
            ? d : null;

    private static bool IsOurs(OJ hook) => Command(hook)?.Contains(Marker, StringComparison.OrdinalIgnoreCase) ?? false;

    private static bool IsOurStatusLine(OJ line) => Command(line)?.Contains(Marker, StringComparison.OrdinalIgnoreCase) ?? false;

    private static IReadOnlyList<OJ>? HooksList(OJ group) => group.Kind == OJKind.Object ? group["hooks"]?.Items : null;

    private static bool GroupHasOurs(OJ group) => HooksList(group)?.Any(IsOurs) ?? false;

    /// Drops our hooks from each group; a group left with no hooks is dropped too.
    private static (List<OJ> Groups, int? FirstIndex, int Removed) StripOurs(IReadOnlyList<OJ> groups)
    {
        var output = new List<OJ>();
        int? first = null;
        int removed = 0;
        foreach (var group in groups)
        {
            if (HooksList(group) is not { } list || !list.Any(IsOurs) || group.Members is not { } members)
            {
                output.Add(group);
                continue;
            }
            first ??= output.Count;
            var kept = list.Where(h => !IsOurs(h)).ToList();
            removed += list.Count - kept.Count;
            if (kept.Count == 0) continue;
            output.Add(OJ.Object(members.Select(m => m.Key == "hooks" ? m with { Value = OJ.Array(kept) } : m)));
        }
        return (output, first, removed);
    }

    /// Lower case, forward slashes: Windows paths compare that way.
    private static string NormalizeForCompare(string path) => path.Replace('\\', '/').ToLowerInvariant();

    // MARK: Chain file

    /// The saved statusLine, verbatim; null when no chain file exists or it saved none.
    /// A chain file that exists but cannot be parsed throws, so the status line is not guessed at.
    private static OJ? ReadChain(string path)
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return null; }
        OJ root;
        try { root = OJParser.Parse(data); }
        catch (OJParseException) { throw HooksInstallerException.ChainUnreadable(path); }
        if (root.Members is not { } m) throw HooksInstallerException.ChainUnreadable(path);
        return Get(m, "previous");
    }

    /// Writes {"previous": <statusLine>, "shell": …} atomically, 2-space pretty.
    private static void WriteChain(string path, OJ previous, string shell)
    {
        // A status line that names its own shell ran through it; the chain says so too
        // (the hook reads `previous.shell` first either way).
        if (previous["shell"]?.StringValue is "bash" or "powershell") shell = previous["shell"]!.StringValue!;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var text = OJ.Object([new OJMember("previous", previous), new OJMember("shell", OJ.String(shell))]).Pretty() + "\n";
        var tmp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllBytes(tmp, new UTF8Encoding(false).GetBytes(text));
        try { File.Move(tmp, path, overwrite: true); }
        catch { TryDelete(tmp); throw; }
    }

    // MARK: File

    private sealed record SettingsFile(OJ Root, bool Existed, bool TrailingNewline, bool Crlf, bool Bom);

    private static SettingsFile ReadSettings(string path)
    {
        if (!File.Exists(path)) return new SettingsFile(OJ.Object([]), false, true, false, false);
        var data = File.ReadAllBytes(path);
        bool bom = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF;
        var text = Encoding.UTF8.GetString(data, bom ? 3 : 0, data.Length - (bom ? 3 : 0));
        bool crlf = text.Contains("\r\n", StringComparison.Ordinal);
        if (text.Trim().Length == 0) return new SettingsFile(OJ.Object([]), true, true, crlf, bom);
        OJ root;
        try { root = OJParser.Parse(data); }
        catch (OJParseException e) { throw HooksInstallerException.InvalidJson(e.Message); }
        if (root.Kind != OJKind.Object) throw HooksInstallerException.NotAnObject("the top level");
        return new SettingsFile(root, true, text.EndsWith('\n'), crlf, bom);
    }

    /// Backs up (when the file exists), then writes atomically. A symlinked settings.json (a
    /// dotfiles repo) stays a link: the write and the backup's content come from the file it
    /// points at, and the temp file sits in that file's folder so the move replaces the file,
    /// not the link.
    private static void WriteSettings(string path, SettingsFile file)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var target = RealPath(path) ?? path;
        if (file.Existed)
        {
            var stamp = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture)
                .Replace(':', '-').Replace('.', '-');
            // The backup holds the content, never a copy of the link.
            File.Copy(target, path + ".notchcode-backup-" + stamp, overwrite: true);
            PruneBackups(path);
        }
        var text = file.Root.Pretty();
        if (file.TrailingNewline) text += "\n";
        if (file.Crlf) text = text.Replace("\n", "\r\n");
        var bytes = new UTF8Encoding(file.Bom).GetPreamble().Concat(new UTF8Encoding(false).GetBytes(text)).ToArray();
        var tmp = target + ".notchcode-tmp-" + Environment.ProcessId;
        File.WriteAllBytes(tmp, bytes);
        try
        {
            File.Move(tmp, target, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Another process holds settings.json open without delete sharing: write in place.
            TryDelete(tmp);
            File.WriteAllBytes(target, bytes);
        }
    }

    /// The path with every link resolved, or null when it does not exist.
    private static string? RealPath(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return null;
            if (info.LinkTarget is not null && info.ResolveLinkTarget(returnFinalTarget: true) is { } t) return t.FullName;
            return info.FullName;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
    }

    /// Keeps the newest `KeptBackups` `<settings>.notchcode-backup-*` (the timestamps sort by
    /// name); only files with exactly that prefix, which only we make, are deleted.
    private static void PruneBackups(string path)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var prefix = Path.GetFileName(path) + ".notchcode-backup-";
        List<string> ours;
        try
        {
            ours = Directory.EnumerateFiles(dir).Select(Path.GetFileName).OfType<string>()
                .Where(n => n.StartsWith(prefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        foreach (var name in ours.Take(Math.Max(0, ours.Count - KeptBackups)))
            TryDelete(Path.Combine(dir, name));
    }

    private static void WriteIfChanged(string path, string? text)
    {
        if (text is null) return;
        try
        {
            if (File.Exists(path) && File.ReadAllText(path) == text) return;
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
