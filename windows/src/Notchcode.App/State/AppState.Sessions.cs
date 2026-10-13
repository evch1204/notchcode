// AppState.Sessions.cs
// Port of Sources/notchcode/State/AppState+Sessions.swift.
// Sessions from hooks and transcripts, the needs-you state, and subagents.
// (TreeSnapshot lives with the diff parsers in Core/Diff, wave 1a.)

using System.Collections.Immutable;
using System.IO;
using Notchcode.ClaudeCode;
using Notchcode.Features.Files;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: - Sessions

    public void TouchSession(HookEnvelope envelope)
    {
        var sid = envelope.ResolvedSessionId;
        var now = DateTime.UtcNow;
        var index = Sessions.FindIndex(s => s.Id == sid);
        if (index >= 0)
        {
            var s = Sessions[index] with { LastEventAt = now };
            bool transcriptChanged = false;
            if (envelope.ResolvedTranscriptPath is { } path && path != s.TranscriptPath)
            {
                s = s with { TranscriptPath = path };
                transcriptChanged = true;
            }
            if (envelope.TermProgram is { } term) s = s with { TermProgram = term };
            if (envelope.TermBundleId is { } bundle) s = s with { TermBundleId = bundle };
            if (envelope.Payload["permission_mode"]?.StringValue is { Length: > 0 } mode) s = s with { PermissionMode = mode };
            Sessions = Sessions.SetItem(index, s);
            if (envelope.Pid is int pid) SessionPids[sid] = pid;
            if (transcriptChanged) ReloadAgents(sid);
            return;
        }

        var cwd = envelope.ResolvedCwd;
        var name = cwd.Length == 0 ? sid : Format.FileName(cwd);
        var transcript = envelope.ResolvedTranscriptPath;
        string? branch = null;
        string? repo = null;
        if (ReadsLocalFiles && cwd.Length > 0)
        {
            branch = GitDir.GitBranch(cwd);
            repo = GitDir.RepoName(cwd);
            transcript ??= TranscriptReader.LatestTranscriptPath(cwd);
        }
        var session = new Session
        {
            Id = sid,
            Cwd = cwd,
            WorktreeName = name,
            RepoName = repo,
            Branch = branch,
            State = SessionState.Idle,
            Verb = null,
            StartedAt = now,
            LastEventAt = now,
            TranscriptPath = transcript,
            TermProgram = envelope.TermProgram,
            TermBundleId = envelope.TermBundleId,
            PermissionMode = envelope.Payload["permission_mode"]?.StringValue,
        };
        Sessions = Sessions.Add(session);
        if (envelope.Pid is int newPid) SessionPids[sid] = newPid;
        if (transcript is not null) ReloadAgents(sid);
    }

    /// Per session, the Claude Code process id the hooks last reported (`pid`): where teleport
    /// starts its walk up the process tree. Windows only; macOS teleports by bundle id.
    internal Dictionary<string, int> SessionPids = [];

    /// SessionEnd: the session stays listed (idle) until it ages out, with its agents closed.
    /// It no longer counts as hook-driven, so the transcript watcher may revive it on new activity.
    public void EndSession(string sid)
    {
        foreach (var req in Pending.Where(p => p.SessionId == sid).ToList())
            Resolve(req.Id, new HookReply { Id = req.Id, Decision = Decision.None });
        HookSeenAt.Remove(sid);
        EndedAt[sid] = DateTime.UtcNow;
        ClearSessionState(sid);
        UpdateSession(sid, s => s with { State = SessionState.Idle, Verb = null });
        if (Agents.TryGetValue(sid, out var list) && list.Any(a => a.IsRunning))
            Agents = Agents.SetItem(sid, TranscriptReader.CloseAgents(list, DateTime.UtcNow).ToImmutableList());
        if (!ReadsLocalFiles) ForgetSession(sid);
    }

    /// Forgets the turn in progress: its start, tallies and tree baseline, the needs-you,
    /// the stop held for agents, and the session's question.
    private void ClearSessionState(string sid)
    {
        TurnStarts = TurnStarts.Remove(sid);
        TurnFiles.Remove(sid);
        TurnLineCounts.Remove(sid);
        TurnShellCounts.Remove(sid);
        TreeSnapshots.Remove(sid);
        ClearNeedsYou(sid);
        OpenTurns.Remove(sid);
        StoppedWithAgents.Remove(sid);
        if (Question?.SessionId == sid) Question = null;
    }

    /// Drops a session and everything kept for it.
    private void ForgetSession(string sid)
    {
        var gone = Session(sid);
        Sessions = Sessions.RemoveAll(s => s.Id == sid);
        // The reader's and the file tree's caches live for the app's life otherwise.
        if (gone?.TranscriptPath is { } path) TranscriptReader.Forget(path);
        if (gone?.Cwd is { Length: > 0 } cwd)
        {
            if (!Sessions.Any(s => RepoFiles.SameRoot(s.Cwd, cwd))) RepoFiles.Forget(cwd);
            if (cwd != GitCwd && !Sessions.Any(s => s.Cwd == cwd))
                UpdateGit(g => g with { Snapshots = g.Snapshots.Remove(cwd) });
        }
        TurnsBySession = TurnsBySession.Remove(sid);
        TurnTitles = TurnTitles.Remove(sid);
        ShellFiles = ShellFiles.Remove(sid);
        ShellFilesLoaded.Remove(sid);
        Statusline = Statusline.Remove(sid);
        SessionPids.Remove(sid);
        ClearSessionState(sid);
        if (Agents.TryGetValue(sid, out var ended))
        {
            Agents = Agents.Remove(sid);
            var ids = ended.Select(a => a.Id).ToHashSet();
            foreach (var key in AgentKeys.Where(kv => ids.Contains(kv.Value)).Select(kv => kv.Key).ToList())
                AgentKeys.Remove(key);
            UnmatchedHookAgents.ExceptWith(ids);
        }
        if (FocusedSessionId == sid) FocusedSessionId = null;
        SessionCursor = Math.Min(SessionCursor, Math.Max(0, Sessions.Count - 1));
    }

    public void UpdateSession(string id, Func<Session, Session> change)
    {
        var index = Sessions.FindIndex(s => s.Id == id);
        if (index < 0) return;
        var s = change(Sessions[index]);
        if (s != Sessions[index]) Sessions = Sessions.SetItem(index, s);
    }

    // MARK: - Needs you

    /// Claude says it waits on the owner, with no request of ours to answer. Lasts at most
    /// `NeedsYouLifetime`, and less if the session does anything in the meantime.
    public void MarkNeedsYou(string sid)
    {
        var now = DateTime.UtcNow;
        NeedsYouSince[sid] = now;
        UpdateSession(sid, s => s with { State = SessionState.NeedsYou });
        if (NeedsYouTasks.TryGetValue(sid, out var old)) old.Cancel();
        NeedsYouTasks[sid] = RunAfter(Theme.Timing.NeedsYouLifetime, () =>
        {
            if (!NeedsYouSince.TryGetValue(sid, out var since) || since != now) return;
            Settle(sid);
            Refresh();
        });
    }

    public void ClearNeedsYou(string sid)
    {
        NeedsYouSince.Remove(sid);
        if (NeedsYouTasks.Remove(sid, out var task)) task.Cancel();
    }

    private bool NeedsYouIsFresh(string sid, DateTime? now = null)
    {
        if (!NeedsYouSince.TryGetValue(sid, out var since)) return false;
        return ((now ?? DateTime.UtcNow) - since).TotalSeconds < Theme.Timing.NeedsYouLifetime;
    }

    /// Makes `NeedsYou` true or gone. A pending request always means needs you; otherwise it
    /// stays only while a fresh notification backs it, then falls back to working (turn still
    /// open) or done.
    public void Settle(string sid)
    {
        if (Session(sid) is not { } s) return;
        if (Pending.Any(p => p.SessionId == sid))
        {
            if (s.State != SessionState.NeedsYou) UpdateSession(sid, x => x with { State = SessionState.NeedsYou });
            return;
        }
        if (s.State != SessionState.NeedsYou || NeedsYouIsFresh(sid)) return;
        ClearNeedsYou(sid);
        if (Question?.SessionId == sid) Question = null;
        bool working = OpenTurns.Contains(sid);
        UpdateSession(sid, x => working
            ? x with { State = SessionState.Working, Verb = x.Verb ?? "Working" }
            : x with { State = SessionState.Done, Verb = null });
    }

    // MARK: - ITranscriptWatcherSink

    /// A hook envelope arrived for the session recently, so hooks win on its state.
    public bool IsHookDriven(string sid, DateTime? now = null)
    {
        if (!HookSeenAt.TryGetValue(sid, out var seen)) return false;
        return ((now ?? DateTime.UtcNow) - seen).TotalSeconds < Theme.Timing.HookDrivenWindow;
    }

    /// Merges sessions found on disk by id. Hooks win on state for sessions they drive.
    public void TranscriptsChanged(IReadOnlyList<DiscoveredSession> discoveredAll)
    {
        if (!ReadsLocalFiles) return;
        var now = DateTime.UtcNow;
        var changed = new List<string>();

        // Claude Code's own helper runs fire hooks like any session, so one may already be listed.
        var headless = discoveredAll.Where(d => d.IsHeadless).Select(d => d.Id).ToHashSet();
        HeadlessIds.UnionWith(headless);
        if (headless.Count > 0 && Sessions.Any(s => headless.Contains(s.Id)))
            Sessions = Sessions.RemoveAll(s => headless.Contains(s.Id));
        var discovered = discoveredAll.Where(d => !d.IsHeadless).ToList();

        // The newest transcript per folder tells the owner which of two same-folder sessions is theirs.
        // Keyed the Windows way: "c:\x" and "C:/x" are one folder.
        var newest = new Dictionary<string, DiscoveredSession>(Paths.CwdComparer);
        foreach (var found in discovered)
        {
            if (found.Cwd.Length == 0) continue;
            if (newest.TryGetValue(found.Cwd, out var best) && best.LastActivityAt >= found.LastActivityAt) continue;
            newest[found.Cwd] = found;
        }
        var newestIds = newest.ToImmutableDictionary(kv => kv.Key, kv => kv.Value.Id, Paths.CwdComparer);
        if (!DictionaryEquals(newestIds, NewestSessionByCwd)) NewestSessionByCwd = newestIds;

        foreach (var found in discovered)
        {
            // The transcript moved on after Claude said it needed the owner: it no longer does.
            if (NeedsYouSince.TryGetValue(found.Id, out var since)
                && found.LastActivityAt > since.AddSeconds(Theme.Timing.NeedsYouActivityGrace))
            {
                ClearNeedsYou(found.Id);
                Settle(found.Id);
            }
            var index = Sessions.FindIndex(s => s.Id == found.Id);
            if (index >= 0)
            {
                var s = Sessions[index];
                if (s.TranscriptPath is null) s = s with { TranscriptPath = found.TranscriptPath };
                if (found.PermissionMode is { } mode) s = s with { PermissionMode = mode };   // the transcript wins over hooks
                if (!IsHookDriven(found.Id, now))
                {
                    bool endedBefore = EndedAt.TryGetValue(found.Id, out var ended) && found.LastActivityAt <= ended;
                    if (!endedBefore)
                    {
                        EndedAt.Remove(found.Id);
                        s = s with { State = found.State, Verb = found.Verb };
                        if (found.LastPrompt is { Length: > 0 } prompt) TurnTitles = TurnTitles.SetItem(found.Id, prompt);
                    }
                    if (found.LastActivityAt > s.LastEventAt) s = s with { LastEventAt = found.LastActivityAt };
                }
                if (s != Sessions[index]) Sessions = Sessions.SetItem(index, s);
            }
            else
            {
                if ((now - found.LastActivityAt).TotalSeconds >= Theme.Timing.SessionIdleCutoff) continue;
                if (EndedAt.TryGetValue(found.Id, out var ended) && found.LastActivityAt <= ended) continue;
                var cwd = found.Cwd;
                Sessions = Sessions.Add(new Session
                {
                    Id = found.Id,
                    Cwd = cwd,
                    WorktreeName = cwd.Length == 0 ? found.Id : Format.FileName(cwd),
                    RepoName = cwd.Length == 0 ? null : GitDir.RepoName(cwd),
                    Branch = cwd.Length == 0 ? null : GitDir.GitBranch(cwd),
                    State = found.State,
                    Verb = found.Verb,
                    StartedAt = found.StartedAt,
                    LastEventAt = found.LastActivityAt,
                    TranscriptPath = found.TranscriptPath,
                    TermProgram = null,
                    TermBundleId = null,
                    PermissionMode = found.PermissionMode,
                });
                if (found.LastPrompt is { Length: > 0 } prompt) TurnTitles = TurnTitles.SetItem(found.Id, prompt);
            }
            if (!LastSeenActivity.TryGetValue(found.Id, out var seen) || seen != found.LastActivityAt)
            {
                LastSeenActivity[found.Id] = found.LastActivityAt;
                changed.Add(found.Id);
            }
        }

        // Sessions idle past the cutoff leave the list, unless hooks still drive them or they wait on the owner.
        var pendingIds = Pending.Select(p => p.SessionId).ToHashSet();
        var stale = Sessions.Where(s => !IsHookDriven(s.Id, now) && !pendingIds.Contains(s.Id)
                                        && (now - s.LastEventAt).TotalSeconds > Theme.Timing.SessionIdleCutoff).ToList();
        foreach (var s in stale)
        {
            ForgetSession(s.Id);
            LastSeenActivity.Remove(s.Id);
            EndedAt.Remove(s.Id);
        }

        foreach (var sid in changed)
        {
            if (Session(sid) is null) continue;
            ReloadTurns(sid);
            ReloadAgents(sid);
        }
        // A background subagent can keep editing while the main transcript stays quiet:
        // re-read turns for every session with a running agent (cheap when nothing changed).
        var changedSet = changed.ToHashSet();
        foreach (var s in Sessions.ToList())
        {
            if (!changedSet.Contains(s.Id) && RunningAgents(s.Id).Count > 0) ReloadTurns(s.Id);
        }
        if (FocusedSessionId is null && IsCardOpen) FocusedSessionId = PrimarySession?.Id;
        Refresh();
    }

    private static bool DictionaryEquals(IReadOnlyDictionary<string, string> a, IReadOnlyDictionary<string, string> b)
        => a.Count == b.Count && a.All(kv => b.TryGetValue(kv.Key, out var v) && v == kv.Value);

    // MARK: - Subagents

    public void ReloadAgents(string sid)
    {
        if (!ReadsLocalFiles || Session(sid)?.TranscriptPath is not { } path) return;
        _ = Task.Run(() =>
        {
            IReadOnlyList<Agent> found;
            try { found = TranscriptReader.Agents(path); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { found = []; }
            RunOnMain(() => MergeTranscriptAgents(found, sid));
        });
    }

    public void AgentStarted(string id, string type, string? description, string sid, DateTime date)
    {
        if (AgentKeys.ContainsKey(id)) return;
        var list = AgentsFor(sid);
        if (list.Any(a => a.Id == id)) { AgentKeys[id] = id; return; }

        // The transcript may have seen this agent first under its tool_use id.
        var index = list.FindIndex(candidate =>
            candidate.IsRunning && candidate.Type == type && !UnmatchedHookAgents.Contains(candidate.Id)
            && !AgentKeys.Any(key => key.Value == candidate.Id && key.Key != candidate.Id)
            && Math.Abs((candidate.StartedAt - date).TotalSeconds) < Theme.Timing.AgentMatchWindow);
        if (index >= 0)
        {
            AgentKeys[id] = list[index].Id;
            if (list[index].Description is null) list = list.SetItem(index, list[index] with { Description = description });
            Agents = Agents.SetItem(sid, list);
            return;
        }

        list = list.Add(new Agent { Id = id, SessionId = sid, Type = type, Description = description, StartedAt = date, EndedAt = null });
        AgentKeys[id] = id;
        UnmatchedHookAgents.Add(id);
        Agents = Agents.SetItem(sid, list);
    }

    /// Ends the matching running agent and returns it, or null when none matched.
    public Agent? AgentStopped(string id, string? type, string sid, DateTime date)
    {
        if (!Agents.TryGetValue(sid, out var list)) return null;
        var stored = AgentKeys.TryGetValue(id, out var k) ? k : id;
        var index = list.FindIndex(a => a.Id == stored && a.IsRunning);
        if (index < 0 && type is not null)
        {
            // Unknown id: end the oldest running agent of that type.
            index = list.FindIndex(a => a.IsRunning && a.Type == type);
        }
        if (index < 0) return null;
        var ended = list[index] with { EndedAt = date };
        Agents = Agents.SetItem(sid, list.SetItem(index, ended));
        return ended;
    }

    internal void MergeTranscriptAgents(IReadOnlyList<Agent> found, string sid)
    {
        if (Session(sid) is null) return;
        var original = AgentsFor(sid);
        var list = original.ToList();
        foreach (var incoming in found)
        {
            if (AgentKeys.TryGetValue(incoming.Id, out var stored) && list.FindIndex(a => a.Id == stored) is var si and >= 0)
            {
                list[si] = Apply(incoming, list[si]);
                continue;
            }
            if (list.FindIndex(a => a.Id == incoming.Id) is var ii and >= 0)
            {
                AgentKeys[incoming.Id] = incoming.Id;
                list[ii] = Apply(incoming, list[ii]);
                continue;
            }
            // Same agent seen by the hook under its agent_id.
            var hi = list.FindIndex(a => UnmatchedHookAgents.Contains(a.Id) && a.Type == incoming.Type
                                         && Math.Abs((a.StartedAt - incoming.StartedAt).TotalSeconds) < Theme.Timing.AgentMatchWindow);
            if (hi >= 0)
            {
                UnmatchedHookAgents.Remove(list[hi].Id);
                AgentKeys[incoming.Id] = list[hi].Id;
                list[hi] = Apply(incoming, list[hi]);
                continue;
            }
            list.Add(incoming with { SessionId = sid });
            AgentKeys[incoming.Id] = incoming.Id;
        }
        var sorted = list.OrderBy(a => a.StartedAt).ToImmutableList();
        if (!sorted.SequenceEqual(original)) Agents = Agents.SetItem(sid, sorted);
        Refresh();
    }

    /// Fills what the transcript knows. A stop seen by the hook is never undone by an older transcript.
    private static Agent Apply(Agent incoming, Agent agent)
    {
        if (agent.Description is null) agent = agent with { Description = incoming.Description };
        if (agent.IsRunning && incoming.EndedAt is { } ended) agent = agent with { EndedAt = ended };
        return agent;
    }
}
