// TranscriptTurns.cs
// Port of Sources/notchcode/ClaudeCode/TranscriptTurns.swift.
// Builds turns from transcript lines for TranscriptReader: the main transcript's turns
// (prompt, model, times, the last context size, an AskUserQuestion), a subagent file's
// edits, and the edit log both gather (file edits with their diff lines, token usage,
// started subagents) and merge into a turn.
//
// The Swift builders are value types copied by the incremental cache; here each has a
// `Clone()` that copies everything a later `Consume` could change.

using Notchcode.UI;

namespace Notchcode.ClaudeCode;

// MARK: - Turn building

/// An `AskUserQuestion` call's first question: `questions[0]` with its header and option labels.
public sealed record AskedQuestion
{
    public string Question { get; init; } = "";
    public string? Header { get; init; }
    public IReadOnlyList<string> Options { get; init; } = [];

    public bool Equals(AskedQuestion? o)
        => o is not null && Question == o.Question && Header == o.Header && Options.SequenceEqual(o.Options);

    public override int GetHashCode() => HashCode.Combine(Question, Header, Options.Count);
}

/// One turn as parsed from the main transcript, before its subagents' edits are merged in.
public sealed class RawTurn
{
    public string Id = "";
    public string Prompt = "";
    public DateTime StartedAt;
    public DateTime? EndedAt;
    public string? Model;
    public EditLog Log = new();
    public string? Cwd;
    public long? LastContext;
    public AskedQuestion? Question;

    public RawTurn Clone() => new()
    {
        Id = Id, Prompt = Prompt, StartedAt = StartedAt, EndedAt = EndedAt, Model = Model,
        Log = Log.Clone(), Cwd = Cwd, LastContext = LastContext, Question = Question,
    };
}

public sealed class TurnBuilder
{
    // Closed turns are never changed again, so a clone shares them.
    private List<RawTurn> _turns = [];
    private RawTurn? _current;
    private string? _cwd;

    public TurnBuilder Clone() => new()
    {
        _turns = [.. _turns],
        _current = _current?.Clone(),
        _cwd = _cwd,
    };

    public void Consume(JsonValue line)
    {
        if (line.IsTrue("isSidechain")) return;
        if (line.Str("cwd") is { Length: > 0 } c) _cwd = c;
        var date = IsoDate.Parse(line["timestamp"]);
        var type = line.Str("type");

        if (type == "user" && JsonLines.PromptText(line) is { } prompt)
        {
            CloseCurrent();
            _current = new RawTurn
            {
                Id = line.Str("uuid") ?? Guid.NewGuid().ToString().ToUpperInvariant(),
                Prompt = prompt,
                StartedAt = date ?? DateTime.UnixEpoch,
                EndedAt = date,
            };
            return;
        }

        if (_current is null) return;
        if (date is { } d) _current.EndedAt = _current.EndedAt is { } e && e > d ? e : d;

        switch (type)
        {
            case "assistant":
                if (line.Obj("message") is not { } message) return;
                if (message.Str("model") is { } model && !model.StartsWith('<')) _current.Model = model;
                if (_current.Log.ConsumeAssistant(message, date) is { } context) _current.LastContext = context;
                if (AskedQuestionIn(message) is { } asked) _current.Question = asked;
                break;
            case "user":
                _current.Log.ConsumeToolResult(line);
                break;
        }
    }

    /// The last `AskUserQuestion` tool_use in an assistant message, if any.
    private static AskedQuestion? AskedQuestionIn(JsonValue message)
    {
        if (message["content"].Objects() is not { } blocks) return null;
        AskedQuestion? found = null;
        foreach (var block in blocks)
        {
            if (block.Str("type") != "tool_use" || block.Str("name") != "AskUserQuestion") continue;
            if (block.Obj("input") is not { } input
                || input["questions"].Objects() is not { Count: > 0 } questions
                || questions[0].Str("question") is not { } text) continue;
            var first = questions[0];
            var options = (first["options"].Objects() ?? [])
                .Select(o => o.Str("label")).OfType<string>().ToList();
            found = new AskedQuestion { Question = text, Header = first.Str("header"), Options = options };
        }
        return found;
    }

    /// The turns so far, the open one closed. Changes the builder: call it on a clone.
    public List<RawTurn> Finish()
    {
        CloseCurrent();
        return _turns;
    }

    private void CloseCurrent()
    {
        if (_current is not { } p) return;
        _current = null;
        p.Cwd = _cwd;
        _turns.Add(p);
    }
}

/// A subagent's own transcript (`<session>\subagents\agent-<id>.jsonl`): every line is
/// sidechain. Its tokens belong to the parent turn that started the agent; its edits carry
/// their timestamps and the agent's id, so they land on the turn running when they were made.
public sealed class SubagentBuilder
{
    public EditLog Log = new();

    public SubagentBuilder Clone() => new() { Log = Log.Clone() };

    public void Consume(JsonValue line)
    {
        if (Log.AgentId is null && line.Str("agentId") is { Length: > 0 } id) Log.AgentId = id;
        switch (line.Str("type"))
        {
            case "assistant":
                if (line.Obj("message") is { } message)
                    Log.ConsumeAssistant(message, IsoDate.Parse(line["timestamp"]));
                break;
            case "user":
                Log.ConsumeToolResult(line);
                break;
        }
    }
}

// MARK: - Edit log

/// File edits, token usage and started subagents, gathered from one run of transcript lines
/// (a main-thread turn or a whole subagent file). Several logs merge into one turn.
public sealed class EditLog
{
    public sealed record Edit
    {
        public string Path { get; init; } = "";
        /// "edit", "write", "new"
        public string Kind { get; init; } = "edit";
        public int Added { get; init; }
        public int Removed { get; init; }
        /// from structuredPatch, when the tool result is seen; capped
        public IReadOnlyList<DiffLine>? Hunks { get; init; }
        /// hunks stopped at the cap
        public bool Truncated { get; init; }
        /// the assistant line's timestamp
        public DateTime? At { get; init; }
        /// set when a subagent made it
        public string? AgentId { get; init; }
    }

    /// by tool_use id
    public Dictionary<string, Edit> Edits = [];
    public List<string> EditOrder = [];
    public Dictionary<string, TokenUsage> UsageByMessage = [];
    public TokenUsage AnonymousUsage = new();
    /// Agent / Task tool_use ids, in launch order
    public List<string> AgentToolUses = [];
    /// tool_use id -> agentId, from the tool result
    public Dictionary<string, string> AgentIds = [];
    /// a subagent's own log: its id
    public string? AgentId;

    /// changed lines; below this the card shows the snippet
    public const int SnippetLimit = 8;

    public EditLog Clone() => new()
    {
        Edits = new(Edits),
        EditOrder = [.. EditOrder],
        UsageByMessage = new(UsageByMessage),
        AnonymousUsage = AnonymousUsage,
        AgentToolUses = [.. AgentToolUses],
        AgentIds = new(AgentIds),
        AgentId = AgentId,
    };

    /// Usage, edits and agent launches of one assistant line. Returns the message's
    /// input-side token count (input + cache read + cache write) when it has usage.
    public long? ConsumeAssistant(JsonValue message, DateTime? date)
    {
        long? context = null;
        if (message.Obj("usage") is { } usage)
        {
            var u = new TokenUsage
            {
                Input = Int(usage["input_tokens"]),
                Output = Int(usage["output_tokens"]),
                CacheRead = Int(usage["cache_read_input_tokens"]),
                CacheWrite = Int(usage["cache_creation_input_tokens"]),
            };
            if (message.Str("id") is { } id)
                UsageByMessage[id] = u;        // repeated lines of one message: keep the last
            else
                AnonymousUsage = Add(AnonymousUsage, u);
            long c = u.Input + u.CacheRead + u.CacheWrite;
            if (c > 0) context = c;
        }
        if (message["content"].Objects() is { } blocks)
        {
            foreach (var block in blocks)
                if (block.Str("type") == "tool_use") ConsumeToolUse(block, date);
        }
        return context;
    }

    private void ConsumeToolUse(JsonValue block, DateTime? date)
    {
        if (block.Str("name") is not { } name) return;
        var toolId = block.Str("id") ?? Guid.NewGuid().ToString().ToUpperInvariant();
        if (name is "Agent" or "Task")
        {
            if (!AgentToolUses.Contains(toolId)) AgentToolUses.Add(toolId);
            return;
        }
        if (block.Obj("input") is not { } input || input.Str("file_path") is not { Length: > 0 } path) return;

        Edit edit;
        switch (name)
        {
            case "Edit":
                edit = new Edit
                {
                    Path = path, Kind = "edit",
                    Added = LineCount(input.Str("new_string")),
                    Removed = LineCount(input.Str("old_string")),
                };
                break;
            case "MultiEdit":
                int added = 0, removed = 0;
                foreach (var e in input["edits"].Objects() ?? [])
                {
                    added += LineCount(e.Str("new_string"));
                    removed += LineCount(e.Str("old_string"));
                }
                edit = new Edit { Path = path, Kind = "edit", Added = added, Removed = removed };
                break;
            case "Write":
                edit = new Edit { Path = path, Kind = "write", Added = LineCount(input.Str("content")), Removed = 0 };
                break;
            default:
                return;
        }
        Edits.TryGetValue(toolId, out var previous);
        if (previous is null) EditOrder.Add(toolId);
        Edits[toolId] = edit with { Hunks = previous?.Hunks, At = previous?.At ?? date };
    }

    /// A tool_result line: replace the estimate with exact counts from structuredPatch,
    /// or note the agentId of a started subagent.
    public void ConsumeToolResult(JsonValue line)
    {
        if (line.Obj("toolUseResult") is not { } result
            || line.Obj("message") is not { } message
            || message["content"].Objects() is not { } blocks
            || blocks.FirstOrDefault(b => b.Str("type") == "tool_result")?.Str("tool_use_id") is not { } toolId)
            return;

        if (result.Str("agentId") is { Length: > 0 } agentId && AgentToolUses.Contains(toolId))
        {
            AgentIds[toolId] = agentId;
            return;
        }
        if (!Edits.TryGetValue(toolId, out var edit)) return;

        if (result.Str("type") == "create") edit = edit with { Kind = "new" };
        if (result["structuredPatch"].Objects() is { } patch)
        {
            if (patch.Count > 0)
            {
                var diff = DiffLines(patch);
                edit = edit with { Added = diff.Added, Removed = diff.Removed, Hunks = diff.Lines, Truncated = diff.Truncated };
            }
            else if (edit.Kind == "new" && result.Str("content") is { } content)
            {
                // A new file: Claude Code records no patch, so every written line is an addition.
                var diff = DiffLinesForNewFile(content);
                edit = edit with { Added = diff.Added, Removed = 0, Hunks = diff.Lines, Truncated = diff.Truncated };
            }
            else
            {
                if (edit.Kind != "new") edit = edit with { Added = 0, Removed = 0 };
                edit = edit with { Hunks = [] };
            }
        }
        Edits[toolId] = edit;
    }

    // MARK: Merging into a turn

    private sealed class Merged
    {
        public FileChange Change = new();
        public List<DiffLine> Hunks = [];
        public bool Exact;
        public bool Truncated;
    }

    /// Builds the turn from its main-thread log, the logs of the subagents it launched (their
    /// usage) and the subagent edits made while it ran (`agentEdits`, in order). Usage is
    /// counted once per message id across all logs; repeated edits of one file merge. A file
    /// only subagents touched carries the first one's id.
    public static TranscriptTurn Turn(RawTurn raw, IReadOnlyList<EditLog> subagents, IReadOnlyList<Edit> agentEdits)
    {
        var logs = new List<EditLog> { raw.Log };
        logs.AddRange(subagents);

        var tokens = new TokenUsage();
        var seen = new HashSet<string>();
        foreach (var log in logs)
        {
            tokens = Add(tokens, log.AnonymousUsage);
            foreach (var (id, u) in log.UsageByMessage)
                if (seen.Add(id)) tokens = Add(tokens, u);
        }

        // Merge repeated edits of one file, in first-touched order; patches concatenate in order.
        var order = new List<string>();
        var merged = new Dictionary<string, Merged>();
        // The main thread's edits and the agents' ones in the order they were made.
        var edits = raw.Log.EditOrder.Select(id => raw.Log.Edits.GetValueOrDefault(id)).OfType<Edit>()
            .Concat(agentEdits)
            .Select((e, i) => (e, i))
            .OrderBy(p => p.e.At ?? DateTime.MaxValue)
            .ThenBy(p => p.i)
            .Select(p => p.e)
            .ToList();
        foreach (var e in edits)
        {
            var path = Paths.Relative(e.Path, raw.Cwd);
            if (merged.TryGetValue(path, out var m))
            {
                var change = m.Change;
                if (e.AgentId is null) change = change with { AgentId = null };
                m.Change = change with
                {
                    Added = change.Added + e.Added,
                    Removed = change.Removed + e.Removed,
                    Kind = StrongerKind(change.Kind, e.Kind),
                };
                if (e.Hunks is { } h)
                {
                    if (m.Hunks.Count <= Theme.Limits.PatchLines) m.Hunks.AddRange(h);
                }
                else
                {
                    m.Exact = false;
                }
                m.Truncated = m.Truncated || e.Truncated;
            }
            else
            {
                order.Add(path);
                merged[path] = new Merged
                {
                    Change = new FileChange { Path = path, Added = e.Added, Removed = e.Removed, Kind = e.Kind, AgentId = e.AgentId },
                    Hunks = e.Hunks is { } hunks ? [.. hunks] : [],
                    Exact = e.Hunks is not null,
                    Truncated = e.Truncated,
                };
            }
        }
        var files = new List<FileChange>();
        foreach (var path in order)
        {
            var m = merged[path];
            var change = m.Change;
            int changed = change.Added + change.Removed;
            if (m.Exact && changed > 0 && changed < SnippetLimit) change = change with { Snippet = m.Hunks };
            if (m.Hunks.Count > Theme.Limits.PatchLines)
                change = change with { Patch = m.Hunks.Take(Theme.Limits.PatchLines).ToList(), PatchTruncated = true };
            else
                change = change with { Patch = m.Hunks, PatchTruncated = m.Truncated };
            files.Add(change);
        }

        return new TranscriptTurn
        {
            Id = raw.Id,
            Prompt = raw.Prompt,
            StartedAt = raw.StartedAt,
            EndedAt = raw.EndedAt,
            Files = files,
            Tokens = tokens,
            Model = raw.Model,
            ContextTokens = raw.LastContext,
        };
    }

    // MARK: Diff lines

    private sealed class Diff
    {
        public List<DiffLine> Lines = [];
        public int Added;
        public int Removed;
        public bool Truncated;

        /// Counts every line, keeps at most `PatchLines` (one over, so the merge sees the overflow).
        public void Append(DiffLine line)
        {
            if (Lines.Count > Theme.Limits.PatchLines) { Truncated = true; return; }
            Lines.Add(line);
        }
    }

    /// Every hunk of a structuredPatch: a `@@ -a,b +c,d @@` header, then context / added /
    /// removed lines numbered from the header.
    private static Diff DiffLines(IReadOnlyList<JsonValue> patch)
    {
        var diff = new Diff();
        foreach (var hunk in patch)
        {
            int oldStart = (int)Int(hunk["oldStart"]);
            int newStart = (int)Int(hunk["newStart"]);
            diff.Append(new DiffLine
            {
                Kind = DiffLineKind.Hunk,
                Text = $"@@ -{oldStart},{Int(hunk["oldLines"])} +{newStart},{Int(hunk["newLines"])} @@",
            });
            int oldLine = oldStart, newLine = newStart;
            // Swift's `as? [String]`: a lines array with anything but strings counts as none.
            var rawLines = hunk["lines"]?.ArrayValue;
            if (rawLines is null || rawLines.Any(l => l.Kind != JsonValueKind.String)) continue;
            foreach (var item in rawLines)
            {
                var raw = item.StringValue!;
                char marker = raw.Length > 0 ? raw[0] : ' ';
                var text = raw.Length == 0 ? "" : raw[1..];
                switch (marker)
                {
                    case '+':
                        diff.Added++;
                        diff.Append(new DiffLine { Kind = DiffLineKind.Added, Text = text, NewLine = newLine });
                        newLine++;
                        break;
                    case '-':
                        diff.Removed++;
                        diff.Append(new DiffLine { Kind = DiffLineKind.Removed, Text = text, OldLine = oldLine });
                        oldLine++;
                        break;
                    case '\\':
                        break; // "\ No newline at end of file"
                    default:
                        diff.Append(new DiffLine { Kind = DiffLineKind.Context, Text = text, OldLine = oldLine, NewLine = newLine });
                        oldLine++;
                        newLine++;
                        break;
                }
            }
        }
        return diff;
    }

    /// A new file as one all-added hunk: `@@ -0,0 +1,N @@`.
    private static Diff DiffLinesForNewFile(string content)
    {
        var diff = new Diff();
        var lines = content.FileLines();
        int count = lines.Count;
        if (count == 0) return diff;
        diff.Append(new DiffLine { Kind = DiffLineKind.Hunk, Text = $"@@ -0,0 +1,{count} @@" });
        int n = 1;
        foreach (var raw in lines)
        {
            if (diff.Lines.Count > Theme.Limits.PatchLines) { diff.Truncated = true; break; }
            diff.Append(new DiffLine { Kind = DiffLineKind.Added, Text = raw, NewLine = n });
            n++;
        }
        diff.Added = count;
        return diff;
    }

    // MARK: Small helpers

    private static string StrongerKind(string a, string b)
    {
        static int Rank(string k) => k switch { "write" => 1, "new" => 2, _ => 0 };
        return Rank(b) > Rank(a) ? b : a;
    }

    internal static TokenUsage Add(TokenUsage a, TokenUsage b) => new()
    {
        Input = a.Input + b.Input,
        Output = a.Output + b.Output,
        CacheRead = a.CacheRead + b.CacheRead,
        CacheWrite = a.CacheWrite + b.CacheWrite,
    };

    private static long Int(JsonValue? v) => v?.LongValue ?? 0;

    /// Lines in a string: "" is 0, "a" is 1, "a\nb" is 2, "a\n" is 1; CRLF is one break.
    private static int LineCount(string? s) => s?.FileLines().Count ?? 0;
}
