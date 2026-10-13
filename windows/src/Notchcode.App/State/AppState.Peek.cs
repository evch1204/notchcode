// AppState.Peek.cs
// Port of Sources/notchcode/State/AppState+Peek.swift.
// Peeks: the short notices for a finished turn, an edit or a finished subagent.

using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: - Peek

    /// "Done · ponyfish" with the turn's file count and line totals. Falls back to the newest
    /// transcript turn when no PostToolUse was seen (the app started mid-turn).
    public Peek DonePeek(string sid)
    {
        var name = Session(sid)?.DisplayFull ?? "";
        int fileCount = TurnFiles.TryGetValue(sid, out var files) ? files.Count : 0;
        var shell = TurnShellCounts.TryGetValue(sid, out var counts) ? counts.Values.ToList() : [];
        var lines = TurnLineCounts.TryGetValue(sid, out var l) ? l : (Added: 0, Removed: 0);
        int added = lines.Added + shell.Sum(c => c.Added);
        int removed = lines.Removed + shell.Sum(c => c.Removed);
        if (fileCount == 0 && Turns(sid).FirstOrDefault() is { } last
            && (!TurnStarts.TryGetValue(sid, out var start) || last.StartedAt >= start.AddSeconds(-Theme.Timing.TurnMatchSlack)))
        {
            fileCount = last.Files.Count;
            added = last.Files.Sum(f => f.Added);
            removed = last.Files.Sum(f => f.Removed);
        }
        var title = name.Length == 0 ? "Done" : "Done" + Theme.Glyphs.Separator + name;
        if (fileCount <= 0) return new Peek { Kind = PeekKind.Done, SessionId = sid, Title = title };
        return new Peek
        {
            Kind = PeekKind.Done,
            SessionId = sid,
            Title = title,
            Added = added,
            Removed = removed,
            Detail = Format.Files(fileCount),
        };
    }

    /// A click on a peek: a finished turn opens that session's Changes, a finished subagent its
    /// Sessions lane. A pending request still takes the card first.
    public void TapPeek(Peek tapped)
    {
        if (CurrentPending is not null || Session(tapped.SessionId) is null)
        {
            ToggleFromNotchTap();
            return;
        }
        PeekTask?.Cancel();
        Peek = null;
        FocusedSessionId = tapped.SessionId;
        switch (tapped.Kind)
        {
            case PeekKind.Done:
            case PeekKind.Edit:
                OpenCard(CardTab.Changes);
                break;
            case PeekKind.Agent:
                OpenCard(CardTab.Sessions);
                break;
        }
    }

    public void ShowPeek(Peek newPeek)
    {
        if (!Prefs.ShowPeeks) return;
        Peek = newPeek;
        PeekTask?.Cancel();
        var peekId = newPeek.Id;
        PeekTask = RunAfter(Prefs.PeekSeconds, () =>
        {
            if (Peek?.Id != peekId) return;
            Peek = null;
            Refresh();
        });
        Refresh();
    }
}
