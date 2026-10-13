// AppState.PlanUsage.cs
// Port of Sources/notchcode/Features/Usage/AppState+PlanUsage.swift.
// Plan usage for the Usage tool: Claude Code's usage cache in %USERPROFILE%\.claude.json,
// refreshed by a headless `claude -p /usage` run 5 s after launch, every 15 minutes while
// Settings allows it, when the Usage pane shows and its cache is older than 5 minutes, and on
// R. Never in the demo.

using Notchcode.Features.Usage;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    public const string PlanUsageNotFound = "claude command not found";
    public const string PlanUsageFailed = "couldn't run claude";

    /// At launch (not in the demo): what the cache already holds, then the schedule.
    public void StartPlanUsage()
    {
        if (!ReadsLocalFiles) return;
        HeadlessIds.Add(PlanUsageRunner.SessionId());
        LoadPlanUsageCache();
        SchedulePlanUsage();
    }

    /// The first run after `PlanUsageLaunchDelay`, then one every `PlanUsageInterval`, while the pref is on.
    public void SchedulePlanUsage()
    {
        PlanUsageTask?.Cancel();
        PlanUsageTask = null;
        if (!ReadsLocalFiles || !Prefs.PlanUsageRefresh) return;
        var cts = new CancellationTokenSource();
        PlanUsageTask = cts;
        _ = PlanUsageLoopAsync(cts.Token);
    }

    private async Task PlanUsageLoopAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(Theme.Timing.PlanUsageLaunchDelay), token);
            while (!token.IsCancellationRequested)
            {
                RefreshPlanUsage(force: false);
                await Task.Delay(TimeSpan.FromSeconds(Theme.Timing.PlanUsageInterval), token);
            }
        }
        catch (TaskCanceledException) { }
    }

    /// Settings → Usage: off stops the schedule, on starts it again.
    public void PlanUsagePrefChanged() => SchedulePlanUsage();

    /// The Usage pane came on screen: pick up a newer cache (Claude Code writes it on every
    /// `/usage`), and refresh when it is stale.
    public void UsagePaneShown()
    {
        LoadPlanUsageCache();
        RefreshPlanUsage(force: false);
    }

    /// Reads the cache off the UI thread and keeps it when it is newer than what is on hand.
    public void LoadPlanUsageCache()
    {
        if (!ReadsLocalFiles) return;
        _ = LoadPlanUsageCacheAsync();
    }

    private async Task LoadPlanUsageCacheAsync()
    {
        var read = await Task.Run(() => PlanUsageReader.Read());
        if (read is not null && read.FetchedAt > (PlanUsage?.FetchedAt ?? DateTime.MinValue)) PlanUsage = read;
        RecomputeUsage();
    }

    /// One `claude -p /usage` run. Not in the demo, not while one runs; unless forced (R),
    /// not with the pref off, not when the cache is younger than `PlanUsageStaleAfter`, and
    /// not again once no `claude.exe` was found.
    public void RefreshPlanUsage(bool force)
    {
        if (!ReadsLocalFiles || PlanUsageRefreshing) return;
        if (!force)
        {
            if (!Prefs.PlanUsageRefresh || PlanUsageNote == PlanUsageNotFound) return;
            if (PlanUsage?.FetchedAt is DateTime fetched && (DateTime.UtcNow - fetched).TotalSeconds < Theme.Timing.PlanUsageStaleAfter) return;
        }
        // The run's own session must never surface, whatever reaches the app about it.
        HeadlessIds.Add(PlanUsageRunner.SessionId());
        PlanUsageRefreshing = true;
        _ = RefreshPlanUsageAsync(force);
    }

    private async Task RefreshPlanUsageAsync(bool force)
    {
        var (text, error) = await Task.Run(() => PlanUsageRunner.RunAsync(resolveAgain: force));
        PlanUsageRefreshing = false;
        if (text is not null)
        {
            PlanUsageNote = null;
            if (PlanUsageReader.Behaviors(text) is { } behaviors) UsageBehaviors = behaviors;
            LoadPlanUsageCache();
        }
        else
        {
            PlanUsageNote = error == PlanUsageError.NotFound ? PlanUsageNotFound : PlanUsageFailed;
        }
    }
}
