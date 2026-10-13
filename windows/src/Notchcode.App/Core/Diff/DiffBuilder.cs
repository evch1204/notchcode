// DiffBuilder.cs
// Port of Sources/notchcode/Core/Diff/DiffBuilder.swift.
// Builds the diff a permission request is about, before Claude makes the change.
// The PermissionRequest payload carries the tool input (old and new strings, or the
// whole new content); the file on disk is still the old version, so applying the
// input to it gives real line numbers and surrounding context. A plain Myers line
// diff, no packages. Reads files only; never writes.

using System.IO;
using System.Text;
using Notchcode.UI;

namespace Notchcode.Core;

public static class DiffBuilder
{
    /// Changed lines below this count also fill `snippet`, as the transcript reader does.
    public const int SnippetLimit = 8;
    /// Past this many edit steps the diff gives up on alignment: all old lines out, all new in.
    public const int MaxEditDistance = 4000;
    /// Files larger than this are not read; the diff falls back to the strings alone.
    public const int MaxFileBytes = 4 * 1024 * 1024;

    /// One edit of a MultiEdit call.
    public readonly record struct MultiEditItem(string Old, string New, bool ReplaceAll);

    // MARK: Tools

    public static FileChange ForEdit(string cwd, string filePath, string oldString, string newString, bool replaceAll, bool readsDisk)
    {
        var path = Paths.Relative(filePath, cwd);
        var original = readsDisk ? Read(Paths.Absolute(filePath, cwd)) : null;
        if (original is not null)
        {
            if (Apply(oldString, newString, replaceAll, original) is { } updated)
                return Change(path, "edit", MakeDiff(original, updated));
        }
        else if (oldString.Length == 0)
        {
            // Edit with an empty old_string on a missing file creates it.
            return Change(path, "new", MakeDiff("", newString));
        }
        return Change(path, "edit", MakeDiff(oldString, newString));
    }

    /// Diffs against the file on disk when it exists (kind "write"), else all added (kind "new").
    public static FileChange ForWrite(string cwd, string filePath, string content, bool readsDisk)
    {
        var path = Paths.Relative(filePath, cwd);
        if (readsDisk && Read(Paths.Absolute(filePath, cwd)) is { } original)
            return Change(path, "write", MakeDiff(original, content));
        return Change(path, "new", MakeDiff("", content));
    }

    public static FileChange ForMultiEdit(string cwd, string filePath, IReadOnlyList<MultiEditItem> edits, bool readsDisk)
    {
        var path = Paths.Relative(filePath, cwd);
        var original = readsDisk ? Read(Paths.Absolute(filePath, cwd)) : null;
        // Each edit applies to the result of the one before, as Claude Code does.
        if (original is not null)
        {
            var text = original;
            bool applied = true;
            foreach (var edit in edits)
            {
                if (Apply(edit.Old, edit.New, edit.ReplaceAll, text) is not { } next) { applied = false; break; }
                text = next;
            }
            if (applied) return Change(path, "edit", MakeDiff(original, text));
        }
        if (original is null && edits.Count > 0 && edits[0].Old.Length == 0)
        {
            // The first edit creates the file; the rest apply to what it wrote.
            var text = edits[0].New;
            foreach (var edit in edits.Skip(1))
                text = Apply(edit.Old, edit.New, edit.ReplaceAll, text) ?? text;
            return Change(path, "new", MakeDiff("", text));
        }
        // No file to anchor on: each edit's strings on their own, numbered from 1.
        var combined = new Diff();
        foreach (var edit in edits)
        {
            var part = MakeDiff(edit.Old, edit.New);
            combined.Added += part.Added;
            combined.Removed += part.Removed;
            foreach (var line in part.Lines)
            {
                if (combined.Lines.Count >= Theme.Limits.PatchLines) { combined.Truncated = true; break; }
                combined.Lines.Add(line);
            }
            combined.Truncated = combined.Truncated || part.Truncated;
        }
        return Change(path, "edit", combined);
    }

    // MARK: - Internals

    private sealed class Diff
    {
        public List<DiffLine> Lines = [];
        public int Added;
        public int Removed;
        public bool Truncated;
    }

    private enum OpKind { Equal, Delete, Insert }

    /// Equal(old index, new index), Delete(old index), Insert(new index); 0-based.
    private readonly record struct Op(OpKind Kind, int I, int J)
    {
        public static Op Equal(int i, int j) => new(OpKind.Equal, i, j);
        public static Op Delete(int i) => new(OpKind.Delete, i, 0);
        public static Op Insert(int j) => new(OpKind.Insert, 0, j);
    }

    private static FileChange Change(string path, string kind, Diff diff)
    {
        var changed = diff.Added + diff.Removed;
        return new FileChange
        {
            Path = path,
            Added = diff.Added,
            Removed = diff.Removed,
            Kind = kind,
            Patch = diff.Lines,
            PatchTruncated = diff.Truncated,
            Snippet = !diff.Truncated && changed > 0 && changed < SnippetLimit ? diff.Lines : [],
        };
    }

    private static Diff MakeDiff(string old, string @new)
    {
        var a = SplitLines(old);
        var b = SplitLines(@new);
        var ops = EditScript(a, b);
        return Hunks(ops, a, b, context: 3, cap: Theme.Limits.PatchLines);
    }

    /// Lines of a text: "" is none, a trailing line break does not add an empty line; CRLF counts as one break.
    private static List<string> SplitLines(string text) => text.FileLines();

    /// Myers' O(ND) diff on the part between the common prefix and suffix.
    private static List<Op> EditScript(List<string> a, List<string> b)
    {
        int prefix = 0;
        while (prefix < a.Count && prefix < b.Count && a[prefix] == b[prefix]) prefix++;
        int suffix = 0;
        while (suffix < a.Count - prefix && suffix < b.Count - prefix
               && a[a.Count - 1 - suffix] == b[b.Count - 1 - suffix]) suffix++;

        var ops = new List<Op>(a.Count + b.Count - prefix - suffix);
        for (int i = 0; i < prefix; i++) ops.Add(Op.Equal(i, i));

        // Compare lines as small integers.
        var ids = new Dictionary<string, int>(StringComparer.Ordinal);
        int Id(string s)
        {
            if (ids.TryGetValue(s, out var v)) return v;
            v = ids.Count;
            ids[s] = v;
            return v;
        }
        var x = new int[a.Count - suffix - prefix];
        for (int i = 0; i < x.Length; i++) x[i] = Id(a[prefix + i]);
        var y = new int[b.Count - suffix - prefix];
        for (int j = 0; j < y.Length; j++) y[j] = Id(b[prefix + j]);
        foreach (var op in Myers(x, y))
        {
            ops.Add(op.Kind switch
            {
                OpKind.Equal => Op.Equal(op.I + prefix, op.J + prefix),
                OpKind.Delete => Op.Delete(op.I + prefix),
                _ => Op.Insert(op.J + prefix),
            });
        }

        for (int s = 0; s < suffix; s++)
            ops.Add(Op.Equal(a.Count - suffix + s, b.Count - suffix + s));
        return ops;
    }

    private static List<Op> Myers(int[] a, int[] b)
    {
        int n = a.Length, m = b.Length;
        if (n == 0) return Enumerable.Range(0, m).Select(Op.Insert).ToList();
        if (m == 0) return Enumerable.Range(0, n).Select(Op.Delete).ToList();

        int maxD = Math.Min(n + m, MaxEditDistance);
        int offset = maxD + 1;
        var v = new int[2 * maxD + 3];
        // trace[d] holds v[-(d+1)...(d+1)] as it was at the start of step d.
        var trace = new List<int[]>();
        bool found = false;

        for (int d = 0; d <= maxD && !found; d++)
        {
            var snap = new int[2 * d + 3];
            Array.Copy(v, offset - d - 1, snap, 0, snap.Length);
            trace.Add(snap);
            for (int k = -d; k <= d; k += 2)
            {
                int xx;
                if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    xx = v[offset + k + 1];
                else
                    xx = v[offset + k - 1] + 1;
                int yy = xx - k;
                while (xx < n && yy < m && a[xx] == b[yy]) { xx++; yy++; }
                v[offset + k] = xx;
                if (xx >= n && yy >= m) { found = true; break; }
            }
        }

        if (!found)
        {
            // Too different to align cheaply: replace everything.
            return Enumerable.Range(0, n).Select(Op.Delete).Concat(Enumerable.Range(0, m).Select(Op.Insert)).ToList();
        }

        var ops = new List<Op>();
        int x = n, y = m;
        for (int d = trace.Count - 1; d >= 0; d--)
        {
            var snap = trace[d];
            int At(int kk) => snap[kk + d + 1];
            int k = x - y;
            int prevK = (k == -d || (k != d && At(k - 1) < At(k + 1))) ? k + 1 : k - 1;
            int prevX = d == 0 ? 0 : At(prevK);
            int prevY = d == 0 ? 0 : prevX - prevK;
            while (x > prevX && y > prevY)
            {
                ops.Add(Op.Equal(x - 1, y - 1));
                x--;
                y--;
            }
            if (d > 0)
            {
                if (x == prevX) ops.Add(Op.Insert(y - 1));
                else ops.Add(Op.Delete(x - 1));
            }
            x = prevX;
            y = prevY;
        }
        ops.Reverse();
        return ops;
    }

    /// Groups the edit script into hunks with `context` unchanged lines around each change.
    private static Diff Hunks(List<Op> ops, List<string> a, List<string> b, int context, int cap)
    {
        var output = new Diff();
        var changes = new List<int>();
        for (int i = 0; i < ops.Count; i++) if (ops[i].Kind != OpKind.Equal) changes.Add(i);
        foreach (var i in changes)
        {
            if (ops[i].Kind == OpKind.Delete) output.Removed++; else output.Added++;
        }
        if (changes.Count == 0) return output;

        // Ranges of ops, merged when the gap between changes is small.
        var ranges = new List<(int Lo, int Hi)>();
        int start = Math.Max(0, changes[0] - context);
        int end = Math.Min(ops.Count - 1, changes[0] + context);
        foreach (var i in changes.Skip(1))
        {
            if (i - context <= end + 1)
            {
                end = Math.Min(ops.Count - 1, i + context);
            }
            else
            {
                ranges.Add((start, end));
                start = Math.Max(0, i - context);
                end = Math.Min(ops.Count - 1, i + context);
            }
        }
        ranges.Add((start, end));

        // Old and new line counts before each op, for hunk starts.
        foreach (var (lo, hi) in ranges)
        {
            int oldBefore = 0, newBefore = 0;
            // Count lines before the hunk from the first op that carries an index.
            var first = ops[lo];
            switch (first.Kind)
            {
                case OpKind.Equal: oldBefore = first.I; newBefore = first.J; break;
                case OpKind.Delete: oldBefore = first.I; newBefore = NewIndex(lo, ops); break;
                case OpKind.Insert: newBefore = first.J; oldBefore = OldIndex(lo, ops); break;
            }
            int oldCount = 0, newCount = 0;
            for (int idx = lo; idx <= hi; idx++)
            {
                switch (ops[idx].Kind)
                {
                    case OpKind.Equal: oldCount++; newCount++; break;
                    case OpKind.Delete: oldCount++; break;
                    case OpKind.Insert: newCount++; break;
                }
            }
            int oldStart = oldCount == 0 ? oldBefore : oldBefore + 1;
            int newStart = newCount == 0 ? newBefore : newBefore + 1;
            if (!Append(new DiffLine { Kind = DiffLineKind.Hunk, Text = $"@@ -{oldStart},{oldCount} +{newStart},{newCount} @@" }, output, cap))
                return output;
            for (int idx = lo; idx <= hi; idx++)
            {
                var op = ops[idx];
                var line = op.Kind switch
                {
                    OpKind.Equal => new DiffLine { Kind = DiffLineKind.Context, Text = a[op.I], OldLine = op.I + 1, NewLine = op.J + 1 },
                    OpKind.Delete => new DiffLine { Kind = DiffLineKind.Removed, Text = a[op.I], OldLine = op.I + 1 },
                    _ => new DiffLine { Kind = DiffLineKind.Added, Text = b[op.J], NewLine = op.J + 1 },
                };
                if (!Append(line, output, cap)) return output;
            }
        }
        return output;
    }

    private static bool Append(DiffLine line, Diff diff, int cap)
    {
        if (diff.Lines.Count >= cap)
        {
            diff.Truncated = true;
            return false;
        }
        diff.Lines.Add(line);
        return true;
    }

    /// Old lines consumed before op `index`.
    private static int OldIndex(int index, List<Op> ops)
    {
        for (int idx = index - 1; idx >= 0; idx--)
        {
            var op = ops[idx];
            if (op.Kind != OpKind.Insert) return op.I + 1;
        }
        return 0;
    }

    /// New lines produced before op `index`.
    private static int NewIndex(int index, List<Op> ops)
    {
        for (int idx = index - 1; idx >= 0; idx--)
        {
            var op = ops[idx];
            if (op.Kind != OpKind.Delete) return op.J + 1;
        }
        return 0;
    }

    // MARK: Files

    /// `old` replaced by `new` in `text`: the first occurrence, or all of them. Null when absent.
    private static string? Apply(string old, string @new, bool replaceAll, string text)
    {
        if (old.Length == 0) return null;
        int at = text.IndexOf(old, StringComparison.Ordinal);
        if (at < 0) return null;
        if (replaceAll) return text.Replace(old, @new, StringComparison.Ordinal);
        return string.Concat(text.AsSpan(0, at), @new, text.AsSpan(at + old.Length));
    }

    /// The file's text, or null when missing, not a regular file, too large, or binary.
    /// Runs on the UI thread for a permission request, so a device or pipe (which could
    /// block the read) is refused, and the size cap applies to what a link points at.
    private static string? Read(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        using var stream = RegularFile.Open(path, MaxFileBytes);
        if (stream is null) return null;
        try
        {
            var data = new byte[(int)Math.Min(stream.Length, MaxFileBytes)];
            int read = 0;
            while (read < data.Length)
            {
                int n = stream.Read(data, read, data.Length - read);
                if (n <= 0) break;
                read += n;
            }
            var span = data.AsSpan(0, read);
            if (span[..Math.Min(8192, read)].Contains((byte)0)) return null;
            // A BOM is not part of the text Claude edits.
            if (span.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) span = span[3..];
            try { return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(span); }
            catch (DecoderFallbackException) { return Encoding.Latin1.GetString(span); }
        }
        catch (IOException) { return null; }
    }
}
