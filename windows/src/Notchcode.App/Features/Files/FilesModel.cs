// FilesModel.cs
// Port of Sources/notchcode/Features/Files/FilesModel.swift.
// The Files tool's value types: a loaded preview, a visible tree row, a file's ±counts, the
// lines this session changed, and the tool's state that AppState keeps as one value
// (`FilesTool`).

using System.Collections.Immutable;
using Notchcode.Core;

namespace Notchcode.Features.Files;

/// A file preview as loaded for the pane, with the line count when RepoFiles capped it.
public sealed record LoadedPreview
{
    public FilePreview Preview { get; init; } = new();
    /// Lines in the whole file, when the preview was truncated and the count is known.
    public int? TotalLines { get; init; }
}

/// One visible row of the tree.
public sealed record TreeRow
{
    public string Id => Node.Path;
    public FileTreeNode Node { get; init; } = new();
    public int Depth { get; init; }
    public bool IsOpen { get; init; }
    /// Position among its parent's children, for the 40 ms stagger when a folder opens.
    public int ChildIndex { get; init; }
}

/// ±counts of a file across the session's turns.
public readonly record struct FileChangeCount(int Added, int Removed);

/// Lines of the current file this session changed. `Added` are new-file line numbers;
/// `RemovedAt` are the lines that now sit where removed lines used to be.
public sealed record ChangeMarks
{
    public ImmutableHashSet<int> Added { get; init; } = [];
    public ImmutableHashSet<int> RemovedAt { get; init; } = [];
    public bool IsEmpty => Added.IsEmpty && RemovedAt.IsEmpty;
    public int? FirstLine
    {
        get
        {
            var all = Added.Union(RemovedAt);
            return all.IsEmpty ? null : all.Min();
        }
    }

    public bool Equals(ChangeMarks? o) => o is not null && Added.SetEquals(o.Added) && RemovedAt.SetEquals(o.RemovedAt);
    public override int GetHashCode() => HashCode.Combine(Added.Count, RemovedAt.Count);
}

/// Files tab. Per session: the tree cursor, the file being previewed, and the folders
/// flipped from their default (top level open, deeper closed). Tree paths are relative to the
/// session's cwd with '/' separators, as on macOS.
public sealed record FilesToolState
{
    /// cwd -> the repository tree, as RepoFiles last read it.
    public ImmutableDictionary<string, IReadOnlyList<FileTreeNode>> RepoTrees { get; init; }
        = ImmutableDictionary<string, IReadOnlyList<FileTreeNode>>.Empty;
    /// cwds whose tree is being read right now.
    public ImmutableHashSet<string> RepoTreesLoading { get; init; } = [];
    public ImmutableDictionary<string, string> TreeCursor { get; init; } = ImmutableDictionary<string, string>.Empty;
    public ImmutableDictionary<string, string> OpenedFile { get; init; } = ImmutableDictionary<string, string>.Empty;
    public ImmutableDictionary<string, ImmutableHashSet<string>> TreeToggled { get; init; }
        = ImmutableDictionary<string, ImmutableHashSet<string>>.Empty;
    /// The Files tab's name filter. Esc clears it.
    public string Filter { get; init; } = "";
    /// The filter field has keyboard focus: typed keys go to it, not to the card's shortcuts.
    public bool FilterFocused { get; init; }
    /// The preview of the opened file, keyed "cwd|path". Only the newest few are kept.
    public ImmutableDictionary<string, LoadedPreview> Previews { get; init; } = ImmutableDictionary<string, LoadedPreview>.Empty;
    /// Session id -> a Markdown file shows its source instead of the rendered preview.
    /// In memory only: every run starts on Preview.
    public ImmutableDictionary<string, bool> MarkdownSource { get; init; } = ImmutableDictionary<string, bool>.Empty;
}
