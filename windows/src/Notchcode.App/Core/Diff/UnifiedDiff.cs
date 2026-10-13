// UnifiedDiff.cs
// Port of Sources/notchcode/Core/Diff/UnifiedDiff.swift.
// Reads the working-tree report a hook sends (git status + `git diff HEAD`, see TreeReport
// in Contract.cs) and finds the files a shell command changed. Pure text parsing: the
// hook exe runs git for the tree report, and the Git tool runs it read-only in the app.
//
// A report becomes one FileSnapshot per path. Comparing two snapshots of the same tree
// gives the files that changed in between (new, changed, or back to HEAD), as FileChanges
// of kind "shell" whose diff is the file's whole diff against HEAD, in the same DiffLine
// shape the transcript path makes: `@@ -a,b +c,d @@` headers, old and new line numbers,
// capped at 400 lines.
//
// Windows: CRLF line endings are line breaks, never text; an untracked file diffed against
// `NUL` (Git for Windows) reads like one diffed against /dev/null, whether or not the hook
// rewrote the `a/NUL` header.

using System.Text;
using Notchcode.UI;

namespace Notchcode.Core;

/// One file of a unified diff.
public sealed record FileDiff
{
    /// relative to the repository root
    public string Path { get; init; } = "";
    /// hunk headers, context, added, removed; capped
    public IReadOnlyList<DiffLine> Lines { get; init; } = [];
    /// `Lines` stopped at the cap
    public bool Truncated { get; init; }
    /// every added line, capped or not
    public int Added { get; init; }
    public int Removed { get; init; }
    /// hash of the diff's body (hunks, or the binary note), not its headers; 0 when none
    public int TextHash { get; init; }
    /// "new" or "deleted" from the file header's mode line, else null
    public string? Kind { get; init; }

    public bool Equals(FileDiff? o)
        => o is not null && Path == o.Path && Lines.SequenceEqual(o.Lines) && Truncated == o.Truncated
           && Added == o.Added && Removed == o.Removed && TextHash == o.TextHash && Kind == o.Kind;

    public override int GetHashCode() => HashCode.Combine(Path, Lines.Count, Added, Removed, TextHash);
}

/// What a file looked like in one report: enough to tell whether it changed since.
public sealed record FileSnapshot
{
    /// porcelain XY code: " M", "??", "A ", " D", ...
    public string Status { get; init; } = "";
    public int Added { get; init; }
    public int Removed { get; init; }
    /// hash of its diff's body; 0 when the report had no diff for it
    public int DiffHash { get; init; }
    /// its parsed diff, so a file that goes back to HEAD can show the reverse
    public IReadOnlyList<DiffLine> Lines { get; init; } = [];
    public bool Truncated { get; init; }

    /// The same change as `other`: the same diff body, or, with no diff on either side,
    /// the same status. Staging alone (`git add`) is not a change.
    public bool SameContent(FileSnapshot other)
    {
        if (DiffHash != 0 || other.DiffHash != 0) return DiffHash == other.DiffHash;
        return Status == other.Status;
    }

    public bool Equals(FileSnapshot? o)
        => o is not null && Status == o.Status && Added == o.Added && Removed == o.Removed
           && DiffHash == o.DiffHash && Lines.SequenceEqual(o.Lines) && Truncated == o.Truncated;

    public override int GetHashCode() => HashCode.Combine(Status, Added, Removed, DiffHash);
}

/// A report reduced to per-file snapshots, plus the HEAD it was taken against.
public sealed record TreeSnapshot
{
    public string Root { get; init; } = "";
    public string? Head { get; init; }
    public IReadOnlyDictionary<string, FileSnapshot> Files { get; init; } = new Dictionary<string, FileSnapshot>();
    /// paths in report order
    public IReadOnlyList<string> Order { get; init; } = [];

    public bool Equals(TreeSnapshot? o)
    {
        if (o is null || Root != o.Root || Head != o.Head || !Order.SequenceEqual(o.Order) || Files.Count != o.Files.Count)
            return false;
        foreach (var (k, v) in Files)
            if (!o.Files.TryGetValue(k, out var w) || !v.Equals(w)) return false;
        return true;
    }

    public override int GetHashCode() => HashCode.Combine(Root, Head, Files.Count);
}

/// One porcelain status entry. `RenamedFrom` is a rename's or copy's old name.
public readonly record struct StatusEntry(string Path, string Code, string? RenamedFrom);

public static class UnifiedDiff
{
    // MARK: Parsing

    private sealed class Building
    {
        public string Path = "";
        public List<DiffLine> Lines = [];
        public bool Truncated;
        public int Added;
        public int Removed;
        public string? Kind;
    }

    /// Splits a multi-file unified diff (`diff --git` sections) into per-file entries.
    public static List<FileDiff> Parse(string text)
    {
        int cap = Theme.Limits.PatchLines;
        var files = new List<FileDiff>();
        Building? current = null;
        var raw = new List<string>();
        bool inHunk = false;
        int oldLine = 0, newLine = 0;

        void Finish()
        {
            if (current is null) return;
            // Every body line has a marker, so empty lines at the end are only the text's
            // final newline: the hook's `$(…)` drops it (macOS), a report kept whole has it.
            // Either way a file hashes the same, last in the report or not.
            while (raw.Count > 0 && raw[^1].Length == 0) raw.RemoveAt(raw.Count - 1);
            int hash = raw.Count == 0 ? 0 : BodyHash(string.Join("\n", raw));
            if (current.Path.Length > 0)
            {
                files.Add(new FileDiff
                {
                    Path = current.Path,
                    Lines = current.Lines,
                    Truncated = current.Truncated,
                    Added = current.Added,
                    Removed = current.Removed,
                    TextHash = hash,
                    Kind = current.Kind,
                });
            }
            current = null;
            raw = [];
        }
        void Append(DiffLine line)
        {
            if (current is null) return;
            if (current.Lines.Count >= cap) { current.Truncated = true; return; }
            current.Lines.Add(line);
        }

        // Git's lines end at "\n"; a CRLF file's "\r" is part of the break, not the text.
        foreach (var line in text.SplitLines(breaksOnLoneCR: false))
        {
            if (line.StartsWith("diff --git ", StringComparison.Ordinal))
            {
                Finish();
                current = new Building { Path = HeaderPath(line["diff --git ".Length..]) };
                raw = [];
                inHunk = false;
                continue;
            }
            if (current is null) continue;
            // Only the body counts toward the hash: staging a file changes its headers
            // ("index", "new file mode"), not what changed in it.
            if (inHunk || line.StartsWith("@@", StringComparison.Ordinal) || line.StartsWith("Binary files", StringComparison.Ordinal))
                raw.Add(line);
            if (line.StartsWith("@@", StringComparison.Ordinal))
            {
                if (HunkHeader(line) is not { } header) continue;
                inHunk = true;
                oldLine = header.OldStart;
                newLine = header.NewStart;
                Append(new DiffLine
                {
                    Kind = DiffLineKind.Hunk,
                    Text = $"@@ -{header.OldStart},{header.OldCount} +{header.NewStart},{header.NewCount} @@",
                });
                continue;
            }
            if (!inHunk)
            {
                // File headers. "+++ b/path" (or "--- a/path" for a deletion) names the file best.
                if (line.StartsWith("new file mode ", StringComparison.Ordinal))
                    current.Kind = "new";
                else if (line.StartsWith("deleted file mode ", StringComparison.Ordinal))
                    current.Kind = "deleted";
                else if (line.StartsWith("+++ ", StringComparison.Ordinal) && SidePath(line[4..], "b/") is { } bPath)
                    current.Path = bPath;
                else if (line.StartsWith("--- ", StringComparison.Ordinal) && SidePath(line[4..], "a/") is { } aPath
                         && current.Path.Length == 0)
                    current.Path = aPath;
                continue;
            }
            char marker = line.Length > 0 ? line[0] : '\0';
            var body = line.Length == 0 ? "" : line[1..];
            switch (marker)
            {
                case '+':
                    current.Added++;
                    Append(new DiffLine { Kind = DiffLineKind.Added, Text = body, NewLine = newLine });
                    newLine++;
                    break;
                case '-':
                    current.Removed++;
                    Append(new DiffLine { Kind = DiffLineKind.Removed, Text = body, OldLine = oldLine });
                    oldLine++;
                    break;
                case ' ':
                    Append(new DiffLine { Kind = DiffLineKind.Context, Text = body, OldLine = oldLine, NewLine = newLine });
                    oldLine++;
                    newLine++;
                    break;
                default:
                    break; // "\ No newline at end of file", or the empty tail after the last newline
            }
        }
        Finish();
        return files;
    }

    /// Porcelain v1 status lines as (path, code, renamedFrom), in order. A rename's or copy's
    /// path is its new name and `RenamedFrom` its old one (`R  old -> new`); null otherwise.
    public static List<StatusEntry> Status(IEnumerable<string> lines)
    {
        var result = new List<StatusEntry>();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd('\r');
            if (line.Length <= 3) continue;
            var code = line[..2];
            var rest = line[3..];
            string? from = null;
            if (code.Contains('R') || code.Contains('C'))
            {
                int arrow = rest.IndexOf(" -> ", StringComparison.Ordinal);
                if (arrow >= 0)
                {
                    from = Unquote(rest[..arrow]);
                    rest = rest[(arrow + 4)..];
                }
            }
            result.Add(new StatusEntry(Unquote(rest), code, from));
        }
        return result;
    }

    // MARK: Snapshots

    public static TreeSnapshot Snapshot(TreeReport report)
    {
        var files = new Dictionary<string, FileSnapshot>();
        var order = new List<string>();
        var diffs = Parse(report.Diff);
        // The hook's cap cut the last file mid-way; where it cuts moves with every other
        // change, so that file counts as having no diff rather than flapping.
        if (report.Truncated && diffs.Count > 0) diffs.RemoveAt(diffs.Count - 1);
        var byPath = new Dictionary<string, FileDiff>();
        foreach (var diff in diffs) byPath.TryAdd(diff.Path, diff);
        foreach (var entry in Status(report.Status))
        {
            if (files.ContainsKey(entry.Path)) continue;
            byPath.TryGetValue(entry.Path, out var diff);
            files[entry.Path] = new FileSnapshot
            {
                Status = entry.Code,
                Added = diff?.Added ?? 0,
                Removed = diff?.Removed ?? 0,
                DiffHash = diff?.TextHash ?? 0,
                Lines = diff?.Lines ?? [],
                Truncated = diff?.Truncated ?? false,
            };
            order.Add(entry.Path);
        }
        // A diffed file the status did not list (should not happen): keep it anyway.
        foreach (var diff in diffs)
        {
            if (files.ContainsKey(diff.Path)) continue;
            files[diff.Path] = new FileSnapshot
            {
                Status = " M",
                Added = diff.Added,
                Removed = diff.Removed,
                DiffHash = diff.TextHash,
                Lines = diff.Lines,
                Truncated = diff.Truncated,
            };
            order.Add(diff.Path);
        }
        return new TreeSnapshot { Root = report.Root, Head = report.Head, Files = files, Order = order };
    }

    /// Files whose snapshot differs between `old` and `new`, as kind "shell" changes, paths
    /// made relative to `cwd` when inside it. New and changed files first (report order),
    /// then files that went back to HEAD. When HEAD moved in between (a commit), files that
    /// simply left the list were committed, not changed, and are skipped.
    public static List<FileChange> Changes(TreeSnapshot old, TreeSnapshot @new, string cwd)
    {
        var output = new List<FileChange>();
        foreach (var path in @new.Order)
        {
            if (!@new.Files.TryGetValue(path, out var now)) continue;
            if (old.Files.TryGetValue(path, out var was) && was.SameContent(now)) continue;
            output.Add(Change(Paths.Absolute(path, @new.Root), cwd, now.Added, now.Removed, now.Lines, now.Truncated));
        }
        if (!SameRoot(old.Root, @new.Root) || old.Head != @new.Head) return output;
        foreach (var path in old.Order)
        {
            if (@new.Files.ContainsKey(path) || !old.Files.TryGetValue(path, out var was)) continue;
            // Back to HEAD: the reverse of the diff it had.
            output.Add(Change(Paths.Absolute(path, @new.Root), cwd, was.Removed, was.Added,
                              was.Lines.Select(Reversed).ToList(), was.Truncated));
        }
        return output;
    }

    // MARK: - Internals

    /// The same repository root; Windows paths ignore case and either slash.
    private static bool SameRoot(string a, string b)
        => string.Equals(a.Replace('\\', '/').TrimEnd('/'), b.Replace('\\', '/').TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

    /// A stable-per-run hash of a diff body; 0 is kept for "no diff".
    private static int BodyHash(string body)
    {
        int h = StringComparer.Ordinal.GetHashCode(body);
        return h == 0 ? 1 : h;
    }

    private static FileChange Change(string path, string cwd, int added, int removed, IReadOnlyList<DiffLine> lines, bool truncated)
        => new()
        {
            Path = Paths.Relative(path, cwd),
            Added = added,
            Removed = removed,
            Kind = "shell",
            Patch = lines,
            PatchTruncated = truncated,
            Snippet = lines.Take(DiffBuilder.SnippetLimit).ToList(),
        };

    private static DiffLine Reversed(DiffLine line)
    {
        switch (line.Kind)
        {
            case DiffLineKind.Added: return new DiffLine { Kind = DiffLineKind.Removed, Text = line.Text, OldLine = line.NewLine };
            case DiffLineKind.Removed: return new DiffLine { Kind = DiffLineKind.Added, Text = line.Text, NewLine = line.OldLine };
            case DiffLineKind.Context: return new DiffLine { Kind = DiffLineKind.Context, Text = line.Text, OldLine = line.NewLine, NewLine = line.OldLine };
            default:
                if (HunkHeader(line.Text) is not { } h) return line;
                return new DiffLine { Kind = DiffLineKind.Hunk, Text = $"@@ -{h.NewStart},{h.NewCount} +{h.OldStart},{h.OldCount} @@" };
        }
    }

    private readonly record struct Header(int OldStart, int OldCount, int NewStart, int NewCount);

    /// "@@ -a,b +c,d @@ context" -> the four numbers; a missing count is 1.
    private static Header? HunkHeader(string line)
    {
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3 || !parts[1].StartsWith('-') || !parts[2].StartsWith('+')) return null;
        static (int, int)? Range(string s)
        {
            var nums = s[1..].Split(',');
            if (!int.TryParse(nums[0], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var start))
                return null;
            int count = 1;
            if (nums.Length > 1 && !int.TryParse(nums[1], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out count))
                count = 1;
            return (start, count);
        }
        if (Range(parts[1]) is not { } old || Range(parts[2]) is not { } @new) return null;
        return new Header(old.Item1, old.Item2, @new.Item1, @new.Item2);
    }

    /// The path in "a/P b/P" (same name both sides, as `--no-renames` gives), or quoted forms.
    private static string HeaderPath(string rest)
    {
        if (rest.StartsWith('"'))
        {
            // "a/..." "b/...": take the second quoted name.
            int split = rest.IndexOf("\" \"", StringComparison.Ordinal);
            if (split >= 0) return Strip(Unquote(rest[(split + 2)..]), "b/");
            return "";
        }
        int length = (rest.Length - 5) / 2;
        if (length <= 0 || !rest.StartsWith("a/", StringComparison.Ordinal)) return "";
        var name = rest.Substring(2, Math.Min(length, rest.Length - 2));
        // `git diff --no-index -- NUL <file>` on Windows: "a/NUL b/<file>" names two different sides.
        return IsNullDevice(name) ? "" : name;
    }

    /// The path of a "--- a/P" / "+++ b/P" line, or null for /dev/null (or NUL, as Git for
    /// Windows writes it for `--no-index` against NUL). Git ends a name that holds a space with a tab.
    private static string? SidePath(string rest, string prefix)
    {
        var name = rest.TrimEnd('\t');
        var path = Unquote(name);
        if (path == "/dev/null") return null;
        var stripped = Strip(path, prefix);
        if (IsNullDevice(stripped) || IsNullDevice(path)) return null;
        return stripped;
    }

    /// "NUL", "nul", "dev/null": the null device as an untracked file's other side.
    private static bool IsNullDevice(string path)
        => string.Equals(path, "NUL", StringComparison.OrdinalIgnoreCase) || path == "dev/null" || path == "/dev/null";

    private static string Strip(string path, string prefix)
        => path.StartsWith(prefix, StringComparison.Ordinal) ? path[prefix.Length..] : path;

    /// Git's C-style quoting: "a\tb\303\251" -> the name. Unquoted text comes back as is.
    public static string Unquote(string text)
    {
        if (text.Length < 2 || text[0] != '"' || text[^1] != '"') return text;
        var input = Encoding.UTF8.GetBytes(text[1..^1]);
        var bytes = new List<byte>(input.Length);
        int i = 0;
        while (i < input.Length)
        {
            byte c = input[i++];
            if (c != (byte)'\\' || i >= input.Length) { bytes.Add(c); continue; }
            byte next = input[i++];
            switch ((char)next)
            {
                case 'n': bytes.Add(10); break;
                case 't': bytes.Add(9); break;
                case 'r': bytes.Add(13); break;
                case 'a': bytes.Add(7); break;
                case 'b': bytes.Add(8); break;
                case 'f': bytes.Add(12); break;
                case 'v': bytes.Add(11); break;
                case >= '0' and <= '7':
                {
                    int value = next - '0';
                    for (int k = 0; k < 2; k++)
                    {
                        if (i >= input.Length || input[i] < '0' || input[i] > '7') break;
                        value = value * 8 + (input[i] - '0');
                        i++;
                    }
                    bytes.Add(unchecked((byte)value));
                    break;
                }
                default: bytes.Add(next); break;
            }
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }
}
