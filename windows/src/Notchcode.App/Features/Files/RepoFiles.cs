// RepoFiles.cs
// Port of Sources/notchcode/Features/Files/RepoFiles.swift.
// The session's working directory as a file tree for the Files tab, and a capped text
// preview of one file. Reads the disk directly; never runs git.
//
// Ignored: a fixed list of build and tool folders, plus the patterns in <cwd>\.gitignore
// (common subset: plain names, `dir/`, `*.ext` globs, leading `/`, `**/` prefixes, and
// `a/b` paths, which are anchored like git does). Negations (`!x`) are skipped.
// Windows: tree paths are relative with '/' separators, as on macOS; names match the ignore
// rules case-insensitively (Git for Windows sets core.ignorecase); reparse points (symbolic
// links, junctions) are shown as leaves, never followed, as symlinked folders are on macOS.

using System.IO;
using System.Text;
using Notchcode.Core;

namespace Notchcode.Features.Files;

public static class RepoFiles
{
    /// Thumbs.db is Windows' .DS_Store.
    public static readonly IReadOnlySet<string> AlwaysIgnored = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        ".git", "node_modules", "build", "DerivedData", ".build", ".swiftpm", "Pods", "dist", ".DS_Store", "Thumbs.db",
    };

    // MARK: Tree

    /// Every file and folder under `cwd` that is not ignored, as a tree sorted directories
    /// first, then files, case-insensitively. Walked breadth first, so when more than
    /// `maxEntries` exist the top levels are complete and the deepest folders are left empty.
    /// Cached per cwd for 10 s, and dropped sooner when the top-level folder's mtime changes.
    public static List<FileTreeNode> Tree(string cwd, int maxEntries = 4000)
    {
        var root = Normalized(cwd);
        if (Stamp(root) is not DateTime mtime) return [];
        var now = DateTime.UtcNow;

        lock (treeLock)
        {
            if (treeCache.TryGetValue(root, out var hit) && hit.Mtime == mtime && hit.MaxEntries == maxEntries
                && (now - hit.BuiltAt).TotalSeconds < 10)
                return hit.Nodes;
        }

        var nodes = Walk(root, maxEntries);
        lock (treeLock) treeCache[root] = new TreeEntry(mtime, maxEntries, now, nodes);
        return nodes;
    }

    private sealed record TreeEntry(DateTime Mtime, int MaxEntries, DateTime BuiltAt, List<FileTreeNode> Nodes);
    private static readonly object treeLock = new();
    private static readonly Dictionary<string, TreeEntry> treeCache = new(StringComparer.OrdinalIgnoreCase);

    /// Mutable while walking; turned into value-type FileTreeNodes at the end.
    private sealed class Box(string path, string name, bool isDirectory)
    {
        public readonly string Path = path;
        public readonly string Name = name;
        public readonly bool IsDirectory = isDirectory;
        public readonly List<Box> Children = [];
        public FileTreeNode Node() => new() { Path = Path, Name = Name, IsDirectory = IsDirectory, Children = Children.Select(c => c.Node()).ToList() };
    }

    private static List<FileTreeNode> Walk(string root, int maxEntries)
    {
        var rules = IgnoreRulesFor(root);
        var top = new Box("", "", true);
        var queue = new List<Box> { top };
        int head = 0;
        int count = 0;

        while (head < queue.Count && count < maxEntries)
        {
            var dir = queue[head++];
            var absolute = dir.Path.Length == 0 ? root : System.IO.Path.Combine(root, dir.Path.Replace('/', '\\'));
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(absolute).ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { continue; }

            var kids = new List<Box>();
            foreach (var full in entries)
            {
                var name = System.IO.Path.GetFileName(full);
                var rel = dir.Path.Length == 0 ? name : dir.Path + "/" + name;
                bool isDir = IsRealDirectory(full);
                if (AlwaysIgnored.Contains(name) || rules.Matches(rel, name, isDir)) continue;
                kids.Add(new Box(rel, name, isDir));
            }
            kids.Sort(Order);
            foreach (var kid in kids)
            {
                if (count >= maxEntries) break;
                dir.Children.Add(kid);
                count++;
                if (kid.IsDirectory) queue.Add(kid);
            }
        }
        return top.Children.Select(c => c.Node()).ToList();
    }

    private static int Order(Box a, Box b)
    {
        if (a.IsDirectory != b.IsDirectory) return a.IsDirectory ? -1 : 1;
        int c = string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        return c != 0 ? c : string.CompareOrdinal(a.Name, b.Name);
    }

    /// A directory that is not a reparse point (symbolic links and junctions are shown as leaves, never followed).
    private static bool IsRealDirectory(string path)
    {
        try
        {
            var attrs = File.GetAttributes(path);
            return (attrs & FileAttributes.Directory) != 0 && (attrs & FileAttributes.ReparsePoint) == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    // MARK: Ignore

    public sealed class IgnoreRules
    {
        public sealed record Rule(string Pattern, bool Anchored, bool DirectoryOnly);

        public List<Rule> Rules { get; } = [];

        public IgnoreRules(string text)
        {
            foreach (var raw in text.SplitLines(omittingEmptySubsequences: true))
            {
                var p = raw;
                while (p.EndsWith(' ') && !p.EndsWith("\\ ", StringComparison.Ordinal)) p = p[..^1];
                if (p.Length == 0 || p.StartsWith('#') || p.StartsWith('!')) continue;
                if (p.StartsWith('\\')) p = p[1..];
                bool directoryOnly = false;
                if (p.EndsWith('/')) { directoryOnly = true; p = p[..^1]; }
                bool anchored = false;
                if (p.StartsWith('/')) { anchored = true; p = p[1..]; }
                while (p.StartsWith("**/", StringComparison.Ordinal)) { p = p[3..]; anchored = false; }
                if (p.Contains('/') && !p.StartsWith("**", StringComparison.Ordinal)) anchored = true;
                if (p.EndsWith("/**", StringComparison.Ordinal)) { p = p[..^3]; directoryOnly = true; }
                if (p.Length == 0) continue;
                Rules.Add(new Rule(p, anchored, directoryOnly));
            }
        }

        public bool Matches(string relativePath, string name, bool isDirectory)
        {
            foreach (var r in Rules)
            {
                if (r.DirectoryOnly && !isDirectory) continue;
                if (r.Anchored)
                {
                    bool pathName = !r.Pattern.Contains("**", StringComparison.Ordinal);
                    if (Glob.Match(r.Pattern, relativePath, pathName)) return true;
                }
                else if (r.Pattern.Contains('/'))
                {
                    // "**/a/b": the tail may sit at any depth.
                    if (Glob.Match(r.Pattern, relativePath, false) || Glob.Match("*/" + r.Pattern, relativePath, false)) return true;
                }
                else if (Glob.Match(r.Pattern, name, false))
                {
                    return true;
                }
            }
            return false;
        }
    }

    private static readonly object rulesLock = new();
    private static readonly Dictionary<string, (DateTime? Mtime, IgnoreRules Rules)> rulesCache = new(StringComparer.OrdinalIgnoreCase);

    /// <cwd>\.gitignore, re-read when its mtime changes.
    private static IgnoreRules IgnoreRulesFor(string root)
    {
        var path = System.IO.Path.Combine(root, ".gitignore");
        DateTime? mtime = File.Exists(path) ? File.GetLastWriteTimeUtc(path) : null;
        lock (rulesLock)
        {
            if (rulesCache.TryGetValue(root, out var hit) && hit.Mtime == mtime) return hit.Rules;
        }
        string text = "";
        if (mtime is not null)
        {
            try { text = File.ReadAllText(path, Encoding.UTF8); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        var rules = new IgnoreRules(text);
        lock (rulesLock) rulesCache[root] = (mtime, rules);
        return rules;
    }

    // MARK: Preview

    public const int MaxPreviewBytes = 4 * 1024 * 1024;

    /// The file's lines as text, at most `maxLines` (then `Truncated`). A file whose first 8 KB
    /// hold a NUL byte is binary: `IsBinary` and no lines. Files over 4 MB are read in part and
    /// marked truncated. Paths escaping `cwd` or unreadable files give an empty preview.
    public static FilePreview Preview(string cwd, string relativePath, int maxLines = 3000)
    {
        var empty = new FilePreview { Path = relativePath };
        var root = Normalized(cwd);
        string absolute;
        try { absolute = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, relativePath.Replace('/', '\\'))); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return empty; }
        // Regular files only: a pipe or device in the tree would block the read forever.
        if (!absolute.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) return empty;
        using var stream = RegularFile.Open(absolute);
        if (stream is null) return empty;

        byte[] data;
        try
        {
            var buffer = new byte[MaxPreviewBytes + 1];
            int total = 0;
            while (total < buffer.Length)
            {
                int n = stream.Read(buffer, total, buffer.Length - total);
                if (n <= 0) break;
                total += n;
            }
            data = buffer.AsSpan(0, total).ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return empty; }

        if (data.AsSpan(0, Math.Min(8192, data.Length)).IndexOf((byte)0) >= 0)
            return new FilePreview { Path = relativePath, IsBinary = true };
        bool truncated = false;
        if (data.Length > MaxPreviewBytes)
        {
            data = data[..MaxPreviewBytes];
            truncated = true;
        }

        var text = Decode(data);
        var lines = new List<string>(Math.Min(maxLines, 1024));
        foreach (var raw in text.FileLines())
        {
            if (lines.Count >= maxLines) { truncated = true; break; }
            lines.Add(raw);
        }
        return new FilePreview { Path = relativePath, Lines = lines, Truncated = truncated };
    }

    private static readonly UTF8Encoding strictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// UTF-8 (a BOM dropped), tolerating a character cut in half at the end; otherwise ISO Latin-1.
    private static string Decode(byte[] data)
    {
        int start = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
        for (int cut = 0; cut <= 3 && data.Length - start >= cut; cut++)
        {
            try { return strictUtf8.GetString(data, start, data.Length - start - cut); }
            catch (DecoderFallbackException) { }
        }
        return Encoding.Latin1.GetString(data);
    }

    // MARK: Helpers

    /// Drops the tree and .gitignore cached for this folder, when no session uses it any more.
    public static void Forget(string cwd)
    {
        var root = Normalized(cwd);
        lock (treeLock) treeCache.Remove(root);
        lock (rulesLock) rulesCache.Remove(root);
    }

    /// True when both folders key the same cache entry.
    public static bool SameRoot(string a, string b) => string.Equals(Normalized(a), Normalized(b), StringComparison.OrdinalIgnoreCase);

    private static string Normalized(string cwd)
    {
        string p;
        try { p = System.IO.Path.GetFullPath(cwd.Replace('/', '\\')); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { p = cwd; }
        while (p.Length > 3 && p.EndsWith('\\')) p = p[..^1];
        return p;
    }

    /// The folder's last write time, or null when it is not a folder.
    private static DateTime? Stamp(string path)
    {
        try { return Directory.Exists(path) ? Directory.GetLastWriteTimeUtc(path) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
    }
}

/// `fnmatch(3)` for the ignore rules: `*`, `?`, `[...]` (with `!` or `^`, ranges) and `\` escapes.
/// `pathName` is FNM_PATHNAME: wildcards never match '/'. Case-insensitive, as Git for Windows.
public static class Glob
{
    public static bool Match(string pattern, string text, bool pathName) => Match(pattern, 0, text, 0, pathName);

    private static bool Match(string p, int pi, string t, int ti, bool pathName)
    {
        while (pi < p.Length)
        {
            char c = p[pi];
            switch (c)
            {
                case '*':
                {
                    // Runs of stars are one star.
                    while (pi < p.Length && p[pi] == '*') pi++;
                    if (pi == p.Length) return !pathName || t.IndexOf('/', ti) < 0;
                    for (int k = ti; k <= t.Length; k++)
                    {
                        if (Match(p, pi, t, k, pathName)) return true;
                        if (k < t.Length && pathName && t[k] == '/') return false;
                    }
                    return false;
                }
                case '?':
                    if (ti >= t.Length || (pathName && t[ti] == '/')) return false;
                    pi++; ti++;
                    break;
                case '[':
                {
                    if (ti >= t.Length || (pathName && t[ti] == '/')) return false;
                    int end = pi + 1;
                    if (end < p.Length && (p[end] == '!' || p[end] == '^')) end++;
                    if (end < p.Length && p[end] == ']') end++;
                    while (end < p.Length && p[end] != ']') end++;
                    if (end >= p.Length)
                    {
                        // No closing bracket: a literal '['.
                        if (char.ToLowerInvariant(t[ti]) != '[') return false;
                        pi++; ti++;
                        break;
                    }
                    if (!ClassMatches(p, pi + 1, end, t[ti])) return false;
                    pi = end + 1; ti++;
                    break;
                }
                case '\\' when pi + 1 < p.Length:
                    if (ti >= t.Length || char.ToLowerInvariant(t[ti]) != char.ToLowerInvariant(p[pi + 1])) return false;
                    pi += 2; ti++;
                    break;
                default:
                    if (ti >= t.Length || char.ToLowerInvariant(t[ti]) != char.ToLowerInvariant(c)) return false;
                    pi++; ti++;
                    break;
            }
        }
        return ti == t.Length;
    }

    private static bool ClassMatches(string p, int start, int end, char ch)
    {
        bool negate = start < end && (p[start] == '!' || p[start] == '^');
        if (negate) start++;
        char c = char.ToLowerInvariant(ch);
        bool hit = false;
        for (int i = start; i < end; i++)
        {
            char lo = char.ToLowerInvariant(p[i]);
            if (i + 2 < end && p[i + 1] == '-')
            {
                char hi = char.ToLowerInvariant(p[i + 2]);
                if (c >= lo && c <= hi) hit = true;
                i += 2;
            }
            else if (c == lo)
            {
                hit = true;
            }
        }
        return hit != negate;
    }
}
