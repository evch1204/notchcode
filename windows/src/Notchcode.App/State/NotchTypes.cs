// NotchTypes.cs
// Port of Sources/notchcode/State/NotchTypes.swift.
// Small types shared across the notch: modes, tabs, card content, keys, session groups,
// peeks and the question preview.

using Notchcode.Core;

namespace Notchcode.State;

public enum NotchMode
{
    Closed,
    /// `Resting`: sessions exist but none works or needs the owner; a dim name, nothing moves.
    Resting,
    Wings,
    Attention,
    Peek,
    Card,
}

/// The strip's tools, plus Settings behind the gear.
public enum CardTab { Changes, Files, Usage, Git, Sessions, Settings }

public static class CardTabs
{
    /// The tabs the owner can move between with 1-5 and tab, left to right.
    public static readonly IReadOnlyList<CardTab> Browsable =
        [CardTab.Sessions, CardTab.Changes, CardTab.Files, CardTab.Git, CardTab.Usage];

    extension(CardTab tab)
    {
        public string Label => tab switch
        {
            CardTab.Changes => "Changes",
            CardTab.Files => "Files",
            CardTab.Usage => "Usage",
            CardTab.Git => "Git",
            CardTab.Sessions => "Sessions",
            _ => "Settings",
        };

        /// One of `Browsable` (not Settings).
        public bool IsBrowsable => Browsable.Contains(tab);
    }
}

/// What the open card shows, in priority order: a waiting request, the question, Settings,
/// or the selected tool's pane. The single source for the well, the strip's right wing, the
/// bridge, the footer keys and the card's height.
public abstract record CardContent
{
    private CardContent() { }

    public sealed record Request(PendingRequest Value) : CardContent;
    public sealed record Question(QuestionPreview Value) : CardContent;
    public sealed record Settings : CardContent
    {
        public static readonly Settings Instance = new();
    }
    public sealed record Tool(CardTab Tab) : CardContent;
}

/// The keys the card understands (NotchKey.Kind), already decoded from the WPF key event.
public enum NotchKeyKind
{
    Primary, Deny, Always, Edit, Escape, NextTab, PreviousTab, Up, Down, Left, Right, Teleport, Settings, Copy, Quit,
    /// "D": open or close a request card's diff.
    Diff,
    /// "/": focus the Files tab's filter field.
    Filter,
    /// Ctrl B: hide or show the Files tool's tree.
    ToggleTree,
    /// "P": Preview or Code for a Markdown file in the Files tool; the sync pill in the Git tool.
    MarkdownMode,
    /// "W": the Git tool's branch picker.
    Worktree,
    /// "R": the branch picker's repository dropdown in the Git tool; refresh in the Usage tool.
    Repository,
    /// "C": the Git tool's commit form.
    Commit,
    /// "U": undo the newest unpushed commit in the Git tool.
    Undo,
    /// Space: put the Git tool's cursor file in or out of the commit.
    Toggle,
    /// Ctrl ⏎: commit from the Git tool's commit form, also from its description.
    Submit,
    /// 1-9: `N` holds the digit.
    Number,
}

/// Keys the card understands, already decoded from the WPF key event. The Swift enum with
/// its `number(Int)` case: compare with `==` (`key == NotchKey.Primary`), or switch on `Kind`.
public readonly record struct NotchKey(NotchKeyKind Kind, int N = 0)
{
    public static NotchKey Primary => new(NotchKeyKind.Primary);
    public static NotchKey Deny => new(NotchKeyKind.Deny);
    public static NotchKey Always => new(NotchKeyKind.Always);
    public static NotchKey Edit => new(NotchKeyKind.Edit);
    public static NotchKey Escape => new(NotchKeyKind.Escape);
    public static NotchKey NextTab => new(NotchKeyKind.NextTab);
    public static NotchKey PreviousTab => new(NotchKeyKind.PreviousTab);
    public static NotchKey Up => new(NotchKeyKind.Up);
    public static NotchKey Down => new(NotchKeyKind.Down);
    public static NotchKey Left => new(NotchKeyKind.Left);
    public static NotchKey Right => new(NotchKeyKind.Right);
    public static NotchKey Teleport => new(NotchKeyKind.Teleport);
    public static NotchKey Settings => new(NotchKeyKind.Settings);
    public static NotchKey Copy => new(NotchKeyKind.Copy);
    public static NotchKey Quit => new(NotchKeyKind.Quit);
    public static NotchKey Diff => new(NotchKeyKind.Diff);
    public static NotchKey Filter => new(NotchKeyKind.Filter);
    public static NotchKey ToggleTree => new(NotchKeyKind.ToggleTree);
    public static NotchKey MarkdownMode => new(NotchKeyKind.MarkdownMode);
    public static NotchKey Worktree => new(NotchKeyKind.Worktree);
    public static NotchKey Repository => new(NotchKeyKind.Repository);
    public static NotchKey Commit => new(NotchKeyKind.Commit);
    public static NotchKey Undo => new(NotchKeyKind.Undo);
    public static NotchKey Toggle => new(NotchKeyKind.Toggle);
    public static NotchKey Submit => new(NotchKeyKind.Submit);
    public static NotchKey Number(int n) => new(NotchKeyKind.Number, n);

    /// The digit of a `Number` key, else null.
    public int? NumberValue => Kind == NotchKeyKind.Number ? N : null;
}

/// One repository in the Sessions tab: its worktrees' sessions, most urgent first.
public sealed record SessionGroup
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public List<Session> Sessions { get; init; } = [];
    /// Distinct working folders in the group.
    public int WorktreeCount => Sessions.Select(s => s.Cwd).Distinct().Count();
    /// A worktree checkout, or more than one folder: the header counts worktrees.
    public bool HasWorktrees => WorktreeCount > 1 || Sessions.Any(s => s.DisplaySub is not null);

    public bool Equals(SessionGroup? o)
        => o is not null && Id == o.Id && Name == o.Name && Sessions.SequenceEqual(o.Sessions);

    public override int GetHashCode() => HashCode.Combine(Id, Name, Sessions.Count);
}

public enum PeekKind { Edit, Done, Agent }

/// A one-line passive notice shown for a few seconds.
/// Peeks mark completions: a finished turn, a finished subagent, and (if the owner opts in) each edit.
public sealed record Peek
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public PeekKind Kind { get; init; }
    public string SessionId { get; init; } = "";
    public string Title { get; init; } = "";
    public int? Added { get; init; }
    public int? Removed { get; init; }
    public string? Detail { get; init; }
    /// Agent peeks: the finished agent's colour slot.
    public int? ColorIndex { get; init; }
}

/// A question Claude asked in the terminal. Read-only here: no hook can answer it.
public sealed record QuestionPreview
{
    public string SessionId { get; init; } = "";
    public string Question { get; init; } = "";
    public IReadOnlyList<string> Options { get; init; } = [];

    public bool Equals(QuestionPreview? o)
        => o is not null && SessionId == o.SessionId && Question == o.Question && Options.SequenceEqual(o.Options);

    public override int GetHashCode() => HashCode.Combine(SessionId, Question, Options.Count);
}
