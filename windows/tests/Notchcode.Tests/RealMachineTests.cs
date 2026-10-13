// RealMachineTests.cs
// Read-only checks against this PC, run only when NOTCHCODE_REAL=1 (a normal test run skips
// them, so they never depend on the machine): the transcript watcher over the real
// %USERPROFILE%\.claude\projects, and the settings.json round trip on a temp copy of the real
// file. Nothing here writes anywhere but a temp folder.
//
//   $env:NOTCHCODE_REAL = "1"; dotnet test tests/Notchcode.Tests --filter RealMachine --logger "console;verbosity=detailed"

using Notchcode.ClaudeCode;
using Notchcode.Core;
using Notchcode.State;
using Xunit.Abstractions;

namespace Notchcode.Tests;

public sealed class RealMachineTests(ITestOutputHelper output)
{
    private static bool Enabled => Environment.GetEnvironmentVariable("NOTCHCODE_REAL") == "1";

    private sealed class Sink : ITranscriptWatcherSink
    {
        public IReadOnlyList<DiscoveredSession> Last = [];
        public void TranscriptsChanged(IReadOnlyList<DiscoveredSession> sessions) => Last = sessions;
    }

    [Fact]
    public void RealMachineTranscripts()
    {
        if (!Enabled) return;
        var sink = new Sink();
        var watcher = new TranscriptWatcher(sink);
        watcher.PollOnce();
        foreach (var s in sink.Last)
        {
            var prompt = s.LastPrompt is null ? "-" : s.LastPrompt[..Math.Min(60, s.LastPrompt.Length)].ReplaceLineEndings(" ");
            output.WriteLine($"{s.Id} headless={s.IsHeadless} {s.State}/{s.Verb} mode={s.PermissionMode} cwd={s.Cwd} last={s.LastActivityAt:u} prompt={prompt}");
        }

        // The app's merge: headless runs gone, the 2 h cutoff applied, names from the cwd.
        var state = new AppState(new Preferences(), savesPrefs: false);
        state.TranscriptsChanged(sink.Last);
        foreach (var s in state.Sessions)
            output.WriteLine($"listed {s.Id} {s.WorktreeName} repo={s.RepoName} branch={s.Branch} {s.State} newest={state.IsNewest(s)}");
        Assert.DoesNotContain(state.Sessions, s => sink.Last.Any(d => d.IsHeadless && d.Id == s.Id));

        // This repo's own session (the one running the port) is listed with this repo's cwd.
        var repo = FindRepoRoot();
        var mine = state.Sessions.Where(s => TranscriptReader.SamePath(s.Cwd, repo)).ToList();
        output.WriteLine($"repo {repo}: {mine.Count} session(s)");
        Assert.NotEmpty(mine);
        Assert.All(mine, s => Assert.Equal("notchcode", s.WorktreeName));
    }

    [Fact]
    public void RealMachineSettingsRoundTripOnACopy()
    {
        if (!Enabled) return;
        var real = NotchcodePaths.ClaudeSettingsFile;
        if (!File.Exists(real)) return;
        var dir = Directory.CreateTempSubdirectory("nc-real-settings-").FullName;
        try
        {
            var paths = new HookInstallPaths(Path.Combine(dir, "settings.json"), Path.Combine(dir, "chain.json"), Path.Combine(dir, "bin"));
            File.Copy(real, paths.SettingsFile);
            Directory.CreateDirectory(paths.BinDirectory);
            File.WriteAllBytes(paths.HookExecutable, [0x4D, 0x5A]);
            var before = File.ReadAllBytes(paths.SettingsFile);
            Assert.Equal(HooksInstallerStatus.NotConnected, HooksInstaller.Status(paths));
            HooksInstaller.Connect(paths);
            Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(paths));
            var connected = File.ReadAllBytes(paths.SettingsFile);
            HooksInstaller.Connect(paths);
            Assert.Equal(connected, File.ReadAllBytes(paths.SettingsFile));
            HooksInstaller.Disconnect(paths);
            Assert.Equal(before, File.ReadAllBytes(paths.SettingsFile));
            output.WriteLine($"round trip of {before.Length} bytes: identical");
        }
        finally { Directory.Delete(dir, true); }
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "windows"))) dir = dir.Parent;
        // A worktree under .claude\worktrees belongs to the repo above it, where the session runs.
        var path = dir!.FullName;
        int cut = path.IndexOf(@"\.claude\worktrees\", StringComparison.OrdinalIgnoreCase);
        return cut >= 0 ? path[..cut] : path;
    }
}
