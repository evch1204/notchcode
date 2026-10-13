// ChangesModel.cs
// Port of Sources/notchcode/Features/Changes/ChangesModel.swift.
// The Changes tool's value types: a file chip's key, the timeline's blocks, the cursor's
// stops, and the tool's view choices that AppState keeps as one value (`ChangesTool`).

using System.Collections.Immutable;
using Notchcode.Core;

namespace Notchcode.Features.Changes;

/// A file chip: the file `Path` as the turn `TurnId` changed it.
public readonly record struct ChangesChipKey(string TurnId, string Path);

/// One block of the timeline, newest first.
public abstract record ChangesBlock
{
    private ChangesBlock() { }

    public abstract string Id { get; }

    /// A turn with files, or the live turn. `Number` counts from the session's first turn.
    public sealed record Entry(TranscriptTurn Turn, int Number, bool Live) : ChangesBlock
    {
        public override string Id => "e|" + Turn.Id;
    }

    /// A run of turns without files, newest first; keyed by its newest turn's id.
    public sealed record Quiet(string GroupId, IReadOnlyList<TranscriptTurn> Turns) : ChangesBlock
    {
        public override string Id => "g|" + GroupId;

        public bool Equals(Quiet? other) => other is not null && GroupId == other.GroupId && Turns.SequenceEqual(other.Turns);
        public override int GetHashCode() => HashCode.Combine(GroupId, Turns.Count);
    }
}

/// A stop of the Changes cursor (`RowCursor` indexes `ChangesCursorItems`).
public abstract record ChangesItem
{
    private ChangesItem() { }

    public abstract string Id { get; }

    /// The live turn while it has no edits: the cursor rests on it.
    public sealed record Live(string TurnId) : ChangesItem
    {
        public override string Id => "l|" + TurnId;
    }

    public sealed record Chip(ChangesChipKey Key) : ChangesItem
    {
        public override string Id => ChangesIds.Chip(Key);
    }

    /// A quiet group's row.
    public sealed record Group(string GroupId) : ChangesItem
    {
        public override string Id => "g|" + GroupId;
    }

    /// One turn of an unfolded quiet group.
    public sealed record Quiet(string TurnId) : ChangesItem
    {
        public override string Id => "q|" + TurnId;
    }
}

/// The view ids of the timeline's stops (Swift `AppState.changesChipID`).
public static class ChangesIds
{
    public static string Chip(ChangesChipKey key) => "c|" + key.TurnId + "|" + key.Path;
}

/// The Changes tool's view choices. All reset when the focused session changes.
public sealed record ChangesToolState
{
    /// The chip whose diff the pane shows (it stays after esc closes the pane).
    public ChangesChipKey? Selection { get; init; }
    /// The diff pane is open beside the timeline.
    public bool PaneOpen { get; init; }
    /// `/`: only the turns with edits (and the live turn); quiet groups hide.
    public bool EditsOnly { get; init; }
    /// Quiet groups unfolded into one row per turn, by the group's id.
    public ImmutableHashSet<string> UnfoldedGroups { get; init; } = [];
    /// Ctrl B while the pane shows: the timeline column is hidden and the pane takes the width.
    public bool ColumnHidden { get; init; }

    public bool Equals(ChangesToolState? o)
        => o is not null && Selection == o.Selection && PaneOpen == o.PaneOpen && EditsOnly == o.EditsOnly
           && UnfoldedGroups.SetEquals(o.UnfoldedGroups) && ColumnHidden == o.ColumnHidden;

    public override int GetHashCode() => HashCode.Combine(Selection, PaneOpen, EditsOnly, UnfoldedGroups.Count, ColumnHidden);
}
