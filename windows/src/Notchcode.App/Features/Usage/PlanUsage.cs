// PlanUsage.cs
// Port of Sources/notchcode/Features/Usage/PlanUsage.swift.
// `PlanUsageReader` parses the usage cache Claude Code keeps in %USERPROFILE%\.claude.json
// (`cachedUsageUtilization`) and the "What's contributing to your limits usage?" section of
// `claude -p /usage`. The app never calls an API: `PlanUsageRunner` runs the owner's own CLI
// headlessly (no hooks, no model turn), which refreshes that cache. Value types: UsageModel.cs.

using System.IO;
using System.Text;
using System.Text.Json;
using JsonValueKind = Notchcode.Core.JsonValueKind;
using Notchcode.Core;
using Notchcode.UI;

namespace Notchcode.Features.Usage;

public static class PlanUsageReader
{
    /// The usage cache in Claude Code's config file, or null when absent or unreadable.
    public static PlanUsage? Read(string? configPath = null)
    {
        var path = configPath ?? NotchcodePaths.ClaudeConfigFile;
        try
        {
            if (!File.Exists(path)) return null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            return Parse(reader.ReadToEnd());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    /// `cachedUsageUtilization` out of the config file's text. Every key may be missing or null.
    public static PlanUsage? Parse(string configText)
    {
        JsonValue root;
        try { root = JsonValue.Parse(configText); }
        catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException) { return null; }
        if (root["cachedUsageUtilization"] is not { Kind: JsonValueKind.Object } cache) return null;
        if (cache["fetchedAtMs"]?.DoubleValue is not double fetchedMs) return null;
        if (cache["utilization"] is not { Kind: JsonValueKind.Object } utilization) return null;

        double? fivePercent = null, weekPercent = null;
        DateTime? fiveResets = null, weekResets = null;
        var limits = utilization["limits"]?.ArrayValue ?? [];
        JsonValue? Limit(string kind) => limits.FirstOrDefault(l => l["kind"]?.StringValue == kind);

        if (utilization["five_hour"] is { Kind: JsonValueKind.Object } five && five["utilization"]?.DoubleValue is double p5)
        {
            fivePercent = Clamp(p5);
            fiveResets = IsoDate.Parse(five["resets_at"]);
        }
        else if (Limit("session") is { } session && session["percent"]?.DoubleValue is double ps)
        {
            fivePercent = Clamp(ps);
            fiveResets = IsoDate.Parse(session["resets_at"]);
        }
        if (utilization["seven_day"] is { Kind: JsonValueKind.Object } seven && seven["utilization"]?.DoubleValue is double p7)
        {
            weekPercent = Clamp(p7);
            weekResets = IsoDate.Parse(seven["resets_at"]);
        }
        else if (Limit("weekly_all") is { } week && week["percent"]?.DoubleValue is double pw)
        {
            weekPercent = Clamp(pw);
            weekResets = IsoDate.Parse(week["resets_at"]);
        }

        var modelWeeks = new List<ModelWeek>();
        foreach (var row in limits)
        {
            if (row["kind"]?.StringValue != "weekly_scoped") continue;
            if (row["scope"]?["model"]?["display_name"]?.StringValue is not { Length: > 0 } name) continue;
            if (row["percent"]?.DoubleValue is not double percent) continue;
            if (modelWeeks.Any(w => w.Name == name)) continue;
            modelWeeks.Add(new ModelWeek { Name = name, Percent = Clamp(percent), ResetsAt = IsoDate.Parse(row["resets_at"]) });
        }

        var rows = utilization["seven_day_breakdown"]?["rows"]?.ArrayValue ?? [];
        var shares = new List<NamedShare>();
        foreach (var row in rows)
        {
            var name = row["display_name"]?.StringValue ?? row["key"]?.StringValue;
            if (name is null || row["percent"]?.DoubleValue is not double percent) continue;
            shares.Add(new NamedShare { Name = name, Percent = Clamp(percent) });
        }

        return new PlanUsage
        {
            FetchedAt = ContractJson.FromUnixSeconds(fetchedMs / 1000),
            FiveHourPercent = fivePercent,
            FiveHourResetsAt = fiveResets,
            WeekPercent = weekPercent,
            WeekResetsAt = weekResets,
            ModelWeeks = modelWeeks,
            WeekBreakdown = shares.Where(s => s.Percent > 0).Concat(shares.Where(s => s.Percent <= 0)).ToList(),
        };
    }

    /// The two periods of "What's contributing to your limits usage?", or null when the
    /// section is absent. A period starts at "Last 24h · 155 requests · 2 sessions"; its
    /// indented lines follow.
    public static UsageBehaviors? Behaviors(string text)
    {
        var periods = new List<UsageBehaviorPeriod>();
        foreach (var raw in text.SplitLines())
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (PeriodHeader(line) is { } period)
                periods.Add(period);
            else if (char.IsWhiteSpace(raw[0]) && periods.Count > 0)
                periods[^1] = periods[^1] with { Lines = periods[^1].Lines.Append(line).ToList() };
        }
        if (periods.Count == 0) return null;
        UsageBehaviorPeriod? day = null, week = null;
        foreach (var period in periods)
        {
            if (period.Title.Contains("24h") || period.Title.Contains("day"))
                day ??= period;
            else
                week ??= period;
        }
        if (day is null && week is null) day = periods[0];
        return new UsageBehaviors { Day = day, Week = week };
    }

    /// "Last 24h · 155 requests · 2 sessions" -> its title and counts.
    private static UsageBehaviorPeriod? PeriodHeader(string line)
    {
        if (!line.StartsWith("Last ", StringComparison.Ordinal)) return null;
        var parts = line.Split('·').Select(p => p.Trim()).ToArray();
        if (parts.Length < 3) return null;
        static int? Count(string part, string word)
        {
            var pieces = part.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (pieces.Length != 2 || !pieces[1].StartsWith(word, StringComparison.Ordinal)) return null;
            return int.TryParse(pieces[0], out var n) ? n : null;
        }
        if (Count(parts[1], "request") is not int requests || Count(parts[2], "session") is not int sessions) return null;
        return new UsageBehaviorPeriod { Title = parts[0], Requests = requests, Sessions = sessions };
    }

    private static double Clamp(double percent) => Math.Min(100, Math.Max(0, percent));
}

/// Runs `claude.exe -p /usage --output-format json --setting-sources "" --resume <id>` in
/// `NotchcodePaths.UsageRunDirectory`: about 300 ms, no tokens, no model turn, no hooks. It
/// refreshes Claude Code's usage cache and prints the usage text as the JSON's `result`.
public static class PlanUsageRunner
{
    private static readonly object gate = new();
    /// The resolved `claude.exe`; `resolvedOnce` with null once nothing resolved.
    private static string? resolved;
    private static bool resolvedOnce;

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// Where `claude.exe` is looked for before PATH: the native installer's folder.
    private static IEnumerable<string> Candidates => [Path.Combine(Home, ".local", "bin", "claude.exe")];

    private static string SessionIdFile => Path.Combine(NotchcodePaths.UsageRunDirectory, "session-id");

    /// The run's session id, read from disk, made on first use, and replaced when its
    /// transcript has grown past `Theme.Limits.PlanUsageTranscriptBytes`.
    public static string SessionId()
    {
        try
        {
            Directory.CreateDirectory(NotchcodePaths.UsageRunDirectory);
            if (File.Exists(SessionIdFile))
            {
                var id = File.ReadAllText(SessionIdFile).Trim();
                if (Guid.TryParse(id, out _))
                {
                    var transcript = TranscriptPath(id);
                    long size = File.Exists(transcript) ? new FileInfo(transcript).Length : 0;
                    if (size <= Theme.Limits.PlanUsageTranscriptBytes) return id;
                }
            }
            var fresh = Guid.NewGuid().ToString().ToLowerInvariant();
            File.WriteAllText(SessionIdFile, fresh);
            return fresh;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Guid.NewGuid().ToString().ToLowerInvariant();
        }
    }

    /// Claude Code keeps a project's transcripts in %USERPROFILE%\.claude\projects\<cwd with every
    /// character but ASCII letters and digits turned into "-">.
    public static string TranscriptPath(string id)
        => Path.Combine(NotchcodePaths.ClaudeProjectsDirectory, NotchcodePaths.ProjectFolderName(NotchcodePaths.UsageRunDirectory), id + ".jsonl");

    /// The usage text, or why there is none. `resolveAgain` (a forced refresh) looks for the
    /// executable again after an earlier search found nothing. A new session's first run
    /// (`--session-id`) never prints "What's contributing to your limits usage?", so a
    /// successful one is followed by one `--resume`, whose text is used when it succeeds.
    public static async Task<(string? Text, PlanUsageError? Error)> RunAsync(bool resolveAgain = false)
    {
        if (Executable(resolveAgain) is not { } claude) return (null, PlanUsageError.NotFound);
        var id = SessionId();
        var cwd = NotchcodePaths.UsageRunDirectory;
        bool fresh = !File.Exists(TranscriptPath(id));

        var localBin = Path.Combine(Home, ".local", "bin");
        var env = new Dictionary<string, string?>
        {
            ["PATH"] = localBin + Path.PathSeparator + (Environment.GetEnvironmentVariable("PATH") ?? ""),
        };

        Task<ProcessRunner.Result> Invoke(string flag) => ProcessRunner.RunAsync(
            claude,
            ["-p", "/usage", "--output-format", "json", "--setting-sources", "", flag, id],
            cwd: cwd,
            environment: env,
            timeout: Theme.Timing.PlanUsageTimeout);

        // A known id resumes; an unknown one starts with --session-id. Each failure the
        // other way round retries once with the other flag.
        var flag = fresh ? "--session-id" : "--resume";
        var result = await Invoke(flag);
        if (result.Status != 0 && !result.TimedOut)
        {
            var said = result.Out + result.Err;
            if (!fresh && said.Contains("No conversation found", StringComparison.Ordinal))
            {
                flag = "--session-id";
                result = await Invoke(flag);
            }
            else if (fresh && said.Contains("already in use", StringComparison.Ordinal))
            {
                flag = "--resume";
                result = await Invoke(flag);
            }
        }
        static string? ResultText(ProcessRunner.Result run)
        {
            if (run.Status != 0) return null;
            try { return JsonValue.Parse(run.Out)["result"]?.StringValue; }
            catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException) { return null; }
        }
        if (ResultText(result) is not { } text) return (null, PlanUsageError.Failed);
        if (flag == "--session-id" && !text.Contains("What's contributing", StringComparison.Ordinal)
            && ResultText(await Invoke("--resume")) is { } resumed)
            return (resumed, null);
        return (text, null);
    }

    /// `claude.exe`, resolved once for the app's lifetime: %USERPROFILE%\.local\bin, then PATH.
    private static string? Executable(bool resolveAgain)
    {
        lock (gate)
        {
            if (resolvedOnce && !(resolveAgain && resolved is null)) return resolved;
        }
        string? found = Candidates.FirstOrDefault(File.Exists);
        if (found is null)
        {
            var path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(dir.Trim().Trim('"'), "claude.exe");
                    if (File.Exists(candidate)) { found = candidate; break; }
                }
                catch (ArgumentException) { }
            }
        }
        lock (gate)
        {
            resolved = found;
            resolvedOnce = true;
        }
        return found;
    }
}
