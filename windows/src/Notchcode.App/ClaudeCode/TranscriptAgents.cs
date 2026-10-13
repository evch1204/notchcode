// TranscriptAgents.cs
// Port of Sources/notchcode/ClaudeCode/TranscriptAgents.swift.
// Builds a session's agents from its main transcript: each Agent tool call, its subagent
// id, its description, and when it started and ended (its tool result, or the
// notification a background agent sends when it finishes). TranscriptReader.Agents
// runs it through an incremental cache.

namespace Notchcode.ClaudeCode;

// MARK: - Agent building

public sealed class AgentBuilder
{
    private sealed record Pending
    {
        public string ToolUseId { get; init; } = "";
        public string? AgentId { get; init; }
        public string Type { get; init; } = "";
        public string? Description { get; init; }
        public DateTime StartedAt { get; init; }
        public DateTime? EndedAt { get; init; }
    }

    private List<Pending> _agents = [];
    private Dictionary<string, int> _byToolUse = [];
    private Dictionary<string, int> _byAgentId = [];
    private string? _sessionId;

    public AgentBuilder Clone() => new()
    {
        _agents = [.. _agents],
        _byToolUse = new(_byToolUse),
        _byAgentId = new(_byAgentId),
        _sessionId = _sessionId,
    };

    public void Consume(JsonValue line)
    {
        if (_sessionId is null && (line.Str("sessionId") ?? line.Str("session_id")) is { } s) _sessionId = s;
        var date = IsoDate.Parse(line["timestamp"]);

        if (line.IsTrue("isSidechain"))
        {
            if (line.Str("agentId") is { Length: > 0 } agentId && !_byAgentId.ContainsKey(agentId))
            {
                int i = _agents.FindIndex(a => a.AgentId is null && a.EndedAt is null);
                if (i >= 0)
                {
                    _agents[i] = _agents[i] with { AgentId = agentId };
                    _byAgentId[agentId] = i;
                }
            }
            return;
        }

        switch (line.Str("type"))
        {
            case "assistant":
                ConsumeAssistant(line, date);
                break;
            case "user":
                ConsumeUser(line, date);
                break;
            case "queue-operation":
                if (line.Str("content") is { } text) ConsumeNotification(text, date);
                break;
            case "attachment":
                if (line.Obj("attachment") is { } a && a.Str("prompt") is { } prompt) ConsumeNotification(prompt, date);
                break;
        }
    }

    public List<Agent> Finish()
        => _agents.Select(p => new Agent
        {
            Id = p.AgentId ?? p.ToolUseId,
            SessionId = _sessionId ?? "unknown",
            Type = p.Type,
            Description = p.Description,
            StartedAt = p.StartedAt,
            EndedAt = p.EndedAt,
        }).ToList();

    private void ConsumeAssistant(JsonValue line, DateTime? date)
    {
        if (line.Obj("message") is not { } message || message["content"].Objects() is not { } blocks) return;
        foreach (var block in blocks)
        {
            if (block.Str("type") != "tool_use") continue;
            if (block.Str("name") is not ("Agent" or "Task") || block.Str("id") is not { } id || _byToolUse.ContainsKey(id)) continue;
            var input = block.Obj("input");
            var type = input.Str("subagent_type") is { Length: > 0 } t ? t : "agent";
            var description = input.Str("description") is { Length: > 0 } d ? d : null;
            _byToolUse[id] = _agents.Count;
            _agents.Add(new Pending
            {
                ToolUseId = id,
                Type = type,
                Description = description,
                StartedAt = date ?? DateTime.UnixEpoch,
            });
        }
    }

    private void ConsumeUser(JsonValue line, DateTime? date)
    {
        // A background agent handing its report back.
        if (line.Obj("origin") is { } origin && origin.IsTrue("handback")
            && origin.Str("from") is { } from && _byAgentId.TryGetValue(from, out var hi))
        {
            End(hi, date);
        }
        if (line.Obj("message") is not { } message) return;
        if (message.Str("content") is { } text)
        {
            ConsumeNotification(text, date);
            return;
        }
        if (message["content"].Objects() is not { } blocks) return;
        foreach (var block in blocks)
        {
            switch (block.Str("type"))
            {
                case "tool_result":
                {
                    if (block.Str("tool_use_id") is not { } toolId || !_byToolUse.TryGetValue(toolId, out var i)) continue;
                    var result = line.Obj("toolUseResult");
                    if (result.Str("agentId") is { Length: > 0 } agentId)
                    {
                        if (_agents[i].AgentId is { } old && _byAgentId.TryGetValue(old, out var oi) && oi == i)
                            _byAgentId.Remove(old);
                        _agents[i] = _agents[i] with { AgentId = agentId };
                        _byAgentId[agentId] = i;
                    }
                    // Anything but a background launch (completed, an error, a denial) ends it.
                    if (result.Str("status") != "async_launched") End(i, date);
                    break;
                }
                case "text":
                    if (block.Str("text") is { } t) ConsumeNotification(t, date);
                    break;
            }
        }
    }

    /// `<task-notification>` … `<tool-use-id>X</tool-use-id>` … `<status>completed</status>`.
    private void ConsumeNotification(string text, DateTime? date)
    {
        const string open = "<task-notification>";
        const string close = "</task-notification>";
        if (!text.Contains(open, StringComparison.Ordinal)) return;
        int pos = 0;
        while (true)
        {
            int o = text.IndexOf(open, pos, StringComparison.Ordinal);
            if (o < 0) break;
            int bodyStart = o + open.Length;
            int c = text.IndexOf(close, bodyStart, StringComparison.Ordinal);
            var body = text[bodyStart..(c < 0 ? text.Length : c)];
            pos = c < 0 ? text.Length : c + close.Length;

            if (Tag(body, "status") is not { } status || status == "running") continue;
            int? index = null;
            if (Tag(body, "tool-use-id") is { } toolId && _byToolUse.TryGetValue(toolId, out var ti)) index = ti;
            if (index is null && Tag(body, "task-id") is { } taskId && _byAgentId.TryGetValue(taskId, out var ai)) index = ai;
            if (index is { } i) End(i, date);
        }
    }

    private void End(int i, DateTime? date)
    {
        if (_agents[i].EndedAt is not null) return;
        _agents[i] = _agents[i] with { EndedAt = date ?? _agents[i].StartedAt };
    }

    private static string? Tag(string text, string name) => JsonLines.TagBody(text, name);
}
