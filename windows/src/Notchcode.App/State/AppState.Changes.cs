// AppState.Changes.cs
// Port of Sources/notchcode/Features/Changes/AppState+Changes.swift.
// The Changes tool, Direction G (Timeline): the session's turns, newest first, as blocks (a
// turn with files is an entry, a run of turns without files one quiet group, the live turn
// always first), the cursor's stops through them in reading order (chips, group rows,
// unfolded quiet rows, the live turn with no edits yet), the chip whose diff the pane shows,
// the With edits filter, and the changes shell commands made. Its value types are in
// Features/Changes/ChangesModel.cs.
//
// SwiftUI's `withAnimation(Theme.Motion.changesLayout)` around a change has no WPF twin: the
// Changes views animate their own layout when these values change.

using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Windows;
using Notchcode.ClaudeCode;
using Notchcode.Core;
using Notchcode.Features.Changes;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    /// The prompt of the session's current (or last) turn.
    public string? CurrentPrompt(string sessionId)
    {
        if (TurnTitles.TryGetValue(sessionId, out var title) && title.Length > 0) return title;
        return Turns(sessionId).FirstOrDefault()?.Prompt;
    }

    /// When the current turn started, for the working clock in the Sessions tab. Null when unknown.
    public DateTime? TurnStart(Session session)
        => TurnStarts.TryGetValue(session.Id, out var start) ? start : null;

    /// The session's turns, newest first, each with the files shell commands changed in it
    /// after its transcript files (the transcript wins on the same path).
    public List<TranscriptTurn> Turns(string? sessionId)
    {
        if (sessionId is null) return [];
        var shell = ShellFiles.TryGetValue(sessionId, out var s) ? s : ImmutableDictionary<string, ImmutableList<FileChange>>.Empty;
        var turns = TurnsBySession.TryGetValue(sessionId, out var t) ? t : ImmutableList<TranscriptTurn>.Empty;
        return turns
            .Select(turn =>
            {
                if (!shell.TryGetValue(turn.Id, out var extra) || extra.IsEmpty) return turn;
                // Transcript files win on the same path; shell files follow them.
                var known = turn.Files.Select(f => f.Path).ToHashSet();
                return turn with { Files = turn.Files.Concat(extra.Where(f => !known.Contains(f.Path))).ToList() };
            })
            .OrderByDescending(turn => turn.StartedAt)
            .ToList();
    }

    // MARK: The timeline

    /// The view id of a chip (Swift `AppState.changesChipID`).
    public static string ChangesChipId(ChangesChipKey key) => ChangesIds.Chip(key);

    /// The turn still running: the newest one while the session works (or waits on the
    /// owner, or its background agents still run), or one the transcript left open. Null when
    /// every turn is finished.
    public string? ChangesLiveTurnId(IReadOnlyList<TranscriptTurn> turns)
    {
        if (turns.Count == 0 || FocusedSession is not { } session) return null;
        var newest = turns[0];
        if (newest.EndedAt is null || RunningAgents(session.Id).Count > 0) return newest.Id;
        return session.State is SessionState.Working or SessionState.NeedsYou ? newest.Id : null;
    }

    /// The timeline's blocks for the focused session, newest first. With edits on, the
    /// quiet groups are left out; the live turn always shows.
    public List<ChangesBlock> ChangesBlocks
    {
        get
        {
            var turns = Turns(FocusedSession?.Id);
            var live = ChangesLiveTurnId(turns);
            var blocks = new List<ChangesBlock>();
            var run = new List<TranscriptTurn>();
            void Flush()
            {
                if (run.Count > 0 && !ChangesTool.EditsOnly) blocks.Add(new ChangesBlock.Quiet(run[0].Id, run.ToList()));
                run.Clear();
            }
            for (int index = 0; index < turns.Count; index++)
            {
                var turn = turns[index];
                bool isLive = turn.Id == live;
                if (isLive || turn.Files.Count > 0)
                {
                    Flush();
                    blocks.Add(new ChangesBlock.Entry(turn, turns.Count - index, isLive));
                }
                else
                {
                    run.Add(turn);
                }
            }
            Flush();
            return blocks;
        }
    }

    /// The cursor's stops in reading order: each entry's chips (the live turn itself while
    /// it has none), each quiet group's row, and an unfolded group's turns under it.
    public List<ChangesItem> ChangesCursorItems
    {
        get
        {
            var items = new List<ChangesItem>();
            foreach (var block in ChangesBlocks)
            {
                switch (block)
                {
                    case ChangesBlock.Entry entry:
                        if (entry.Turn.Files.Count == 0)
                            items.Add(new ChangesItem.Live(entry.Turn.Id));
                        else
                            items.AddRange(entry.Turn.Files.Select(f => new ChangesItem.Chip(new ChangesChipKey(entry.Turn.Id, f.Path))));
                        break;
                    case ChangesBlock.Quiet quiet:
                        items.Add(new ChangesItem.Group(quiet.GroupId));
                        if (ChangesTool.UnfoldedGroups.Contains(quiet.GroupId))
                            items.AddRange(quiet.Turns.Select(t => new ChangesItem.Quiet(t.Id)));
                        break;
                }
            }
            return items;
        }
    }

    /// The key of the stop under the keyboard cursor in the Changes tool.
    public string? CursorRowKey
    {
        get
        {
            if (SelectedTab != CardTab.Changes) return null;
            var items = ChangesCursorItems;
            return RowCursor >= 0 && RowCursor < items.Count ? items[RowCursor].Id : null;
        }
    }

    /// The chip under the cursor, if the cursor is on one.
    public ChangesChipKey? ChangesCursorChip
    {
        get
        {
            var items = ChangesCursorItems;
            if (RowCursor < 0 || RowCursor >= items.Count) return null;
            return items[RowCursor] is ChangesItem.Chip chip ? chip.Key : null;
        }
    }

    /// The diff pane shows: a chip is selected and the pane is open.
    public bool ChangesPaneShown => ChangesTool.PaneOpen && ChangesSelectedFile is not null;

    /// The selected chip's turn, file and the turn's number, when both still exist.
    public (TranscriptTurn Turn, FileChange File, int Number)? ChangesSelectedFile
    {
        get
        {
            if (ChangesTool.Selection is not { } key) return null;
            var turns = Turns(FocusedSession?.Id);
            int index = turns.FindIndex(t => t.Id == key.TurnId);
            if (index < 0) return null;
            var file = turns[index].Files.FirstOrDefault(f => f.Path == key.Path);
            if (file is null) return null;
            return (turns[index], file, turns.Count - index);
        }
    }

    /// Every view choice goes back to its default: a new session, or the app's start.
    public void ResetChangesView() => ChangesTool = new ChangesToolState();

    /// Runs `change` with the cursor kept on the same stop when it still exists; otherwise
    /// the cursor stays where it was, clamped to the new list.
    private void KeepingChangesCursor(Action change)
    {
        var before = CursorRowKey;
        change();
        var items = ChangesCursorItems;
        int index = before is null ? -1 : items.FindIndex(i => i.Id == before);
        RowCursor = index >= 0 ? index : Math.Max(0, Math.Min(items.Count - 1, RowCursor));
    }

    /// A click on a chip: the cursor lands on it and the pane shows its diff.
    public void SelectChangesChip(ChangesChipKey key)
    {
        int index = ChangesCursorItems.FindIndex(i => i is ChangesItem.Chip c && c.Key == key);
        if (index >= 0) RowCursor = index;
        ChangesTool = ChangesTool with { Selection = key, PaneOpen = true };
    }

    /// A click or ⏎ on a quiet group's row: its turns unfold under it, or fold away.
    public void ToggleChangesGroup(string id)
    {
        KeepingChangesCursor(() =>
        {
            var groups = ChangesTool.UnfoldedGroups;
            ChangesTool = ChangesTool with { UnfoldedGroups = groups.Contains(id) ? groups.Remove(id) : groups.Add(id) };
        });
        int index = ChangesCursorItems.FindIndex(i => i is ChangesItem.Group g && g.GroupId == id);
        if (index >= 0) RowCursor = index;
    }

    /// `/`: With edits on or off. The cursor stays on its chip; from a quiet row it moves on.
    public void ToggleChangesEditsOnly()
        => KeepingChangesCursor(() => ChangesTool = ChangesTool with { EditsOnly = !ChangesTool.EditsOnly });

    /// Ctrl B while the pane shows: the timeline column goes, the pane takes the width; again brings it back.
    public void ToggleChangesColumn()
    {
        if (!ChangesPaneShown) return;
        ChangesTool = ChangesTool with { ColumnHidden = !ChangesTool.ColumnHidden };
    }

    /// Esc in the Changes tool: a hidden column comes back, then the pane closes (the chip
    /// stays the cursor). False when there is nothing to back out of, so esc closes the card.
    public bool ChangesEscape()
    {
        if (!ChangesPaneShown) return false;
        ChangesTool = ChangesTool.ColumnHidden
            ? ChangesTool with { ColumnHidden = false }
            : ChangesTool with { PaneOpen = false };
        return true;
    }

    /// The Changes tool's own keys; null for the keys every tool shares (numbers, ⇥).
    public bool? HandleChangesKey(NotchKey key)
    {
        switch (key.Kind)
        {
            case NotchKeyKind.Up:
            case NotchKeyKind.Down:
            {
                var items = ChangesCursorItems;
                if (items.Count == 0) return false;
                int next = Math.Max(0, Math.Min(items.Count - 1, RowCursor + (key.Kind == NotchKeyKind.Up ? -1 : 1)));
                RowCursor = next;
                // The pane follows the cursor from chip to chip.
                if (ChangesTool.PaneOpen && items[next] is ChangesItem.Chip chip)
                    ChangesTool = ChangesTool with { Selection = chip.Key };
                return true;
            }
            case NotchKeyKind.Primary:
            {
                var items = ChangesCursorItems;
                if (RowCursor < 0 || RowCursor >= items.Count) return false;
                switch (items[RowCursor])
                {
                    case ChangesItem.Chip chip:
                        if (ChangesPaneShown && ChangesTool.Selection == chip.Key)
                            // The diff is already up: ⏎ again goes to the terminal, as Alt ⏎ does.
                            Teleport(FocusedSession);
                        else
                            SelectChangesChip(chip.Key);
                        break;
                    case ChangesItem.Group group:
                        ToggleChangesGroup(group.GroupId);
                        break;
                }
                return true;
            }
            case NotchKeyKind.Copy:
                return CopyCursorLocation();
            case NotchKeyKind.Filter:
                ToggleChangesEditsOnly();
                return true;
            case NotchKeyKind.ToggleTree:
                ToggleChangesColumn();
                return true;
            default:
                return null;
        }
    }

    /// "y" in Changes: copies `path:line` of the first changed line of the chip under the cursor.
    public bool CopyCursorLocation()
    {
        if (ChangesCursorChip is not { } key) return false;
        var file = Turns(FocusedSession?.Id).FirstOrDefault(t => t.Id == key.TurnId)?.Files.FirstOrDefault(f => f.Path == key.Path);
        if (file is null) return false;
        CopyLocation(file.Path, FirstChangedLine(file));
        return true;
    }

    /// The lines a diff shows: the whole patch, or the snippet when no patch was recorded.
    public static IReadOnlyList<DiffLine> DiffLines(FileChange file) => file.Patch.Count == 0 ? file.Snippet : file.Patch;

    /// Puts `C:\abs\path:line` on the clipboard and says so in the footer.
    public void CopyLocation(string relative, int line)
    {
        var path = relative;
        if (!Paths.IsAbsolute(path) && FocusedSession?.Cwd is { Length: > 0 } cwd)
            path = System.IO.Path.Combine(cwd, path);
        try
        {
            Clipboard.SetText(path + ":" + line);
        }
        catch (Exception e) when (e is COMException or ExternalException or InvalidOperationException)
        {
            // The clipboard is held by another app for a moment; the hint still says what was meant.
        }
        Flash("Copied " + Format.FileName(relative) + ":" + line);
    }

    /// The new-file line number of the first added line, else the old one of the first removed line.
    public static int FirstChangedLine(FileChange file)
    {
        foreach (var line in DiffLines(file))
        {
            if (line.Kind == DiffLineKind.Added && line.NewLine is int n) return n;
            if (line.Kind == DiffLineKind.Removed && (line.OldLine ?? line.NewLine) is int m) return m;
        }
        return 1;
    }

    // MARK: Shell changes

    /// Where shell changes wait while their turn is not in the transcript yet.
    public const string PendingTurnKey = "~pending";

    /// A Bash call's working-tree report: every file that differs from the baseline is
    /// attributed to the session's current turn as a "shell" change, then the report becomes
    /// the new baseline. Silent: no peek. With no baseline yet (the app started mid-turn),
    /// the report only becomes the baseline.
    /// `agentId`: the subagent whose Bash call it was (the hook's `agent_id`), marked on the files.
    public void HandleShellTree(TreeReport? report, string sid, string cwd, string? agentId = null)
    {
        if (report is null) return;
        var now = UnifiedDiff.Snapshot(report);
        try
        {
            if (!TreeSnapshots.TryGetValue(sid, out var baseline) || baseline.Root != now.Root) return;
            var changed = UnifiedDiff.Changes(baseline, now, cwd);
            if (changed.Count == 0) return;
            if (!string.IsNullOrEmpty(agentId))
                changed = changed.Select(f => f with { AgentId = agentId }).ToList();

            var files = TurnFiles.TryGetValue(sid, out var f0) ? f0 : [];
            var counts = TurnShellCounts.TryGetValue(sid, out var c0) ? c0 : [];
            foreach (var file in changed)
            {
                var absolute = Paths.Absolute(file.Path, cwd);
                if (!files.Contains(absolute))
                {
                    files.Add(absolute);
                    counts[absolute] = (file.Added, file.Removed);
                }
                else if (counts.ContainsKey(absolute))
                {
                    counts[absolute] = (file.Added, file.Removed);
                }
            }
            TurnFiles[sid] = files;
            TurnShellCounts[sid] = counts;

            var turns = TurnsBySession.TryGetValue(sid, out var t) ? (IReadOnlyList<TranscriptTurn>)t : [];
            AttachShellFiles(changed, sid, ShellTurnId(sid, turns) ?? PendingTurnKey);
        }
        finally
        {
            TreeSnapshots[sid] = now;
        }
    }

    /// The turn shell changes belong to: the newest turn, if it started with the current turn
    /// (the transcript can lag the UserPromptSubmit hook). Null while it has not arrived.
    public string? ShellTurnId(string sid, IReadOnlyList<TranscriptTurn> turns)
    {
        TranscriptTurn? newest = null;
        foreach (var turn in turns)
            if (newest is null || newest.StartedAt < turn.StartedAt) newest = turn;
        if (newest is null) return null;
        if (TurnStarts.TryGetValue(sid, out var start) && newest.StartedAt < start.AddSeconds(-Theme.Timing.TurnMatchSlack))
            return null;
        return newest.Id;
    }

    /// Adds `changed` to a turn's shell files: a path seen before is replaced in place, a new one appended.
    public void AttachShellFiles(IReadOnlyList<FileChange> changed, string sid, string turnId)
    {
        LoadShellFiles(sid);
        var perTurn = ShellFiles.TryGetValue(sid, out var p) ? p : ImmutableDictionary<string, ImmutableList<FileChange>>.Empty;
        var list = perTurn.TryGetValue(turnId, out var l) ? l : ImmutableList<FileChange>.Empty;
        foreach (var file in changed)
        {
            int index = list.FindIndex(f => f.Path == file.Path);
            list = index >= 0 ? list.SetItem(index, file) : list.Add(file);
        }
        perTurn = perTurn.SetItem(turnId, list);
        ShellFiles = ShellFiles.SetItem(sid, perTurn);
        ShellChangesStore.Save(perTurn.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<FileChange>)kv.Value), sid);
    }

    /// Brings back the session's shell changes saved before a relaunch, once per session;
    /// what is already in memory wins on the same turn.
    public void LoadShellFiles(string sid)
    {
        if (!ReadsLocalFiles || ShellFilesLoaded.Contains(sid)) return;
        ShellFilesLoaded.Add(sid);
        var saved = ShellChangesStore.Load(sid);
        if (saved.Count == 0) return;
        var merged = saved.ToImmutableDictionary(kv => kv.Key, kv => kv.Value.ToImmutableList());
        if (ShellFiles.TryGetValue(sid, out var current))
            foreach (var (turnId, list) in current) merged = merged.SetItem(turnId, list);
        ShellFiles = ShellFiles.SetItem(sid, merged);
    }

    /// The open question's options, from the transcript's last `AskUserQuestion` call (the
    /// one asking the same thing when the texts match, else the latest). The transcript may
    /// lag the Notification; `ApplyTurns` tries again.
    public void FillQuestionOptions(string sid)
    {
        if (Question is not { } current || current.SessionId != sid || current.Options.Count > 0) return;
        if (Session(sid)?.TranscriptPath is not { } path) return;
        if (TranscriptReader.LastQuestion(path) is not { } asked || asked.Options.Count == 0) return;
        if (asked.Question == current.Question || current.Question.Contains(asked.Question, StringComparison.Ordinal))
            current = current with { Question = asked.Question };
        Question = current with { Options = asked.Options };
    }

    /// Re-reads the session's transcript off the UI thread, then applies its turns.
    public void ReloadTurns(string sid)
    {
        if (!ReadsLocalFiles || Session(sid)?.TranscriptPath is not { } path) return;
        _ = ReloadTurnsAsync(sid, path);
    }

    private async Task ReloadTurnsAsync(string sid, string path)
    {
        List<TranscriptTurn> turns;
        try
        {
            turns = await Task.Run(() => TranscriptReader.Turns(path));
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            turns = [];
        }
        ApplyTurns(turns, sid);
    }

    private void ApplyTurns(List<TranscriptTurn> turns, string sid)
    {
        if (Session(sid) is null) return;
        LoadShellFiles(sid);
        // Shell changes seen before their turn reached the transcript: attach them now.
        if (ShellFiles.TryGetValue(sid, out var perTurn) && perTurn.TryGetValue(PendingTurnKey, out var held)
            && ShellTurnId(sid, turns) is { } turnId)
        {
            ShellFiles = ShellFiles.SetItem(sid, perTurn.Remove(PendingTurnKey));
            AttachShellFiles(held, sid, turnId);
        }
        if (Question?.SessionId == sid && Question.Options.Count == 0) FillQuestionOptions(sid);
        var next = turns.ToImmutableList();
        if (!TurnsBySession.TryGetValue(sid, out var old) || !old.SequenceEqual(next))
        {
            TurnsBySession = TurnsBySession.SetItem(sid, next);
            // New edits: the open preview's text and tints may have moved.
            if (IsCardOpen && SelectedTab == CardTab.Files && sid == FocusedSession?.Id) ReloadOpenedPreview();
        }
        // Sessions hooks never announced: the elapsed clock runs from the open turn.
        if (!IsHookDriven(sid))
        {
            TranscriptTurn? open = null;
            foreach (var turn in turns)
                if (open is null || open.StartedAt < turn.StartedAt) open = turn;
            if (open is { EndedAt: null }) TurnStarts = TurnStarts.SetItem(sid, open.StartedAt);
        }
        RecomputeUsage();
    }
}
