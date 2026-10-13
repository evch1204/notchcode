// AppState.RequestDiff.cs
// Port of the request-card diff part of Sources/notchcode/State/AppState+Requests.swift
// (wave 1d; the queue and the answers stay in AppState.Requests.cs, wave 1e): which file's
// diff is open inside the current permission or commit card, opening and closing it, and the
// ↑↓ scroll commands its box (or a plan card's Markdown) follows. The published values
// (`RequestDiff`, `RequestDiffScroll`, `RequestRowCursor`) live in AppState.cs.

using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.State;

/// The one file whose diff is open inside a permission or commit card.
public sealed record RequestDiffTarget(string RequestId, string Path);

/// A request card's box moves by `Delta` lines (a diff) or blocks (a plan) each time `Seq`
/// changes (↑↓ while it is open).
public sealed record RequestDiffScroll
{
    public int Seq { get; init; }
    public int Delta { get; init; }
}

public sealed partial class AppState
{
    // MARK: - Request card diff

    /// The path whose diff is open in `request`'s card, if it is still one of its files.
    public string? RequestDiffPath(PendingRequest request)
    {
        if (RequestDiff is not { } target || target.RequestId != request.Id
            || !request.Files.Any(f => f.Path == target.Path)) return null;
        return target.Path;
    }

    /// Opens `path`'s diff in the current request card, or closes it when it is the open one.
    /// The card grows (or shrinks) with the shape's height spring (`Theme.Motion.RequestDiff`,
    /// run by the shape animator off `CardHeight`).
    public void ToggleRequestDiff(string path)
    {
        if (CurrentPending is not { } req) return;
        var file = req.Files.FirstOrDefault(f => f.Path == path);
        if (file is null || file.DiffLines().Count == 0) return;
        int index = req.Files.ToList().FindIndex(f => f.Path == path);
        if (index >= 0) RequestRowCursor = index;
        bool opening = RequestDiffPath(req) != path;
        RequestDiff = opening ? new RequestDiffTarget(req.Id, path) : null;
    }

    public void CloseRequestDiff()
    {
        if (RequestDiff is null) return;
        RequestDiff = null;
    }

    /// "D": the permission card's file, or the commit card's file under the cursor.
    public bool ToggleRequestDiffAtCursor(PendingRequest req)
    {
        var files = req.Files;
        if (files.Count == 0) return false;
        if (RequestDiffPath(req) is { } open)
        {
            ToggleRequestDiff(open);
            return true;
        }
        int index = req.Kind == PendingRequestKind.Commit ? Math.Max(0, Math.Min(files.Count - 1, RequestRowCursor)) : 0;
        if (files[index].DiffLines().Count == 0) return false;
        if (!IsCardOpen) OpenCard();
        ToggleRequestDiff(files[index].Path);
        return true;
    }

    /// ↑↓ over a request card whose box scrolls (a plan, or an open diff): one step of
    /// `planScrollBlocks` blocks or `requestDiffScrollLines` lines. The one place a scroll
    /// command is made (AppState+Card.swift's ↑↓ calls it).
    public void ScrollRequestCard(PendingRequest req, int step)
    {
        int unit = req.Kind == PendingRequestKind.Plan ? Theme.Limits.PlanScrollBlocks : Theme.Limits.RequestDiffScrollLines;
        RequestDiffScroll = new RequestDiffScroll { Seq = RequestDiffScroll.Seq + 1, Delta = step * unit };
    }
}
