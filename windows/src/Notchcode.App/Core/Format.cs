// Format.cs
// Port of Sources/notchcode/Core/Format.swift.
// Text formatting for clocks, durations, tokens, money and paths. Dates are UTC DateTimes;
// clock times are shown in local time, "1:10 PM" style (the owner's clock format).

using System.Globalization;
using Notchcode.UI;

namespace Notchcode.Core;

public static class Format
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// "2:07" for a countdown or elapsed clock; "1:02:07" past an hour.
    public static string Clock(double seconds)
    {
        long total = Math.Max(0, (long)Math.Floor(seconds));
        if (total >= 3600)
            return string.Format(Inv, "{0}:{1:00}:{2:00}", total / 3600, (total % 3600) / 60, total % 60);
        return string.Format(Inv, "{0}:{1:00}", total / 60, total % 60);
    }

    /// "45s", "2m 14s", "1h 3m".
    public static string Duration(double seconds)
    {
        long total = Math.Max(0, (long)Math.Round(seconds, MidpointRounding.AwayFromZero));
        if (total < 60) return $"{total}s";
        if (total < 3600) return $"{total / 60}m {total % 60}s";
        return $"{total / 3600}h {(total % 3600) / 60}m";
    }

    /// "now", "12m ago", "2h ago" for when a session last did something.
    public static string Ago(DateTime date, DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        long total = Math.Max(0, (long)(n - date).TotalSeconds);
        if (total < 60) return "now";
        if (total < 3600) return $"{total / 60}m ago";
        return $"{total / 3600}h ago";
    }

    /// "resets in 1h 52m" when close, "resets Thu 3:40 PM" when further out.
    public static string Resets(DateTime date, DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        long total = Math.Max(0, (long)(date - n).TotalSeconds);
        if (total < Theme.Timing.ResetRelativeWindow)
        {
            long hours = total / 3600;
            long minutes = (total % 3600) / 60;
            return "resets in " + (hours > 0 ? $"{hours}h {minutes}m" : $"{Math.Max(1, minutes)}m");
        }
        return "resets " + WeekdayTime(date);
    }

    /// "limits updated now", "limits updated 3m ago", then "limits as of 2:14 PM" (today)
    /// or "limits as of Thu 3:40 PM".
    public static string LimitsAsOf(DateTime date, DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        var age = (n - date).TotalSeconds;
        if (age < Theme.Timing.LimitsRelativeWindow) return "limits updated " + Ago(date, n);
        return "limits as of " + (SameLocalDay(date, n) ? Time(date) : WeekdayTime(date));
    }

    /// "reset at 3:40 PM" for a limit window that has already rolled over.
    public static string ResetAt(DateTime date, DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        return "reset at " + (SameLocalDay(date, n) ? Time(date) : WeekdayTime(date));
    }

    /// A tool's short name: "Bash" stays "Bash"; an MCP tool
    /// ("mcp__claude_ai_Google_Calendar__complete_authentication") becomes its last part.
    public static string ToolName(string tool)
    {
        if (McpServer(tool) is null) return tool;
        var parts = tool.Split(McpSeparator);
        return parts.Length > 0 ? parts[^1] : tool;
    }

    /// The MCP server of an "mcp__server__tool" name, else null.
    public static string? McpServer(string tool)
    {
        var parts = tool.Split(McpSeparator);
        if (parts.Length < 3 || parts[0] != "mcp") return null;
        return string.Join(McpSeparator, parts[1..^1]);
    }

    private const string McpSeparator = "__";

    /// "1:10 PM" (the owner's clock format): when a turn started.
    public static string TimeOfDay(DateTime date) => Time(date);

    /// "1 turn", "14 turns".
    public static string Turns(int count) => count == 1 ? "1 turn" : $"{count} turns";

    /// "1 quiet turn", "4 quiet turns".
    public static string QuietTurns(int count) => count == 1 ? "1 quiet turn" : $"{count} quiet turns";

    /// "started 1:10 PM".
    public static string Started(DateTime date) => "started " + Time(date);

    private static DateTime Local(DateTime date)
        => date.Kind == DateTimeKind.Local ? date : DateTime.SpecifyKind(date, DateTimeKind.Utc).ToLocalTime();

    private static bool SameLocalDay(DateTime a, DateTime b) => Local(a).Date == Local(b).Date;

    /// Short time, "1:10 PM".
    private static string Time(DateTime date) => Local(date).ToString("h:mm tt", Inv);

    /// "Thu 3:40 PM".
    private static string WeekdayTime(DateTime date) => Local(date).ToString("ddd h:mm tt", Inv);

    /// Token counts the way Claude Code prints them: "812", "357.2k", "1.9M", "200k", "1M".
    public static string Tokens(long count)
    {
        static string Trimmed(double value)
        {
            var text = value.ToString("F1", Inv);
            return text.EndsWith(".0", StringComparison.Ordinal) ? text[..^2] : text;
        }
        if (count >= 1_000_000) return Trimmed(count / 1_000_000.0) + "M";
        if (count >= 1_000)
        {
            var k = Math.Round(count / 100.0, MidpointRounding.AwayFromZero) / 10;
            return k >= 1_000 ? Trimmed(count / 1_000_000.0) + "M" : Trimmed(k) + "k";
        }
        return count.ToString(Inv);
    }

    /// "1 file", "3 files".
    public static string Files(int count) => count == 1 ? "1 file" : $"{count} files";

    public static string Money(double value) => "$" + value.ToString("F2", Inv);

    /// "$50" for whole dollars, else "$12.40".
    public static string MoneyTrimmed(double value)
        => value == Math.Round(value, MidpointRounding.AwayFromZero) ? "$" + value.ToString("F0", Inv) : Money(value);

    /// A gateway spend limit: "$12.40 of $50".
    public static string Spend(double used, double limit) => Money(used) + " of " + MoneyTrimmed(limit);

    /// Percent values arrive as 0-100.
    public static string Percent(double value) => $"{(long)Math.Round(value, MidpointRounding.AwayFromZero)}%";

    /// "… 9 more lines" ("… 1 more line"), or "… more lines" when the count is not known.
    public static string MoreLines(int? count)
    {
        if (count is not int c || c <= 0) return Theme.Glyphs.Ellipsis + " more lines";
        return Theme.Glyphs.Ellipsis + (c == 1 ? " 1 more line" : $" {c} more lines");
    }

    public static string Added(int count) => $"+{count}";
    public static string Removed(int count) => Theme.Glyphs.Minus + count.ToString(Inv);

    /// The last path component, for '/' and '\' alike; a trailing separator is ignored.
    public static string FileName(string path)
    {
        var trimmed = path.TrimEnd('/', '\\');
        if (trimmed.Length == 0) return path.Length > 0 ? path[..1] : path;
        int i = trimmed.LastIndexOfAny(['/', '\\']);
        return i < 0 ? trimmed : trimmed[(i + 1)..];
    }

    /// The open card's status line: "main · opus · Editing", with the start time after the
    /// model when another session shares the folder ("main · opus · started 1:10 PM").
    public static string StatusSubtitle(Session session, string? model, DateTime? started, string? verb)
    {
        var extras = new List<string>();
        if (model is not null) extras.Add(model);
        if (started is DateTime s) extras.Add(Started(s));
        if (verb is not null) extras.Add(verb);
        return SessionSubtitle(session, string.Join(Theme.Glyphs.Separator, extras));
    }

    /// "main · Editing": the branch, then extras. The worktree is already in `DisplayFull`.
    public static string SessionSubtitle(Session session, string? extra = null)
    {
        var parts = new List<string>();
        if (session.Branch is not null) parts.Add(session.Branch);
        if (!string.IsNullOrEmpty(extra)) parts.Add(extra);
        return string.Join(Theme.Glyphs.Separator, parts);
    }

    /// "1 worktree", "2 worktrees".
    public static string Worktrees(int count) => count == 1 ? "1 worktree" : $"{count} worktrees";

    /// "1 session", "3 sessions".
    public static string Sessions(int count) => count == 1 ? "1 session" : $"{count} sessions";

    /// "1 agent", "3 agents".
    public static string Agents(int count) => count == 1 ? "1 agent" : $"{count} agents";

    /// "2 working · 1 waiting · 3 agents", skipping zero counts.
    public static string SessionCounts(int working, int waiting, int done, int idle, int agents)
    {
        var parts = new List<string>();
        if (working > 0) parts.Add($"{working} working");
        if (waiting > 0) parts.Add($"{waiting} waiting");
        if (done > 0) parts.Add($"{done} done");
        if (idle > 0) parts.Add($"{idle} idle");
        if (agents > 0) parts.Add(Agents(agents));
        return string.Join(Theme.Glyphs.Separator, parts);
    }

    /// A state in a word: the verb while working ("Editing"), else Needs you, Done, Idle.
    public static string StateText(SessionState state, string? verb) => state switch
    {
        SessionState.Working => verb ?? "Working",
        SessionState.NeedsYou => "Needs you",
        SessionState.Done => "Done",
        _ => "Idle",
    };

    /// A permission mode in a word: "bypass", "plan", "accept edits", "don't ask". Default and auto (the owner's everyday modes) show nothing.
    /// Null for the default mode and for anything unknown, which show nothing.
    public static string? PermissionModeLabel(string? raw) => raw switch
    {
        "bypassPermissions" => "bypass",
        "plan" => "plan",
        "acceptEdits" => "accept edits",
        "dontAsk" => "don't ask",
        _ => null,
    };

    /// "+1 session", "+3 sessions": the other sessions beside the one the wings name.
    public static string OtherSessions(int count) => count == 1 ? "+1 session" : $"+{count} sessions";

    /// "1 other session", "3 other sessions".
    public static string OtherSessionsHelp(int count) => count == 1 ? "1 other session" : $"{count} other sessions";
}

/// The main name is the repository; the worktree is the sub line. A plain checkout has no sub.
/// (The Swift `extension Session` in Format.swift; C# 14 extension properties.)
public static class SessionDisplay
{
    extension(Session session)
    {
        public string DisplayName => session.RepoName ?? session.WorktreeName;

        public string? DisplaySub
            => session.RepoName is { } repo && repo != session.WorktreeName ? session.WorktreeName : null;

        /// "notchcode · ponyfish" for a worktree, "notchcode" for a plain checkout. Views show it
        /// with middle truncation, so a long pair keeps both ends.
        public string DisplayFull
            => session.DisplaySub is { } sub ? session.DisplayName + Theme.Glyphs.Separator + sub : session.DisplayName;

        /// The name of the row inside its repository group: the worktree folder.
        public string RowName => session.WorktreeName;
    }

    /// The session's full name, or the app's when there is no session.
    public static string DisplayOrApp(this Session? session) => session?.DisplayFull ?? "notchcode";
}
