// PanesHarnessTests.cs
// Wave 1c's pane harness (Features/PanesHarness.cs): renders the Sessions, Changes, Files and
// Usage panes with sample data to PNGs when NOTCHCODE_PANES_OUT names a folder; otherwise it
// does nothing, so the normal test run never opens a window. Plus the pure parts of those
// panes: the Markdown parser, the ignore globs, the usage cache reader, the timeline blocks.

using Notchcode.Core;
using Notchcode.Features;
using Notchcode.Features.Changes;
using Notchcode.Features.Files;
using Notchcode.Features.Usage;
using Notchcode.State;

namespace Notchcode.Tests;

public class PanesHarnessTests
{
    [Fact]
    public void RendersPanesWhenAsked()
    {
        var dir = Environment.GetEnvironmentVariable("NOTCHCODE_PANES_OUT");
        if (string.IsNullOrEmpty(dir)) return;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try { PanesHarness.RenderAll(dir); }
            catch (Exception e) { error = e; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (error is not null) throw new Exception("harness failed", error);
    }

    /// Runs the owner's real `claude.exe -p /usage` once and reads the real `.claude.json`, when
    /// NOTCHCODE_PLAN_USAGE_LIVE names a file to write what came back to. Off in a normal run:
    /// it starts a process and touches %LOCALAPPDATA%\notchcode\usage.
    [Fact]
    public async Task RunsThePlanUsageRunnerWhenAsked()
    {
        var report = Environment.GetEnvironmentVariable("NOTCHCODE_PLAN_USAGE_LIVE");
        if (string.IsNullOrEmpty(report)) return;
        var started = DateTime.UtcNow;
        var (text, error) = await PlanUsageRunner.RunAsync();
        var took = DateTime.UtcNow - started;
        var plan = PlanUsageReader.Read();
        var behaviors = text is null ? null : PlanUsageReader.Behaviors(text);
        var lines = new List<string>
        {
            $"took: {took.TotalMilliseconds:0} ms",
            $"error: {error?.ToString() ?? "none"}",
            $"session: {PlanUsageRunner.SessionId()}",
            $"transcript exists: {File.Exists(PlanUsageRunner.TranscriptPath(PlanUsageRunner.SessionId()))}",
            "text:", text ?? "(none)",
            $"behaviors day: {behaviors?.Day?.Title} {behaviors?.Day?.Requests} req, {behaviors?.Day?.Lines.Count} lines",
            $"behaviors week: {behaviors?.Week?.Title} {behaviors?.Week?.Requests} req, {behaviors?.Week?.Lines.Count} lines",
            $"cache fetched: {plan?.FetchedAt:o}",
            $"5h: {plan?.FiveHourPercent} resets {plan?.FiveHourResetsAt:o}",
            $"week: {plan?.WeekPercent} resets {plan?.WeekResetsAt:o}",
            $"model weeks: {string.Join("; ", plan?.ModelWeeks.Select(w => $"{w.Name} {w.Percent} {w.ResetsAt:o}") ?? [])}",
            $"breakdown: {string.Join("; ", plan?.WeekBreakdown.Select(s => $"{s.Name} {s.Percent}") ?? [])}",
        };
        File.WriteAllLines(report, lines);
        Assert.Null(error);
        Assert.NotNull(plan);
    }

    [Fact]
    public void ParsesMarkdownBlocks()
    {
        var blocks = MarkdownParser.Parse(
        [
            "# Plan: notch", "", "Some **bold** and `code` and [a link](https://x.y).", "",
            "- one", "  - two", "1. first", "", "> quoted", "", "```", "let x = 1", "```", "", "---", "",
            "| a | b |", "|---|---|", "| 1 | 2 |",
        ]);
        Assert.IsType<MarkdownBlockKind.Heading>(blocks[0].Kind);
        var paragraph = Assert.IsType<MarkdownBlockKind.Paragraph>(blocks[1].Kind);
        Assert.Contains(paragraph.Text.Runs, r => r.Style.HasFlag(InlineStyle.Bold) && r.Text == "bold");
        Assert.Contains(paragraph.Text.Runs, r => r.Style.HasFlag(InlineStyle.Code) && r.Text == "code");
        Assert.Contains(paragraph.Text.Runs, r => r.Link == "https://x.y" && r.Text == "a link");
        var list = Assert.IsType<MarkdownBlockKind.List>(blocks[2].Kind);
        Assert.Equal(3, list.Items.Count);
        Assert.Equal(1, list.Items[1].Depth);
        Assert.Equal("1.", list.Items[2].Marker);
        Assert.IsType<MarkdownBlockKind.Quote>(blocks[3].Kind);
        Assert.IsType<MarkdownBlockKind.Code>(blocks[4].Kind);
        Assert.IsType<MarkdownBlockKind.Rule>(blocks[5].Kind);
        var table = Assert.IsType<MarkdownBlockKind.Table>(blocks[6].Kind);
        Assert.Equal(2, table.Header.Count);
        Assert.Single(table.Rows);
    }

    [Fact]
    public void IgnoreRulesMatchLikeGit()
    {
        var rules = new RepoFiles.IgnoreRules("bin/\n*.log\n/out\ndocs/**/*.tmp\n!keep.log\n");
        Assert.True(rules.Matches("src/bin", "bin", isDirectory: true));
        Assert.False(rules.Matches("src/bin", "bin", isDirectory: false));
        Assert.True(rules.Matches("a/b/x.LOG", "x.LOG", isDirectory: false));
        Assert.True(rules.Matches("out", "out", isDirectory: true));
        Assert.False(rules.Matches("src/out", "out", isDirectory: true));
        Assert.True(Glob.Match("*.cs", "Theme.cs", pathName: false));
        Assert.False(Glob.Match("a/*", "a/b/c", pathName: true));
        Assert.True(Glob.Match("[!x]y", "zy", pathName: false));
    }

    [Fact]
    public void ReadsTheUsageCache()
    {
        var plan = PlanUsageReader.Parse("""
            {"cachedUsageUtilization": {"fetchedAtMs": 1760000000000, "utilization": {
              "five_hour": {"utilization": 61, "resets_at": "2026-10-12T15:00:00Z"},
              "limits": [{"kind": "weekly_all", "percent": 93},
                         {"kind": "weekly_scoped", "percent": 41, "scope": {"model": {"display_name": "Fable"}}}],
              "seven_day_breakdown": {"rows": [{"display_name": "Chats", "percent": 0}, {"key": "Claude Code", "percent": 98}]}}}}
            """);
        Assert.NotNull(plan);
        Assert.Equal(61, plan!.FiveHourPercent);
        Assert.Equal(93, plan.WeekPercent);
        Assert.Equal("Fable", Assert.Single(plan.ModelWeeks).Name);
        Assert.Equal("Claude Code", plan.WeekBreakdown[0].Name);

        var behaviors = PlanUsageReader.Behaviors("What's contributing\nLast 24h · 155 requests · 2 sessions\n  94% of your usage came from x\nLast 7d · 1,204 requests · 19 sessions\n");
        Assert.Equal(155, behaviors!.Day!.Requests);
        Assert.Single(behaviors.Day.Lines);
    }

    [Fact]
    public void TimelineFoldsQuietTurnsAndKeepsTheLiveTurnFirst()
    {
        var state = PanesHarness.SampleState(Path.GetTempPath());
        var blocks = state.ChangesBlocks;
        var live = Assert.IsType<ChangesBlock.Entry>(blocks[0]);
        Assert.True(live.Live);
        Assert.Contains(blocks, b => b is ChangesBlock.Quiet q && q.Turns.Count == 2);
        state.ToggleChangesEditsOnly();
        Assert.DoesNotContain(state.ChangesBlocks, b => b is ChangesBlock.Quiet);
        Assert.Equal(1.42, UsageCalculator.CostUSD(new TokenUsage { Input = 142_000 }, "claude-sonnet-5") * 5, 2);
    }
}
