// TranscriptReader.cs
// Port of Sources/notchcode/ClaudeCode/TranscriptReader.swift.
// Reads Claude Code's own session files,
// %USERPROFILE%\.claude\projects\<encoded cwd>\<session_id>.jsonl, into turns, file changes
// and token usage. (The git branch and repo name come from GitDir, which reads .git
// without running git.)
//
// Line shapes relied on (checked against real transcripts, 2026-09-27; the same on Windows,
// where `cwd` and `filePath` hold backslash paths):
//   {"type":"user","uuid","timestamp","cwd","isSidechain","isMeta"?,
//    "message":{"role":"user","content": String | [{type:"text"|"tool_result",...}]},
//    "toolUseResult"?: {"filePath","type":"create"|"update"?,"content"?,"structuredPatch":[hunk]}}
//   {"type":"assistant","timestamp","isSidechain",
//    "message":{"id","model","content":[{type:"text"|"thinking"|"tool_use",...}],"usage":{...}}}
// One API message is split over several assistant lines that share message.id and repeat
// the same usage, so usage is counted once per message id.
// Every other line type (system, attachment, file-history-snapshot, ...) only extends the turn's end.

using System.IO;

namespace Notchcode.ClaudeCode;

public static class TranscriptReader
{
    // MARK: Turns

    /// Cheap to call every couple of seconds: results are cached per path and keyed by
    /// (file id, mtime, size). When the file only grew, just the appended lines are parsed.
    ///
    /// Subagents (Agent tool) keep their lines in
    /// `<transcript dir>\<session id>\subagents\agent-<agentId>.jsonl`, not in the main file;
    /// each is parsed incrementally through its own cache, nested agents included. Their tokens
    /// belong to the turn that started them. Their edits belong to the turn running when the
    /// edit was made (a background agent outlives its turn, and SendMessage continues it in a
    /// later one), and are marked with the agent's id. The merged result is cached against the
    /// stamps of the main file and every subagent file.
    /// Throws FileNotFoundException (or another IOException) when the transcript cannot be read.
    public static List<TranscriptTurn> Turns(string transcriptPath)
    {
        var mainStamp = FileStamp.Of(transcriptPath);
        var raw = TurnCache.Value(transcriptPath);
        RecordQuestion(raw.Count > 0 ? raw[^1].Question : null, transcriptPath);
        var dir = SubagentsDirectory(transcriptPath);
        var metaIds = SubagentToolUseMap(dir);

        // Each turn's subagent logs, depth first in launch order. An agent is read once, for
        // the turn that launched it, even when a later turn's SendMessage continues it.
        var signature = new List<FileStamp?> { mainStamp };
        var perTurn = new List<List<EditLog>>(raw.Count);
        var visited = new HashSet<string>();
        foreach (var turn in raw)
        {
            var logs = new List<EditLog>();
            void Collect(EditLog log, int depth)
            {
                if (depth >= 8) return;
                foreach (var toolId in log.AgentToolUses)
                {
                    var agentId = log.AgentIds.GetValueOrDefault(toolId) ?? metaIds.GetValueOrDefault(toolId);
                    if (agentId is null || !visited.Add(agentId)) continue;
                    var path = Path.Combine(dir, "agent-" + agentId + ".jsonl");
                    var stamp = FileStamp.Of(path);
                    signature.Add(stamp);
                    if (stamp is null) continue;
                    EditLog sub;
                    try { sub = SubagentCache.Value(path); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                    logs.Add(sub);
                    Collect(sub, depth + 1);
                }
            }
            Collect(turn.Log, 0);
            perTurn.Add(logs);
        }

        lock (MergedLock)
        {
            if (Merged.TryGetValue(transcriptPath, out var hit) && hit.Signature.SequenceEqual(signature))
                return hit.Turns;
        }

        // Every subagent edit goes to the turn whose window (its prompt until the next
        // prompt) holds the edit's timestamp; never to a turn before the one that launched it.
        var agentEdits = Enumerable.Range(0, raw.Count).Select(_ => new List<EditLog.Edit>()).ToList();
        for (int launch = 0; launch < perTurn.Count; launch++)
        {
            foreach (var log in perTurn[launch])
            {
                foreach (var toolId in log.EditOrder)
                {
                    if (!log.Edits.TryGetValue(toolId, out var edit)) continue;
                    edit = edit with { AgentId = log.AgentId };
                    int target = edit.At is { } at ? Math.Max(launch, TurnIndex(at, raw)) : launch;
                    agentEdits[target].Add(edit);
                }
            }
        }

        var turns = Enumerable.Range(0, raw.Count).Select(i => EditLog.Turn(raw[i], perTurn[i], agentEdits[i])).ToList();
        lock (MergedLock) Merged[transcriptPath] = (signature, turns);
        return turns;
    }

    /// The last turn that started at or before `date` (turns are in transcript order).
    private static int TurnIndex(DateTime date, List<RawTurn> raw)
    {
        int low = 0, high = raw.Count - 1, found = 0;
        while (low <= high)
        {
            int mid = (low + high) / 2;
            if (raw[mid].StartedAt <= date) { found = mid; low = mid + 1; } else { high = mid - 1; }
        }
        return found;
    }

    /// Drops everything cached for this transcript and its subagent files, so a session that
    /// left the list does not keep its parsed turns in memory for the life of the app.
    public static void Forget(string transcriptPath)
    {
        var dir = SubagentsDirectory(transcriptPath);
        TurnCache.Forget(transcriptPath);
        AgentCache.Forget(transcriptPath);
        SubagentCache.ForgetUnder(dir + Path.DirectorySeparatorChar);
        lock (MergedLock) Merged.Remove(transcriptPath);
        lock (MetaLock) MetaCache.Remove(dir);
        lock (QuestionLock) LastQuestions.Remove(transcriptPath);
    }

    /// Sets `EndedAt` on every agent still running. The UI calls it when a session ends.
    public static List<Agent> CloseAgents(IEnumerable<Agent> agents, DateTime date)
        => agents.Select(a => a.EndedAt is not null ? a : a with { EndedAt = date > a.StartedAt ? date : a.StartedAt }).ToList();

    private static readonly IncrementalCache<TurnBuilder, List<RawTurn>> TurnCache = new(
        make: () => new TurnBuilder(),
        consume: (b, line) => b.Consume(line),
        clone: b => b.Clone(),
        finish: b => b.Clone().Finish());

    private static readonly IncrementalCache<SubagentBuilder, EditLog> SubagentCache = new(
        make: () => new SubagentBuilder(),
        consume: (b, line) => b.Consume(line),
        clone: b => b.Clone(),
        finish: b => b.Log.Clone());

    private static readonly object MergedLock = new();
    private static readonly Dictionary<string, (List<FileStamp?> Signature, List<TranscriptTurn> Turns)> Merged
        = new(StringComparer.OrdinalIgnoreCase);

    /// `<dir>\<session id>\subagents` for `<dir>\<session id>.jsonl`.
    private static string SubagentsDirectory(string path)
        => Path.Combine(Path.ChangeExtension(path, null) ?? path, "subagents");

    private static readonly object MetaLock = new();
    private static readonly Dictionary<string, (double MTime, Dictionary<string, string> Map)> MetaCache
        = new(StringComparer.OrdinalIgnoreCase);

    /// tool_use id -> agentId from the `agent-<id>.meta.json` files, so a foreground agent's
    /// edits show while it runs, before its tool result (which carries agentId) is written.
    /// Re-read only when the directory's mtime changes (a new agent file appears).
    private static Dictionary<string, string> SubagentToolUseMap(string directory)
    {
        if (FileStamp.Of(directory) is not { } stamp) return [];
        lock (MetaLock)
        {
            if (MetaCache.TryGetValue(directory, out var hit) && hit.MTime == stamp.MTime) return hit.Map;
        }

        var map = new Dictionary<string, string>();
        IEnumerable<string> names;
        try { names = Directory.EnumerateFiles(directory, "agent-*.meta.json").Select(Path.GetFileName).OfType<string>().ToList(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { names = []; }
        foreach (var name in names)
        {
            if (!name.StartsWith("agent-", StringComparison.Ordinal) || !name.EndsWith(".meta.json", StringComparison.Ordinal)) continue;
            var agentId = name["agent-".Length..^".meta.json".Length];
            try
            {
                var data = File.ReadAllBytes(Path.Combine(directory, name));
                if (JsonLines.Parse(data) is { } obj && obj.Str("toolUseId") is { Length: > 0 } toolId)
                    map[toolId] = agentId;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        lock (MetaLock) MetaCache[directory] = (stamp.MTime, map);
        return map;
    }

    private static readonly IncrementalCache<AgentBuilder, List<Agent>> AgentCache = new(
        make: () => new AgentBuilder(),
        consume: (b, line) => b.Consume(line),
        clone: b => b.Clone(),
        finish: b => b.Finish());

    private static readonly object QuestionLock = new();
    private static readonly Dictionary<string, AskedQuestion> LastQuestions = new(StringComparer.OrdinalIgnoreCase);

    /// The newest turn's last `AskUserQuestion` call, as of the last `Turns` read: the
    /// Notification that says Claude waits carries only a message, not the options.
    public static AskedQuestion? LastQuestion(string transcriptPath)
    {
        lock (QuestionLock) return LastQuestions.GetValueOrDefault(transcriptPath);
    }

    private static void RecordQuestion(AskedQuestion? question, string path)
    {
        lock (QuestionLock)
        {
            if (question is null) LastQuestions.Remove(path);
            else LastQuestions[path] = question;
        }
    }

    // MARK: Agents

    /// The subagents Claude started in this session (Agent tool, "Task" in older transcripts),
    /// oldest first. `Id` is the subagent's agentId when the transcript has it (the same value
    /// the SubagentStart / SubagentStop hooks send as `agent_id`), else the tool_use id.
    /// Returns [] when the file cannot be read.
    ///
    /// Line shapes relied on (checked against real transcripts and
    /// https://code.claude.com/docs/en/hooks.md, 2026-09-27):
    ///   start   assistant line, content block {type:"tool_use", name:"Agent"|"Task", id,
    ///           input:{description, subagent_type, prompt}}
    ///   result  user line with {type:"tool_result", tool_use_id} and toolUseResult
    ///           {status:"completed"|"async_launched", agentId, ...}. "completed" (foreground) ends
    ///           the agent. "async_launched" (background, the default since v2.1.198) does not.
    ///   end     for background agents: a "&lt;task-notification&gt;" text holding
    ///           &lt;tool-use-id&gt;…&lt;/tool-use-id&gt; and &lt;status&gt;completed|failed|…&lt;/status&gt;, found in a
    ///           queue-operation line's `content`, an attachment's `prompt`, or a user message;
    ///           or a user line whose origin is {handback:true, from:&lt;agentId&gt;}.
    ///   older   sidechain lines (isSidechain true) in the main file carry `agentId`; the id is
    ///           given to the earliest open agent that has none yet.
    public static List<Agent> Agents(string transcriptPath)
    {
        try { return AgentCache.Value(transcriptPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    // MARK: Paths

    /// Claude Code's project directory name for a cwd: every character that is not an ASCII
    /// letter or digit becomes "-" (C:\Users\a\my.app -> C--Users-a-my-app).
    public static string EncodedProjectName(string cwd) => NotchcodePaths.ProjectFolderName(cwd);

    /// The newest transcript of the project folder Claude Code keeps for `cwd`, or null.
    /// The cwd is normalised first (`C:/x/` and `c:\x` are the same folder on Windows); a
    /// folder name Claude Code cut at 200 characters (and suffixed) is found by its prefix.
    public static string? LatestTranscriptPath(string cwd, string? projectsDirectory = null)
    {
        var root = projectsDirectory ?? NotchcodePaths.ClaudeProjectsDirectory;
        var normalized = Normalize(cwd);
        var candidates = new List<string> { EncodedProjectName(normalized) };
        var raw = EncodedProjectName(cwd);
        if (!candidates.Contains(raw, StringComparer.OrdinalIgnoreCase)) candidates.Add(raw);

        foreach (var name in candidates)
        {
            var dirs = new List<string>();
            var exact = Path.Combine(root, name);
            if (Directory.Exists(exact)) dirs.Add(exact);
            else if (name.Length >= 200)
            {
                try { dirs.AddRange(Directory.EnumerateDirectories(root, name + "*")); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            string? best = null;
            var bestDate = DateTime.MinValue;
            foreach (var dir in dirs)
            {
                IEnumerable<FileInfo> items;
                try { items = new DirectoryInfo(dir).EnumerateFiles("*.jsonl").ToList(); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                foreach (var item in items)
                {
                    if (item.Name.StartsWith('.') || (item.Attributes & FileAttributes.Hidden) != 0) continue;
                    if (best is null || item.LastWriteTimeUtc > bestDate) { best = item.FullName; bestDate = item.LastWriteTimeUtc; }
                }
            }
            if (best is not null) return best;
        }
        return null;
    }

    /// The full path without a trailing separator ("C:\" keeps its own); the input when it is not a path.
    public static string Normalize(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        try
        {
            var full = Path.GetFullPath(path.Replace('/', '\\'));
            var root = Path.GetPathRoot(full);
            return full.Length > (root?.Length ?? 0) ? full.TrimEnd('\\') : full;
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return path; }
    }

    /// Two working folders are the same: normalised, ignoring case.
    public static bool SamePath(string? a, string? b)
        => a is not null && b is not null && string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);
}
