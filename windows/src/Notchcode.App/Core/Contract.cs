// Contract.cs
// Port of Sources/notchcode/Core/Contract.swift.
// The shared contract between the hook exe, the pipe transport, the transcript reader and
// the UI. Every other file in the app talks through the types in this file. Change it only
// by agreement; the hook exe (which links this file) encodes the same JSON.
//
// Wire format, one JSON object per line over a named pipe at \\.\pipe\notchcode-<username>
//
//   hook -> app   HookEnvelope
//   app  -> hook  HookReply     (only for kinds that block: permission, preTool)
//
// A hook that gets no reply within its own timeout prints nothing and exits 0,
// so Claude Code's normal terminal prompt continues.
//
// Port conventions:
// - Every Swift `Date` is a `DateTime` in UTC (Kind Utc) everywhere in the port; convert
//   to local time only for display. `TimeInterval` seconds are `double`.
// - Swift value structs are immutable C# records with `init` properties: change one with
//   `with { ... }` and assign it back, which keeps Swift's value semantics (a `didSet` sees
//   the old and the new value). Records holding lists implement value equality by hand.
// - Swift nested enums (`PendingRequest.Kind`, `DiffLine.Kind`, `Preferences.IdleStyle`) are
//   top-level enums here (`PendingRequestKind`, `DiffLineKind`, `IdleStyle`), because C#
//   cannot have a nested type and a property with the same name.
// - No WPF types: this file is linked into the hook project.

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Notchcode.Core;

// MARK: - Wire types

[JsonConverter(typeof(EventKindConverter))]
public enum EventKind
{
    /// PermissionRequest hook. Blocking.
    Permission,
    /// PreToolUse hook (used for Bash git commit). Blocking.
    PreTool,
    /// PostToolUse hook (Edit / Write / MultiEdit / Bash). Passive. On Bash it carries `tree`.
    PostTool,
    /// Notification hook (idle_prompt, permission_prompt, agent_needs_input, ...). Passive.
    Notification,
    /// Stop hook: Claude finished a turn. Passive.
    Stop,
    SessionStart,
    SessionEnd,
    /// UserPromptSubmit: a new turn began. Carries `tree` (the turn's baseline).
    UserPrompt,
    /// SubagentStart hook: payload has agent_id, agent_type. Passive.
    SubagentStart,
    /// SubagentStop hook. Passive.
    SubagentStop,
    /// Claude Code's status line input, forwarded by our status line command. Passive.
    /// payload.rate_limits.five_hour / seven_day: { used_percentage, resets_at (unix s) },
    /// plus context_window, cost, model, session_id. This is where the real limits come from.
    Statusline,
}

/// The Swift raw values of `EventKind`, both ways.
public static class EventKinds
{
    public static string RawValue(this EventKind kind) => kind switch
    {
        EventKind.Permission => "permission",
        EventKind.PreTool => "pre_tool",
        EventKind.PostTool => "post_tool",
        EventKind.Notification => "notification",
        EventKind.Stop => "stop",
        EventKind.SessionStart => "session_start",
        EventKind.SessionEnd => "session_end",
        EventKind.UserPrompt => "user_prompt",
        EventKind.SubagentStart => "subagent_start",
        EventKind.SubagentStop => "subagent_stop",
        EventKind.Statusline => "statusline",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static EventKind? FromRaw(string? raw) => raw switch
    {
        "permission" => EventKind.Permission,
        "pre_tool" => EventKind.PreTool,
        "post_tool" => EventKind.PostTool,
        "notification" => EventKind.Notification,
        "stop" => EventKind.Stop,
        "session_start" => EventKind.SessionStart,
        "session_end" => EventKind.SessionEnd,
        "user_prompt" => EventKind.UserPrompt,
        "subagent_start" => EventKind.SubagentStart,
        "subagent_stop" => EventKind.SubagentStop,
        "statusline" => EventKind.Statusline,
        _ => null,
    };
}

/// Reads and writes `EventKind` as the Swift raw strings. An unknown kind fails the envelope, as in Swift.
public sealed class EventKindConverter : JsonConverter<EventKind>
{
    public override EventKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
        return EventKinds.FromRaw(raw) ?? throw new JsonException("Unknown event kind: " + raw);
    }

    public override void Write(Utf8JsonWriter writer, EventKind value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.RawValue());
}

/// What a hook sends. `payload` is the raw JSON Claude Code gave the hook on stdin,
/// embedded verbatim. Read session_id / cwd / transcript_path through the `Resolved*`
/// accessors, which fall back to the payload.
///
/// `tree` is present on `user_prompt`, and on `post_tool` when the tool was Bash, if the
/// session's cwd is inside a git work tree:
///
///   "tree": { "root": "&lt;git toplevel&gt;", "head": "&lt;HEAD sha, or empty&gt;",
///             "status_b64": base64 of `git status --porcelain=v1 --untracked-files=all`,
///             "diff_b64":   base64 of `git diff HEAD` plus each untracked file (first 20)
///                           diffed against NUL (/dev/null on macOS), capped at 256 KB,
///             "truncated":  true when that cap cut the diff }
///
/// Paths inside both texts are relative to `root`.
public sealed record HookEnvelope
{
    [JsonPropertyName("v")] public int V { get; init; } = 1;
    [JsonPropertyName("kind")] public EventKind Kind { get; init; }
    /// A GUID made by the hook, echoed back in the reply.
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("session_id"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SessionId { get; init; }
    [JsonPropertyName("cwd"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Cwd { get; init; }
    [JsonPropertyName("transcript_path"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TranscriptPath { get; init; }
    /// TERM_PROGRAM as inherited by the hook (vscode, WindowsTerminal from WT_SESSION, ...).
    [JsonPropertyName("term_program"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TermProgram { get; init; }
    /// __CFBundleIdentifier on macOS; unused on Windows.
    [JsonPropertyName("term_bundle_id"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TermBundleId { get; init; }
    /// The Claude Code process id (parent of the hook).
    [JsonPropertyName("pid"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? Pid { get; init; }
    /// Unix seconds.
    [JsonPropertyName("ts")] public double Ts { get; init; }
    [JsonPropertyName("payload")] public JsonValue Payload { get; init; } = JsonValue.Null;
    /// The working tree, see above.
    [JsonPropertyName("tree"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public TreeReport? Tree { get; init; }

    [JsonIgnore] public string ResolvedSessionId => SessionId ?? Payload["session_id"]?.StringValue ?? "unknown";
    [JsonIgnore] public string ResolvedCwd => Cwd ?? Payload["cwd"]?.StringValue ?? "";
    [JsonIgnore] public string? ResolvedTranscriptPath => TranscriptPath ?? Payload["transcript_path"]?.StringValue;
    [JsonIgnore] public bool IsBlocking => Kind == EventKind.Permission || Kind == EventKind.PreTool;
    /// A PermissionRequest for `ExitPlanMode`: Claude finished a plan and asks to leave plan mode.
    [JsonIgnore] public bool IsPlanRequest => Kind == EventKind.Permission && Payload["tool_name"]?.StringValue == "ExitPlanMode";

    /// One envelope from one JSON line; null when the line is not a valid envelope.
    public static HookEnvelope? FromLine(string line)
    {
        try { return JsonSerializer.Deserialize<HookEnvelope>(line, ContractJson.Options); }
        catch (JsonException) { return null; }
        catch (NotSupportedException) { return null; }
    }

    /// The envelope as one JSON line, no trailing newline.
    public string ToLine() => JsonSerializer.Serialize(this, ContractJson.Options);
}

/// The working-tree report a hook attaches to `user_prompt` and Bash `post_tool` envelopes,
/// with the base64 texts decoded. Parsed into per-file entries by Core/Diff/UnifiedDiff.cs.
[JsonConverter(typeof(TreeReportConverter))]
public sealed record TreeReport
{
    /// git toplevel
    public string Root { get; init; } = "";
    /// HEAD's sha; null in a repository with no commit yet
    public string? Head { get; init; }
    /// `git status --porcelain=v1` lines: "XY path"
    public IReadOnlyList<string> Status { get; init; } = [];
    /// unified diff against HEAD, untracked files as new
    public string Diff { get; init; } = "";
    /// the hook's 256 KB cap cut `diff`
    public bool Truncated { get; init; }

    public bool Equals(TreeReport? other)
        => other is not null && Root == other.Root && Head == other.Head && Status.SequenceEqual(other.Status)
           && Diff == other.Diff && Truncated == other.Truncated;

    public override int GetHashCode() => HashCode.Combine(Root, Head, Status.Count, Diff, Truncated);

    /// Base64 to text. The 256 KB cap can split a UTF-8 sequence; that byte decodes to U+FFFD.
    /// Characters outside the base64 alphabet are ignored, as `.ignoreUnknownCharacters`.
    internal static string Unbase64(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var clean = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '+' or '/' or '=')
                clean.Append(c);
        }
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(clean.ToString())); }
        catch (FormatException) { return ""; }
    }

    internal static string Base64(string text) => Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
}

/// Wire form of TreeReport: root, head ("" when none), status_b64, diff_b64, truncated.
public sealed class TreeReportConverter : JsonConverter<TreeReport>
{
    public override TreeReport? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var obj = JsonValue.Read(ref reader);
        if (obj.Kind != JsonValueKind.Object) throw new JsonException("tree is not an object");
        var root = obj["root"]?.StringValue ?? throw new JsonException("tree has no root");
        var sha = obj["head"]?.StringValue ?? "";
        var statusText = TreeReport.Unbase64(obj["status_b64"]?.StringValue);
        return new TreeReport
        {
            Root = root,
            Head = sha.Length == 0 ? null : sha,
            Status = statusText.Split('\n').Where(s => s.Length > 0).ToList(),
            Diff = TreeReport.Unbase64(obj["diff_b64"]?.StringValue),
            Truncated = obj["truncated"]?.BoolValue ?? false,
        };
    }

    public override void Write(Utf8JsonWriter writer, TreeReport value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("root", value.Root);
        writer.WriteString("head", value.Head ?? "");
        writer.WriteString("status_b64", TreeReport.Base64(string.Join("\n", value.Status)));
        writer.WriteString("diff_b64", TreeReport.Base64(value.Diff));
        writer.WriteBoolean("truncated", value.Truncated);
        writer.WriteEndObject();
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<Decision>))]
public enum Decision
{
    [JsonStringEnumMemberName("allow")] Allow,
    [JsonStringEnumMemberName("deny")] Deny,
    /// No opinion: the hook prints nothing and the terminal prompt continues.
    [JsonStringEnumMemberName("none")] None,
}

/// What the app sends back for a blocking event.
public sealed record HookReply
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("decision")] public Decision Decision { get; init; } = Decision.None;
    /// Allow and remember (the hook emits updatedPermissions).
    [JsonPropertyName("always")] public bool Always { get; init; }
    [JsonPropertyName("reason"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Reason { get; init; }
    /// The rules the hook sends as `updatedPermissions`; absent from the line when null.
    [JsonPropertyName("updated_permissions"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public JsonValue? UpdatedPermissions { get; init; }

    public static string DecisionRaw(Decision d) => d switch
    {
        Decision.Allow => "allow",
        Decision.Deny => "deny",
        _ => "none",
    };

    /// The reply as one line, keys sorted (always, decision, id, reason, updated_permissions;
    /// nested keys sorted too), nil fields left out, slashes unescaped, and a trailing "\n":
    /// byte-identical to the Swift `replyLine`.
    public string ToLine()
    {
        var sb = new StringBuilder();
        sb.Append("{\"always\":").Append(Always ? "true" : "false");
        sb.Append(",\"decision\":\"").Append(DecisionRaw(Decision)).Append('"');
        sb.Append(",\"id\":");
        JsonValue.AppendSwiftString(sb, Id);
        if (Reason is not null)
        {
            sb.Append(",\"reason\":");
            JsonValue.AppendSwiftString(sb, Reason);
        }
        if (UpdatedPermissions is not null)
        {
            sb.Append(",\"updated_permissions\":");
            UpdatedPermissions.AppendSwiftJson(sb, sortKeys: true);
        }
        sb.Append("}\n");
        return sb.ToString();
    }

    /// One reply line for the hook waiting under `id` (SocketServer.replyLine): a null reply is
    /// "none". An "always" allow with no rules of its own echoes the payload's
    /// `permission_suggestions` as `updated_permissions`.
    public static string ReplyLine(HookReply? reply, string id, JsonValue payload)
    {
        var r = (reply ?? new HookReply { Decision = Decision.None }) with { Id = id };
        if (r.Decision == Decision.Allow && r.Always && r.UpdatedPermissions is null
            && payload["permission_suggestions"] is { } suggestions
            && suggestions.ArrayValue is { Count: > 0 })
        {
            r = r with { UpdatedPermissions = suggestions };
        }
        return r.ToLine();
    }
}

/// Sends the owner's answer to the waiting hook. Returns true when the hook got the reply;
/// false when the transport had already answered none at its deadline or the hook had gone.
public delegate bool ReplyHandler(HookReply? reply);

/// The UI side implements this. The transport calls `Receive` on the UI thread.
/// For blocking kinds the sink MUST eventually call `reply`, or the transport
/// replies none itself when the hook's deadline passes.
public interface IHookEventSink
{
    void Receive(HookEnvelope envelope, ReplyHandler reply);
    /// The hook went away before a reply (the owner answered in the terminal, or Claude Code timed out).
    /// The sink drops the pending request and must not call its reply handler afterwards.
    void Cancel(string requestId);
    /// The transport replied "none" at its deadline. The sink drops the request without
    /// replying and treats it as unanswered (Claude Code's terminal prompt now waits).
    void TimedOut(string requestId);
}

/// JSON options for the wire types: Swift-like escaping (no escaping of non-ASCII or slashes).
public static class ContractJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    /// Unix seconds to a UTC DateTime.
    public static DateTime FromUnixSeconds(double seconds)
        => DateTime.UnixEpoch.AddTicks((long)(seconds * TimeSpan.TicksPerSecond));

    /// A UTC DateTime to unix seconds.
    public static double ToUnixSeconds(DateTime date)
        => (date.ToUniversalTime() - DateTime.UnixEpoch).Ticks / (double)TimeSpan.TicksPerSecond;
}

// MARK: - Model derived from envelopes and transcripts

[JsonConverter(typeof(JsonStringEnumConverter<SessionState>))]
public enum SessionState
{
    [JsonStringEnumMemberName("idle")] Idle,
    [JsonStringEnumMemberName("working")] Working,
    [JsonStringEnumMemberName("needsYou")] NeedsYou,
    [JsonStringEnumMemberName("done")] Done,
}

public sealed record Session
{
    /// session_id
    public string Id { get; init; } = "";
    public string Cwd { get; init; } = "";
    /// last path component of cwd ("ponyfish")
    public string WorktreeName { get; init; } = "";
    /// git toplevel name if different from worktree ("notchcode")
    public string? RepoName { get; init; }
    public string? Branch { get; init; }
    public SessionState State { get; init; }
    /// "Editing", "Running tests", "Thinking"
    public string? Verb { get; init; }
    public DateTime StartedAt { get; init; }
    public DateTime LastEventAt { get; init; }
    public string? TranscriptPath { get; init; }
    public string? TermProgram { get; init; }
    public string? TermBundleId { get; init; }
    /// raw: "default", "plan", "bypassPermissions", "acceptEdits", "auto"; the transcript is the source of truth
    public string? PermissionMode { get; init; }
}

/// A subagent Claude started inside a session (Agent tool). Shown as a lane under its session.
public sealed record Agent
{
    /// agent_id from the hook, or the tool_use id from the transcript
    public string Id { get; init; } = "";
    public string SessionId { get; init; } = "";
    /// agent_type: "Explore", "general-purpose", "claude", ...
    public string Type { get; init; } = "";
    /// the Agent tool's short description when known from the transcript
    public string? Description { get; init; }
    public DateTime StartedAt { get; init; }
    public DateTime? EndedAt { get; init; }
    public bool IsRunning => EndedAt is null;
}

[JsonConverter(typeof(JsonStringEnumConverter<IdleStyle>))]
public enum IdleStyle
{
    [JsonStringEnumMemberName("closed")] Closed,
    [JsonStringEnumMemberName("wings")] Wings,
}

[JsonConverter(typeof(JsonStringEnumConverter<AttentionStyle>))]
public enum AttentionStyle
{
    [JsonStringEnumMemberName("twoRow")] TwoRow,
    [JsonStringEnumMemberName("wings")] Wings,
}

[JsonConverter(typeof(JsonStringEnumConverter<OpenGesture>))]
public enum OpenGesture
{
    [JsonStringEnumMemberName("click")] Click,
    [JsonStringEnumMemberName("hover")] Hover,
}

/// What the owner can change. Persisted to preferences.json by PreferencesStore; the keys are
/// the Swift property names. A key missing from the stored file (a choice added later) takes its default.
public sealed record Preferences
{
    /// what shows when sessions exist but nothing needs you
    [JsonPropertyName("idleStyle")] public IdleStyle IdleStyle { get; init; } = IdleStyle.Wings;
    [JsonPropertyName("attentionStyle")] public AttentionStyle AttentionStyle { get; init; } = AttentionStyle.TwoRow;
    /// passive events peek for a few seconds
    [JsonPropertyName("showPeeks")] public bool ShowPeeks { get; init; } = true;
    [JsonPropertyName("peekSeconds")] public double PeekSeconds { get; init; } = 4;
    [JsonPropertyName("openGesture")] public OpenGesture OpenGesture { get; init; } = OpenGesture.Click;
    /// Alt space (Ctrl Alt space when another app owns Alt space)
    [JsonPropertyName("hotkeyEnabled")] public bool HotkeyEnabled { get; init; } = true;
    /// the running subagent count in the closed state's wings
    [JsonPropertyName("showAgentsInWings")] public bool ShowAgentsInWings { get; init; } = true;
    /// also post a system notification for blocking events
    [JsonPropertyName("systemNotifications")] public bool SystemNotifications { get; init; }
    /// Peek every file edit, not only completed turns and subagents.
    [JsonPropertyName("peekEdits")] public bool PeekEdits { get; init; }
    /// The Files tool's tree is collapsed so the preview takes the whole well (Ctrl B).
    [JsonPropertyName("filesTreeHidden")] public bool FilesTreeHidden { get; init; }
    /// The small keycaps beside buttons and pills inside the card. The footer's key row and
    /// the attention row keep theirs either way; the shortcuts work either way.
    [JsonPropertyName("keycapsBesideButtons")] public bool KeycapsBesideButtons { get; init; } = true;
    /// Run `claude -p /usage` every 15 minutes for the per-model week and the limits breakdown.
    [JsonPropertyName("planUsageRefresh")] public bool PlanUsageRefresh { get; init; } = true;

    // Windows only (windows/PLAN.md, "Window and shape"): not in the macOS Preferences.
    /// The tray icon with Open · Settings · Quit. On by default: a window-less Windows app has no other way to quit.
    [JsonPropertyName("showTrayIcon")] public bool ShowTrayIcon { get; init; } = true;
    /// Start with Windows (a `Run` value under HKCU), the macOS plan's "Open at login".
    [JsonPropertyName("openAtLogin")] public bool OpenAtLogin { get; init; } = true;
    /// The live hotkey: "alt-space" (the default) or "ctrl-alt-space" when Alt+Space was taken at launch. Written by the app, shown in Settings.
    [JsonPropertyName("hotkeyChord")] public string HotkeyChord { get; init; } = "alt-space";
}

[JsonConverter(typeof(JsonStringEnumConverter<PendingRequestKind>))]
public enum PendingRequestKind { Permission, Commit, Plan }

/// A blocking request waiting for the owner.
public sealed record PendingRequest
{
    /// envelope id
    public string Id { get; init; } = "";
    public PendingRequestKind Kind { get; init; }
    public string SessionId { get; init; } = "";
    /// "Bash", "Edit", ...
    public string Tool { get; init; } = "";
    /// "Run the tests?" / commit subject
    public string Title { get; init; } = "";
    /// the command, the path, or the commit body
    public string Detail { get; init; } = "";
    public string? Reason { get; init; }
    /// commit only
    public IReadOnlyList<FileChange> Files { get; init; } = [];
    /// What "Always" would add: one line per `permission_suggestions` entry, all of which are sent back.
    public IReadOnlyList<string> AlwaysRules { get; init; } = [];
    /// The payload's `tool_use_id`: the plugin and Connect both installed send one call twice.
    public string? ToolUseId { get; init; }
    public DateTime ReceivedAt { get; init; }
    public DateTime Deadline { get; init; }

    public bool Equals(PendingRequest? o)
        => o is not null && Id == o.Id && Kind == o.Kind && SessionId == o.SessionId && Tool == o.Tool
           && Title == o.Title && Detail == o.Detail && Reason == o.Reason && Files.SequenceEqual(o.Files)
           && AlwaysRules.SequenceEqual(o.AlwaysRules) && ToolUseId == o.ToolUseId
           && ReceivedAt == o.ReceivedAt && Deadline == o.Deadline;

    public override int GetHashCode() => HashCode.Combine(Id, Kind, SessionId, Title, ReceivedAt);
}

public sealed record FileChange
{
    [JsonIgnore] public string Id => Path;
    /// relative to cwd when possible
    [JsonPropertyName("path")] public string Path { get; init; } = "";
    [JsonPropertyName("added")] public int Added { get; init; }
    [JsonPropertyName("removed")] public int Removed { get; init; }
    /// "edit", "write", "new", or "shell" (a Bash command changed it; the diff is against HEAD)
    [JsonPropertyName("kind")] public string Kind { get; init; } = "edit";
    /// the first few lines, for peeks and small inline previews (&lt; 8 lines)
    [JsonPropertyName("snippet")] public IReadOnlyList<DiffLine> Snippet { get; init; } = [];
    /// the whole diff as Claude Code recorded it (structuredPatch), capped at 400 lines
    [JsonPropertyName("patch")] public IReadOnlyList<DiffLine> Patch { get; init; } = [];
    [JsonPropertyName("patchTruncated")] public bool PatchTruncated { get; init; }
    /// The subagent that made the change (its agentId), when only subagents touched the file.
    [JsonPropertyName("agentId"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AgentId { get; init; }
    /// A staged rename's old path (`R  old -> new`); a commit must name both.
    [JsonPropertyName("renamedFrom"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RenamedFrom { get; init; }

    public bool Equals(FileChange? o)
        => o is not null && Path == o.Path && Added == o.Added && Removed == o.Removed && Kind == o.Kind
           && Snippet.SequenceEqual(o.Snippet) && Patch.SequenceEqual(o.Patch)
           && PatchTruncated == o.PatchTruncated && AgentId == o.AgentId && RenamedFrom == o.RenamedFrom;

    public override int GetHashCode() => HashCode.Combine(Path, Added, Removed, Kind, Patch.Count);
}

[JsonConverter(typeof(JsonStringEnumConverter<DiffLineKind>))]
public enum DiffLineKind
{
    [JsonStringEnumMemberName("context")] Context,
    [JsonStringEnumMemberName("added")] Added,
    [JsonStringEnumMemberName("removed")] Removed,
    [JsonStringEnumMemberName("hunk")] Hunk,
}

public sealed record DiffLine
{
    [JsonPropertyName("kind")] public DiffLineKind Kind { get; init; }
    [JsonPropertyName("text")] public string Text { get; init; } = "";
    [JsonPropertyName("oldLine"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? OldLine { get; init; }
    [JsonPropertyName("newLine"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? NewLine { get; init; }
}

public sealed record TokenUsage
{
    [JsonPropertyName("input")] public long Input { get; init; }
    [JsonPropertyName("output")] public long Output { get; init; }
    [JsonPropertyName("cacheRead")] public long CacheRead { get; init; }
    [JsonPropertyName("cacheWrite")] public long CacheWrite { get; init; }
    [JsonIgnore] public long Total => Input + Output + CacheRead + CacheWrite;
}

/// One prompt the owner sent and what happened after it, read from the transcript.
public sealed record TranscriptTurn
{
    /// uuid of the user message
    public string Id { get; init; } = "";
    public string Prompt { get; init; } = "";
    public DateTime StartedAt { get; init; }
    public DateTime? EndedAt { get; init; }
    public IReadOnlyList<FileChange> Files { get; init; } = [];
    public TokenUsage Tokens { get; init; } = new();
    public string? Model { get; init; }
    /// Input + cache read + cache write of the turn's last main-thread assistant message:
    /// the context size after it. Null when the transcript did not say (demo turns).
    public long? ContextTokens { get; init; }

    public bool Equals(TranscriptTurn? o)
        => o is not null && Id == o.Id && Prompt == o.Prompt && StartedAt == o.StartedAt && EndedAt == o.EndedAt
           && Files.SequenceEqual(o.Files) && Tokens == o.Tokens && Model == o.Model && ContextTokens == o.ContextTokens;

    public override int GetHashCode() => HashCode.Combine(Id, StartedAt, EndedAt, Files.Count);
}

/// A session found by reading `%USERPROFILE%\.claude\projects` directly, with no hook involved.
/// The UI merges these with hook-driven sessions by id. Hooks win on state when both exist.
public sealed record DiscoveredSession
{
    /// session_id (the transcript file name)
    public string Id { get; init; } = "";
    public string Cwd { get; init; } = "";
    public string TranscriptPath { get; init; } = "";
    public DateTime StartedAt { get; init; }
    public DateTime LastActivityAt { get; init; }
    /// inferred: working if the last line is recent and mid-turn, done if a turn just ended, idle otherwise
    public SessionState State { get; init; }
    /// from the last tool_use: "Editing", "Running", "Reading", "Thinking"
    public string? Verb { get; init; }
    public string? LastPrompt { get; init; }
    /// raw, from the last line that carries `permissionMode`
    public string? PermissionMode { get; init; }
    /// A helper run Claude Code started for itself (`entrypoint: sdk-cli`, such as naming a
    /// branch): never one of the owner's sessions. Reported so a hook-made row can be dropped.
    public bool IsHeadless { get; init; }
}

/// Watches the projects directory and reports sessions active in the last few hours.
/// Delivered on the UI thread. Implemented in ClaudeCode/TranscriptWatcher.cs.
public interface ITranscriptWatcherSink
{
    void TranscriptsChanged(IReadOnlyList<DiscoveredSession> sessions);
}

/// One entry of a repository's file tree, for the Files tab. Built by Features/Files/RepoFiles.cs.
public sealed record FileTreeNode
{
    public string Id => Path;
    /// relative to the session's cwd
    public string Path { get; init; } = "";
    public string Name { get; init; } = "";
    public bool IsDirectory { get; init; }
    public IReadOnlyList<FileTreeNode> Children { get; init; } = [];

    public bool Equals(FileTreeNode? o)
        => o is not null && Path == o.Path && Name == o.Name && IsDirectory == o.IsDirectory
           && Children.SequenceEqual(o.Children);

    public override int GetHashCode() => HashCode.Combine(Path, Name, IsDirectory, Children.Count);
}

/// A file's text for the preview pane, capped. Built by Features/Files/RepoFiles.cs.
public sealed record FilePreview
{
    public string Path { get; init; } = "";
    public IReadOnlyList<string> Lines { get; init; } = [];
    public bool Truncated { get; init; }
    public bool IsBinary { get; init; }

    public bool Equals(FilePreview? o)
        => o is not null && Path == o.Path && Lines.SequenceEqual(o.Lines) && Truncated == o.Truncated && IsBinary == o.IsBinary;

    public override int GetHashCode() => HashCode.Combine(Path, Lines.Count, Truncated, IsBinary);
}

/// One of Claude Code's per-model weekly windows ("Fable"), from its usage cache.
public sealed record ModelWeek
{
    public string Id => Name;
    public string Name { get; init; } = "";
    public double Percent { get; init; }
    public DateTime? ResetsAt { get; init; }
}

/// A share with a name: "Claude Code 98%" (the week breakdown), from the usage cache.
public sealed record NamedShare
{
    public string Id => Name;
    public string Name { get; init; } = "";
    public double Percent { get; init; }
}

/// A gateway spend limit from the status line. Present only behind a gateway.
public sealed record SpendLimit
{
    public double Percent { get; init; }
    public DateTime? ResetsAt { get; init; }
    public double? UsedUSD { get; init; }
    public double? LimitUSD { get; init; }
    public string? Period { get; init; }
}

/// Limits and cost, when a source provides them. Every field optional: the UI degrades.
public sealed record UsageSnapshot
{
    public double? FiveHourPercent { get; init; }
    public DateTime? FiveHourResetsAt { get; init; }
    public double? WeekPercent { get; init; }
    public DateTime? WeekResetsAt { get; init; }
    public long? ContextUsed { get; init; }
    public long? ContextLimit { get; init; }
    public double? SessionCostUSD { get; init; }
    public double? TodayCostUSD { get; init; }
    public TokenUsage? TodayTokens { get; init; }
    public TokenUsage? SessionTokens { get; init; }
    /// Today's tokens and estimated cost on Fable models, from the transcripts' model ids.
    /// Claude Code's status line carries no per-model limit, so there is no Fable percent.
    public TokenUsage? TodayFableTokens { get; init; }
    public double? TodayFableCostUSD { get; init; }
    /// true when computed from tokens with our rate table, not reported by Claude
    public bool CostIsEstimate { get; init; } = true;
    /// Per-model weekly windows and where the week went, from Claude Code's usage cache.
    public IReadOnlyList<ModelWeek> ModelWeeks { get; init; } = [];
    public IReadOnlyList<NamedShare> WeekBreakdown { get; init; } = [];
    /// The status line's `rate_limits.spend_limit`, behind a gateway only.
    public SpendLimit? SpendLimit { get; init; }

    public bool Equals(UsageSnapshot? o)
        => o is not null && FiveHourPercent == o.FiveHourPercent && FiveHourResetsAt == o.FiveHourResetsAt
           && WeekPercent == o.WeekPercent && WeekResetsAt == o.WeekResetsAt && ContextUsed == o.ContextUsed
           && ContextLimit == o.ContextLimit && SessionCostUSD == o.SessionCostUSD && TodayCostUSD == o.TodayCostUSD
           && TodayTokens == o.TodayTokens && SessionTokens == o.SessionTokens && TodayFableTokens == o.TodayFableTokens
           && TodayFableCostUSD == o.TodayFableCostUSD && CostIsEstimate == o.CostIsEstimate
           && ModelWeeks.SequenceEqual(o.ModelWeeks) && WeekBreakdown.SequenceEqual(o.WeekBreakdown)
           && SpendLimit == o.SpendLimit;

    public override int GetHashCode() => HashCode.Combine(FiveHourPercent, WeekPercent, ContextUsed, SessionCostUSD, ModelWeeks.Count);
}
