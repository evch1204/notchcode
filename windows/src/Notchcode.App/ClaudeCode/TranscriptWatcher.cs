// TranscriptWatcher.cs
// Port of Sources/notchcode/ClaudeCode/TranscriptWatcher.swift.
// Finds live Claude Code sessions with no hooks at all, by polling
// %USERPROFILE%\.claude\projects\<encoded cwd>\<session_id>.jsonl every 2 s (the way
// sidecar-pane does), on a background thread. Results reach the sink on the WPF dispatcher
// when an Application exists, else synchronously on the polling thread (tests).
//
// Per file it reads the head once (cwd, first timestamp) and, whenever the file's size or
// mtime changes, only its last 64 KB (last prompt, last conversation line). State is then
// derived from that cached tail on every pass, so "working" decays to idle without new writes.
//
// State rules, from the last non-sidechain user / assistant line (every other line type,
// such as system, attachment, mode, last-prompt, is ignored):
//   assistant with a tool_use block, < 3 min old          -> working, verb from the tool
//   assistant mid-turn (stop_reason tool_use or none yet), < 3 min -> working "Thinking"
//   assistant that ended its turn (end_turn etc.), < 10 min -> done
//   user prompt / tool result / task notification, < 3 min -> working "Thinking"
//   interruption, local command output, anything older      -> idle
// Age is measured from that line's own timestamp.
//
// Permission mode ("default", "plan", "bypassPermissions", "acceptEdits", "auto", ...) comes from
// the last non-sidechain line that carries `permissionMode`: every prompt line, and the
// `permission-mode` line Claude Code writes when the owner switches modes mid-session.

using System.IO;
using System.Windows;

namespace Notchcode.ClaudeCode;

public sealed class TranscriptWatcher : IDisposable
{
    private readonly WeakReference<ITranscriptWatcherSink> _sink;
    private readonly double _lookback;
    private readonly string _projectsDirectory;
    private readonly Func<DateTime> _clock;
    private readonly object _runLock = new();
    private CancellationTokenSource? _cts;
    private Thread? _thread;

    // Touched only on the polling thread (or under _pollLock for PollOnce).
    private readonly object _pollLock = new();
    private readonly Dictionary<string, FileInfo> _files = new(StringComparer.OrdinalIgnoreCase);
    private List<DiscoveredSession>? _lastDelivered;

    public const double Interval = 2;
    public const int TailBytes = 64 * 1024;
    public const int HeadBytes = 64 * 1024;
    public const double WorkingWindow = 3 * 60;
    public const double DoneWindow = 10 * 60;

    /// `projectsDirectory` and `clock` exist for tests; the app uses the defaults.
    public TranscriptWatcher(ITranscriptWatcherSink sink, double lookback = 6 * 3600,
                             string? projectsDirectory = null, Func<DateTime>? clock = null)
    {
        _sink = new WeakReference<ITranscriptWatcherSink>(sink);
        _lookback = lookback;
        _projectsDirectory = projectsDirectory ?? NotchcodePaths.ClaudeProjectsDirectory;
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    public void Dispose() => Stop();

    public void Start()
    {
        lock (_runLock)
        {
            if (_thread is not null) return;
            var cts = new CancellationTokenSource();
            _cts = cts;
            _thread = new Thread(() => Loop(cts.Token))
            {
                IsBackground = true,
                Name = "notchcode.transcript-watcher",
                Priority = ThreadPriority.BelowNormal,
            };
            _thread.Start();
        }
    }

    public void Stop()
    {
        lock (_runLock)
        {
            _cts?.Cancel();
            _cts = null;
            _thread = null;
        }
    }

    private void Loop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try { PollOnce(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            token.WaitHandle.WaitOne(TimeSpan.FromSeconds(Interval));
        }
    }

    // MARK: Polling

    private sealed record Head
    {
        public string? Cwd { get; init; }
        public DateTime? StartedAt { get; init; }
        /// "cli" for the owner's sessions, "sdk-cli" for Claude Code's own helper runs
        public string? Entrypoint { get; init; }
    }

    /// The `entrypoint` Claude Code writes on the lines of a run it started for itself (naming a
    /// branch, summarising) in the same folder as a real session. Those never reach the list.
    public const string HeadlessEntrypoint = "sdk-cli";

    private enum LastKind { None, ToolUse, MidTurn, TurnEnded, UserActive, UserIdle }

    /// none · toolUse(name, at) · midTurn(at): assistant text / thinking that will be followed by
    /// more · turnEnded(at) · userActive(at): prompt, tool result, task notification ·
    /// userIdle: interruption, local command output.
    private readonly record struct LastLine(LastKind Kind, string Name = "", DateTime At = default);

    private sealed record FileInfo
    {
        public FileStamp Stamp { get; init; }
        public Head Head { get; init; } = new();
        public LastLine Last { get; init; }
        public string? LastPrompt { get; init; }
        /// a cwd seen in the tail, for heads that have none
        public string? FallbackCwd { get; init; }
        /// the last one written, raw
        public string? PermissionMode { get; init; }
        // The whole file was already searched for a prompt / a mode (this file id): a file
        // with none is not re-read in full on every change.
        public bool ScannedWholeForPrompt { get; init; }
        public bool ScannedWholeForMode { get; init; }
    }

    /// One pass: list, scan what changed, deliver when the list differs from the last one.
    /// Public for tests; the polling thread calls it every `Interval` seconds.
    public void PollOnce()
    {
        List<DiscoveredSession> list;
        lock (_pollLock)
        {
            var now = _clock();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var sessions = new List<DiscoveredSession>();

            foreach (var (path, stamp) in ListTranscripts(now))
            {
                seen.Add(path);
                _files.TryGetValue(path, out var old);
                FileInfo info;
                if (old is not null && old.Stamp == stamp)
                {
                    info = old;
                }
                else if (Scan(path, stamp, old) is { } fresh)
                {
                    info = fresh;
                    _files[path] = fresh;
                }
                else
                {
                    continue;
                }
                var (state, verb) = State(info.Last, now);
                sessions.Add(new DiscoveredSession
                {
                    Id = Path.GetFileNameWithoutExtension(path),
                    Cwd = info.Head.Cwd ?? info.FallbackCwd ?? "",
                    TranscriptPath = path,
                    StartedAt = info.Head.StartedAt ?? stamp.Modified,
                    LastActivityAt = stamp.Modified,
                    State = state,
                    Verb = verb,
                    LastPrompt = info.LastPrompt,
                    PermissionMode = info.PermissionMode,
                    IsHeadless = info.Head.Entrypoint == HeadlessEntrypoint,
                });
            }
            foreach (var path in _files.Keys.Where(p => !seen.Contains(p)).ToList())
            {
                _files.Remove(path);
                // Past the lookback or deleted: the reader's caches for it go too.
                TranscriptReader.Forget(path);
            }

            sessions.Sort((a, b) => a.LastActivityAt != b.LastActivityAt
                ? b.LastActivityAt.CompareTo(a.LastActivityAt)
                : string.CompareOrdinal(a.Id, b.Id));
            if (_lastDelivered is not null && _lastDelivered.SequenceEqual(sessions)) return;
            _lastDelivered = sessions;
            list = sessions;
        }
        Deliver(list);
    }

    private void Deliver(IReadOnlyList<DiscoveredSession> list)
    {
        if (!_sink.TryGetTarget(out var sink)) return;
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null) { sink.TranscriptsChanged(list); return; }
        dispatcher.BeginInvoke(() =>
        {
            if (_sink.TryGetTarget(out var s)) s.TranscriptsChanged(list);
        });
    }

    /// `projects\*\*.jsonl` modified within `lookback`. Subagent transcripts live one level
    /// deeper (`<session>\subagents\`), so they are never listed.
    private List<(string Path, FileStamp Stamp)> ListTranscripts(DateTime now)
    {
        var result = new List<(string, FileStamp)>();
        IEnumerable<string> projects;
        try { projects = Directory.EnumerateDirectories(_projectsDirectory).ToList(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return result; }
        foreach (var dir in projects)
        {
            var project = Path.GetFileName(dir);
            if (project.StartsWith('.') || project == "subagents") continue;
            IEnumerable<string> names;
            try { names = Directory.EnumerateFiles(dir, "*.jsonl").ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var path in names)
            {
                var name = Path.GetFileName(path);
                // EnumerateFiles' "*.jsonl" also matches "x.jsonlx" through 8.3 names: check again.
                if (!name.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) || name.StartsWith('.')) continue;
                // A cheap date check first, so only recent files are opened for their stamp.
                try { if ((now - File.GetLastWriteTimeUtc(path)).TotalSeconds > _lookback + 60) continue; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                if (FileStamp.Of(path) is not { } stamp || (now - stamp.Modified).TotalSeconds > _lookback) continue;
                result.Add((path, stamp));
            }
        }
        return result;
    }

    // MARK: Reading one file

    private FileInfo? Scan(string path, FileStamp stamp, FileInfo? previous)
    {
        // Transcripts only grow; a shrink or a new file id means a different file.
        bool sameFile = previous is not null && previous.Stamp.FileId == stamp.FileId && stamp.Size >= previous.Stamp.Size;

        var head = sameFile ? previous!.Head : new Head();
        if (head.Cwd is null || head.StartedAt is null) head = ReadHead(path, head);

        long offset = Math.Max(0, stamp.Size - TailBytes);
        byte[] data;
        try { data = JsonLines.Read(path, offset, TailBytes); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        var tail = new TailScan();
        ReadOnlySpan<byte> body = data;
        if (offset > 0)
        {
            int nl = body.IndexOf((byte)0x0A);
            if (nl >= 0) body = body[(nl + 1)..]; // drop the cut line
        }
        int consumed = JsonLines.ForEachCompleteLine(body, tail.Consume);
        if (consumed < body.Length && JsonLines.Parse(body[consumed..]) is { } last) tail.Consume(last);

        // A new file id starts over; the same file keeps what it already searched.
        bool scannedForPrompt = sameFile && previous!.ScannedWholeForPrompt;
        bool scannedForMode = sameFile && previous!.ScannedWholeForMode;

        var lastPrompt = tail.LastPrompt;
        if (lastPrompt is null)
        {
            if (sameFile && previous!.LastPrompt is { } old)
            {
                lastPrompt = old;                                // no new prompt since the last pass
            }
            else if (offset > 0 && !scannedForPrompt)
            {
                lastPrompt = LastPromptInWholeFile(path);        // once, for a large file
                scannedForPrompt = true;
            }
        }

        var mode = tail.PermissionMode;
        if (mode is null)
        {
            if (sameFile && previous!.PermissionMode is { } old)
            {
                mode = old;                                      // no mode written since the last pass
            }
            else if (offset > 0 && !scannedForMode)
            {
                mode = PermissionModeInWholeFile(path);
                scannedForMode = true;
            }
        }

        return new FileInfo
        {
            Stamp = stamp,
            Head = head,
            Last = tail.Last,
            LastPrompt = lastPrompt,
            FallbackCwd = tail.Cwd ?? previous?.FallbackCwd,
            PermissionMode = mode,
            ScannedWholeForPrompt = scannedForPrompt,
            ScannedWholeForMode = scannedForMode,
        };
    }

    private static Head ReadHead(string path, Head head)
    {
        byte[] data;
        try { data = JsonLines.Read(path, 0, HeadBytes); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return head; }
        JsonLines.ForEachCompleteLine(data, line =>
        {
            if (head.Cwd is null && line.Str("cwd") is { Length: > 0 } c) head = head with { Cwd = c };
            if (head.StartedAt is null && IsoDate.Parse(line["timestamp"]) is { } d) head = head with { StartedAt = d };
            if (head.Entrypoint is null && line.Str("entrypoint") is { Length: > 0 } e) head = head with { Entrypoint = e };
        });
        return head;
    }

    private static string? LastPromptInWholeFile(string path)
    {
        byte[] data;
        try { data = JsonLines.Read(path, 0); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        string? prompt = null;
        JsonLines.ForEachCompleteLine(data, line =>
        {
            if (!line.IsTrue("isSidechain") && JsonLines.PromptText(line) is { } p) prompt = p;
        });
        return prompt;
    }

    private static string? PermissionModeInWholeFile(string path)
    {
        byte[] data;
        try { data = JsonLines.Read(path, 0); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        string? mode = null;
        JsonLines.ForEachCompleteLine(data, line =>
        {
            if (!line.IsTrue("isSidechain") && line.Str("permissionMode") is { Length: > 0 } m) mode = m;
        });
        return mode;
    }

    private sealed class TailScan
    {
        public LastLine Last = new(LastKind.None);
        public string? LastPrompt;
        public string? Cwd;
        public string? PermissionMode;

        public void Consume(JsonValue line)
        {
            if (line.IsTrue("isSidechain")) return;
            if (line.Str("cwd") is { Length: > 0 } c) Cwd = c;
            if (line.Str("permissionMode") is { Length: > 0 } m) PermissionMode = m;
            var date = IsoDate.Parse(line["timestamp"]) ?? DateTime.MinValue;
            switch (line.Str("type"))
            {
                case "assistant":
                {
                    if (line.Obj("message") is not { } message) return;
                    var blocks = message["content"].Objects() ?? [];
                    var tool = blocks.LastOrDefault(b => b.Str("type") == "tool_use");
                    if (tool is not null)
                    {
                        Last = new LastLine(LastKind.ToolUse, tool.Str("name") ?? "", date);
                    }
                    else
                    {
                        var stop = message.Str("stop_reason");
                        Last = stop is null or "tool_use"
                            ? new LastLine(LastKind.MidTurn, At: date)
                            : new LastLine(LastKind.TurnEnded, At: date);
                    }
                    break;
                }
                case "user":
                    if (JsonLines.PromptText(line) is { } p)
                    {
                        LastPrompt = p;
                        Last = new LastLine(LastKind.UserActive, At: date);
                    }
                    else if (JsonLines.UserText(line) is { } text)
                    {
                        bool idle = text.StartsWith("[Request interrupted", StringComparison.Ordinal)
                                    || text.StartsWith("<local-command-", StringComparison.Ordinal)
                                    || text.StartsWith("<command-name>", StringComparison.Ordinal); // local slash commands answer with stdout next
                        Last = idle ? new LastLine(LastKind.UserIdle) : new LastLine(LastKind.UserActive, At: date);
                        // A slash command that goes to Claude is still a prompt; PromptText caught it above.
                    }
                    else
                    {
                        Last = new LastLine(LastKind.UserActive, At: date); // a tool result: Claude is thinking again
                    }
                    break;
            }
        }
    }

    private static (SessionState, string?) State(LastLine last, DateTime now)
    {
        bool Recent(DateTime d, double window) => (now - d).TotalSeconds < window;
        return last.Kind switch
        {
            LastKind.ToolUse when Recent(last.At, WorkingWindow) => (SessionState.Working, Verb(last.Name)),
            LastKind.MidTurn or LastKind.UserActive when Recent(last.At, WorkingWindow) => (SessionState.Working, "Thinking"),
            LastKind.TurnEnded when Recent(last.At, DoneWindow) => (SessionState.Done, null),
            _ => (SessionState.Idle, null),
        };
    }

    public static string Verb(string toolName) => toolName switch
    {
        "Edit" or "Write" or "MultiEdit" or "NotebookEdit" => "Editing",
        "Bash" or "PowerShell" => "Running",
        "Read" or "Grep" or "Glob" => "Reading",
        "Agent" or "Task" => "Delegating",
        _ => "Working",
    };
}
