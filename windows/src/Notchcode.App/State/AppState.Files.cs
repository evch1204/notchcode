// AppState.Files.cs
// Port of Sources/notchcode/Features/Files/AppState+Files.swift.
// The Files tool's AppState partial: the repository tree from RepoFiles, which folders are
// open, the name filter, the keyboard cursor, the previewed file (remembered per session),
// and which lines of that file this session changed. Also the two view switches: the tree
// collapsed (Ctrl B, saved with the preferences) and a Markdown file's Preview · Code (P, per
// session, in memory). Its value types are in Features/Files/FilesModel.cs.
//
// Reading only. RepoFiles reads the disk off the UI thread; nothing here writes a file.
// Tree paths are relative with '/' separators; FileChange paths are made to match.

using System.Collections.Immutable;
using System.IO;
using Notchcode.Core;
using Notchcode.Features.Files;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: Tree

    /// The focused session's tree, if read.
    public IReadOnlyList<FileTreeNode>? FocusedTree
    {
        get
        {
            if (FocusedSession?.Cwd is not { Length: > 0 } cwd) return null;
            return FilesTool.RepoTrees.TryGetValue(cwd, out var nodes) ? nodes : null;
        }
    }

    /// Reads the focused session's tree in the background. RepoFiles caches it, so calling
    /// this every time the tab shows is cheap.
    public void LoadRepoTree()
    {
        if (FocusedSession?.Cwd is not { Length: > 0 } cwd || FilesTool.RepoTreesLoading.Contains(cwd)) return;
        FilesTool = FilesTool with { RepoTreesLoading = FilesTool.RepoTreesLoading.Add(cwd) };
        _ = LoadRepoTreeAsync(cwd);
    }

    private async Task LoadRepoTreeAsync(string cwd)
    {
        var nodes = await Task.Run(() => RepoFiles.Tree(cwd));
        ApplyTree(nodes, cwd);
    }

    private void ApplyTree(List<FileTreeNode> nodes, string cwd)
    {
        var next = FilesTool with { RepoTreesLoading = FilesTool.RepoTreesLoading.Remove(cwd) };
        if (!next.RepoTrees.TryGetValue(cwd, out var old) || !old.SequenceEqual(nodes))
            next = next with { RepoTrees = next.RepoTrees.SetItem(cwd, nodes) };
        FilesTool = next;
        if (FocusedSession is { } session && session.Cwd == cwd
            && FilesTool.OpenedFile.TryGetValue(session.Id, out var path)
            && !FilesTool.Previews.ContainsKey(PreviewKey(cwd, path)))
            LoadPreview(cwd, path);
    }

    public static int Depth(string path) => path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length - 1;

    /// Top-level folders start open, deeper ones closed; a click or ←/→ flips one.
    public bool IsFolderOpen(string path, string sessionId)
    {
        bool openByDefault = Depth(path) == 0;
        bool toggled = FilesTool.TreeToggled.TryGetValue(sessionId, out var set) && set.Contains(path);
        return openByDefault != toggled;
    }

    public void SetFolder(string path, bool open, string sessionId)
    {
        if (IsFolderOpen(path, sessionId) == open) return;
        var set = FilesTool.TreeToggled.TryGetValue(sessionId, out var s) ? s : [];
        set = set.Contains(path) ? set.Remove(path) : set.Add(path);
        FilesTool = FilesTool with { TreeToggled = FilesTool.TreeToggled.SetItem(sessionId, set) };
    }

    /// The rows the tree shows right now. With a filter: files whose name contains it, and the
    /// folders above them, all open; a folder whose own name matches keeps its whole subtree.
    public List<TreeRow> VisibleTreeRows()
    {
        if (FocusedSession?.Id is not { } sid || FocusedTree is not { } tree) return [];
        var query = FilesTool.Filter.Trim().ToLowerInvariant();
        var rows = new List<TreeRow>();

        bool Matches(FileTreeNode node) => node.Name.ToLowerInvariant().Contains(query, StringComparison.Ordinal);
        bool HasMatch(FileTreeNode node) => Matches(node) || (node.IsDirectory && node.Children.Any(HasMatch));
        void Add(IReadOnlyList<FileTreeNode> nodes, int depth, bool filtering)
        {
            int index = 0;
            foreach (var node in nodes)
            {
                if (filtering && !HasMatch(node)) continue;
                // Inside a folder whose own name matched, everything below shows normally.
                bool keepFiltering = filtering && !Matches(node);
                bool open = node.IsDirectory && (keepFiltering || IsFolderOpen(node.Path, sid));
                rows.Add(new TreeRow { Node = node, Depth = depth, IsOpen = open, ChildIndex = index });
                index++;
                if (node.IsDirectory && open) Add(node.Children, depth + 1, keepFiltering);
            }
        }
        Add(tree, 0, query.Length > 0);
        return rows;
    }

    // MARK: Cursor and keys

    public string? TreeCursorPath
        => FocusedSession is { } s && FilesTool.TreeCursor.TryGetValue(s.Id, out var p) ? p : null;

    public string? OpenedFilePath
        => FocusedSession is { } s && FilesTool.OpenedFile.TryGetValue(s.Id, out var p) ? p : null;

    private void SetTreeCursor(string sid, string path)
        => FilesTool = FilesTool with { TreeCursor = FilesTool.TreeCursor.SetItem(sid, path) };

    /// The Files tab's keys. Null: not a Files key, let the card handle it.
    public bool? HandleFilesKey(NotchKey key)
    {
        if (FocusedSession?.Id is not { } sid) return null;
        // The tree's own keys bring a collapsed tree back first, then act.
        if (key.Kind is NotchKeyKind.Filter or NotchKeyKind.Up or NotchKeyKind.Down or NotchKeyKind.Left or NotchKeyKind.Right
            && FilesTreeCollapsed)
            SetFilesTreeHidden(false);
        switch (key.Kind)
        {
            case NotchKeyKind.ToggleTree:
                ToggleFilesTree();
                return true;
            case NotchKeyKind.MarkdownMode:
                return ToggleMarkdownMode();
            case NotchKeyKind.Filter:
                FilesTool = FilesTool with { FilterFocused = true };
                return true;
            case NotchKeyKind.Up:
            case NotchKeyKind.Down:
            {
                var rows = VisibleTreeRows();
                if (rows.Count == 0) return false;
                FilesTool.TreeCursor.TryGetValue(sid, out var cursor);
                int current = rows.FindIndex(r => r.Id == cursor);
                bool down = key.Kind == NotchKeyKind.Down;
                int next = current >= 0
                    ? Math.Max(0, Math.Min(rows.Count - 1, current + (down ? 1 : -1)))
                    : down ? 0 : rows.Count - 1;
                SetTreeCursor(sid, rows[next].Id);
                return true;
            }
            case NotchKeyKind.Right:
            {
                if (CursorRow() is not { } row || !row.Node.IsDirectory) return false;
                if (row.IsOpen)
                {
                    // Already open: step onto its first child, as Explorer and VS Code do.
                    var first = VisibleTreeRows().FirstOrDefault(r => Parent(r.Id) == row.Id);
                    if (first is not null) SetTreeCursor(sid, first.Id);
                }
                else
                {
                    SetFolder(row.Id, true, sid);
                }
                return true;
            }
            case NotchKeyKind.Left:
            {
                if (CursorRow() is not { } row) return false;
                if (row.Node.IsDirectory && row.IsOpen && FilesTool.Filter.Length == 0)
                    SetFolder(row.Id, false, sid);
                else if (Parent(row.Id) is { } parent)
                    SetTreeCursor(sid, parent);
                return true;
            }
            case NotchKeyKind.Primary:
            {
                if (CursorRow() is not { } row) return false;
                if (row.Node.IsDirectory)
                {
                    if (FilesTool.Filter.Length > 0) return true;
                    SetFolder(row.Id, !row.IsOpen, sid);
                }
                else
                {
                    OpenFile(row.Id);
                }
                return true;
            }
            case NotchKeyKind.Copy:
                return CopyFileLocation();
            default:
                return null;
        }
    }

    private TreeRow? CursorRow()
    {
        if (TreeCursorPath is not { } path) return null;
        return VisibleTreeRows().FirstOrDefault(r => r.Id == path);
    }

    public static string? Parent(string path)
    {
        int i = path.LastIndexOf('/');
        return i <= 0 ? null : path[..i];
    }

    /// A click on a tree row: folders open or close, files open in the preview.
    public void ClickTreeRow(TreeRow row)
    {
        if (FocusedSession?.Id is not { } sid) return;
        SetTreeCursor(sid, row.Id);
        if (row.Node.IsDirectory)
        {
            if (FilesTool.Filter.Length > 0) return;
            SetFolder(row.Id, !row.IsOpen, sid);
        }
        else
        {
            OpenFile(row.Id);
        }
    }

    /// Shows a file in the preview and remembers it for this session.
    public void OpenFile(string path)
    {
        if (FocusedSession is not { } session) return;
        FilesTool = FilesTool with
        {
            TreeCursor = FilesTool.TreeCursor.SetItem(session.Id, path),
            OpenedFile = FilesTool.OpenedFile.SetItem(session.Id, path),
        };
        LoadPreview(session.Cwd, path);
    }

    /// "y" in Files: `path:line` of the first changed line of the file under the cursor
    /// (else the previewed file). Line 1 when this session did not change it.
    public bool CopyFileLocation()
    {
        if (FocusedSession?.Id is not { } sid) return false;
        FilesTool.OpenedFile.TryGetValue(sid, out var path);
        if (FilesTool.TreeCursor.TryGetValue(sid, out var cursor)
            && VisibleTreeRows().FirstOrDefault(r => r.Id == cursor) is { Node.IsDirectory: false })
            path = cursor;
        if (path is null) return false;
        CopyLocation(path.Replace('/', '\\'), ChangeMarksFor(path).FirstLine ?? 1);
        return true;
    }

    // MARK: View switches

    /// The owner collapsed the tree. It only takes effect while a file is open: with nothing
    /// to preview, the tree shows (and the collapse pill is disabled).
    public bool FilesTreeCollapsed => Prefs.FilesTreeHidden && OpenedFilePath is not null;

    public void SetFilesTreeHidden(bool hidden)
    {
        if (Prefs.FilesTreeHidden == hidden) return;
        if (hidden) FilesTool = FilesTool with { FilterFocused = false };
        Prefs = Prefs with { FilesTreeHidden = hidden };
    }

    /// Ctrl B or the pill. Does nothing with no file open.
    public void ToggleFilesTree()
    {
        if (OpenedFilePath is null) return;
        SetFilesTreeHidden(!FilesTreeCollapsed);
    }

    public static bool IsMarkdown(string path)
        => System.IO.Path.GetExtension(path).ToLowerInvariant() is ".md" or ".markdown" or ".mdx";

    /// The focused session shows Markdown as source (Code) rather than rendered (Preview).
    public bool MarkdownShowsCode
    {
        get => FocusedSession is { } s && FilesTool.MarkdownSource.TryGetValue(s.Id, out var code) && code;
        set
        {
            if (FocusedSession?.Id is not { } sid || MarkdownShowsCode == value) return;
            FilesTool = FilesTool with { MarkdownSource = FilesTool.MarkdownSource.SetItem(sid, value) };
        }
    }

    /// P: flips Preview · Code when the opened file is Markdown.
    public bool ToggleMarkdownMode()
    {
        if (OpenedFilePath is not { } path || !IsMarkdown(path)) return false;
        MarkdownShowsCode = !MarkdownShowsCode;
        return true;
    }

    // MARK: Preview

    public static string PreviewKey(string cwd, string path) => cwd + "|" + path;

    /// The previewed file of the focused session, when loaded.
    public LoadedPreview? OpenedPreview
    {
        get
        {
            if (FocusedSession is not { } session || !FilesTool.OpenedFile.TryGetValue(session.Id, out var path)) return null;
            return FilesTool.Previews.TryGetValue(PreviewKey(session.Cwd, path), out var loaded) ? loaded : null;
        }
    }

    public void ReloadOpenedPreview()
    {
        if (FocusedSession is not { } session || !FilesTool.OpenedFile.TryGetValue(session.Id, out var path)) return;
        LoadPreview(session.Cwd, path);
    }

    /// Reads the file off the UI thread. When RepoFiles capped it, also counts the whole
    /// file's lines for the "… N more lines" footer.
    public void LoadPreview(string cwd, string path)
    {
        if (cwd.Length == 0) return;
        _ = LoadPreviewAsync(cwd, path);
    }

    private async Task LoadPreviewAsync(string cwd, string path)
    {
        var key = PreviewKey(cwd, path);
        var loaded = await Task.Run(() =>
        {
            var preview = RepoFiles.Preview(cwd, path);
            int? total = null;
            if (preview.Truncated && !preview.IsBinary)
                total = CountLines(System.IO.Path.Combine(cwd, path.Replace('/', '\\')));
            return new LoadedPreview { Preview = preview, TotalLines = total };
        });
        ApplyPreview(loaded, key);
    }

    private void ApplyPreview(LoadedPreview loaded, string key)
    {
        if (FilesTool.Previews.TryGetValue(key, out var existing) && existing == loaded) return;
        var previews = FilesTool.Previews;
        // Keep the newest few: the one showing plus a handful to flip back to.
        if (!previews.ContainsKey(key) && previews.Count >= Theme.Limits.MaxCachedPreviews)
        {
            string? keep = FocusedSession is { } s && FilesTool.OpenedFile.TryGetValue(s.Id, out var p) ? PreviewKey(s.Cwd, p) : null;
            var drop = previews.Keys.FirstOrDefault(k => k != keep);
            if (drop is not null) previews = previews.Remove(drop);
        }
        FilesTool = FilesTool with { Previews = previews.SetItem(key, loaded) };
    }

    /// Line breaks in the file, plus one for a last line without one. Null when unreadable.
    public static int? CountLines(string path)
    {
        using var stream = RegularFile.Open(path);
        if (stream is null) return null;
        try
        {
            var buffer = new byte[64 * 1024];
            int count = 0;
            int last = -1;
            int n;
            while ((n = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                count += buffer.AsSpan(0, n).Count((byte)0x0A);
                last = buffer[n - 1];
            }
            if (last >= 0 && last != 0x0A) count++;
            return count;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    // MARK: What this session changed

    /// A path from a FileChange, relative to the session's cwd when it lies inside it, with
    /// '/' separators like the tree's.
    public string RelativePath(string path)
    {
        if (FocusedSession?.Cwd is not { Length: > 0 } cwd) return path.Replace('\\', '/');
        return Paths.Relative(path, cwd).Replace('\\', '/');
    }

    /// Relative path -> summed ±counts across every turn of the focused session.
    public Dictionary<string, FileChangeCount> SessionChangeCounts
    {
        get
        {
            var result = new Dictionary<string, FileChangeCount>(StringComparer.OrdinalIgnoreCase);
            foreach (var turn in Turns(FocusedSession?.Id))
                foreach (var file in turn.Files)
                {
                    var key = RelativePath(file.Path);
                    var count = result.TryGetValue(key, out var c) ? c : new FileChangeCount(0, 0);
                    result[key] = new FileChangeCount(count.Added + file.Added, count.Removed + file.Removed);
                }
            return result;
        }
    }

    /// The lines of `path` this session changed, in the file's current numbering. Patches are
    /// applied oldest first; each newer patch moves (or drops) the marks older ones left.
    /// Best effort: a patch Claude Code capped at 400 lines only marks what it recorded.
    public ChangeMarks ChangeMarksFor(string path)
    {
        var added = new HashSet<int>();
        var removedAt = new HashSet<int>();
        var oldestFirst = Turns(FocusedSession?.Id);
        oldestFirst.Reverse();
        foreach (var turn in oldestFirst)
        {
            foreach (var file in turn.Files)
            {
                if (!string.Equals(RelativePath(file.Path), path, StringComparison.OrdinalIgnoreCase)) continue;
                var patch = file.Patch.Count == 0 ? file.Snippet : file.Patch;
                if (patch.Count == 0) continue;
                added = added.Select(n => MapLine(n, patch)).OfType<int>().ToHashSet();
                removedAt = removedAt.Select(n => MapLine(n, patch)).OfType<int>().ToHashSet();
                int delta = 0;
                foreach (var line in patch)
                {
                    switch (line.Kind)
                    {
                        case DiffLineKind.Context:
                            if (line.OldLine is int o && line.NewLine is int nw) delta = nw - o;
                            break;
                        case DiffLineKind.Added:
                            if (line.NewLine is int a) added.Add(a);
                            delta += 1;
                            break;
                        case DiffLineKind.Removed:
                            if (line.OldLine is int r) removedAt.Add(r + delta);
                            delta -= 1;
                            break;
                    }
                }
            }
        }
        // A removal that sits on an added line reads as a change already; keep one tint per line.
        removedAt.ExceptWith(added);
        return new ChangeMarks { Added = added.ToImmutableHashSet(), RemovedAt = removedAt.ToImmutableHashSet() };
    }

    /// Where old line `n` ends up after `patch`, or null when the patch removed it.
    public static int? MapLine(int n, IReadOnlyList<DiffLine> patch)
    {
        int delta = 0;
        foreach (var line in patch)
        {
            switch (line.Kind)
            {
                case DiffLineKind.Context:
                    if (line.OldLine is not int old || line.NewLine is not int nw) continue;
                    if (old == n) return nw;
                    if (old > n) return n + delta;
                    delta = nw - old;
                    break;
                case DiffLineKind.Removed:
                    if (line.OldLine is not int removed) continue;
                    if (removed == n) return null;
                    if (removed > n) return n + delta;
                    delta -= 1;
                    break;
                case DiffLineKind.Added:
                    delta += 1;
                    break;
            }
        }
        return n + delta;
    }
}
