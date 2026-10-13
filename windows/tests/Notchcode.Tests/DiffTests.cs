// DiffTests.cs
// The diff parsers and builders: DiffBuilder (permission diffs), UnifiedDiff (the hook's tree
// report, CRLF and NUL headers included), WordDiff (reviewer word highlights).

using System.Text;
using Notchcode.Core;

namespace Notchcode.Tests;

public class DiffTests
{
    // MARK: DiffBuilder

    [Fact]
    public void EditOnDiskGivesRealLineNumbersAndContext()
    {
        var dir = Directory.CreateTempSubdirectory("nc-diff-").FullName;
        try
        {
            var file = Path.Combine(dir, "a.txt");
            File.WriteAllText(file, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n");
            var change = DiffBuilder.ForEdit(dir, file, "four", "FOUR\nfour and a half", replaceAll: false, readsDisk: true);
            Assert.Equal("a.txt", change.Path);
            Assert.Equal("edit", change.Kind);
            Assert.Equal(2, change.Added);
            Assert.Equal(1, change.Removed);
            Assert.Equal("@@ -1,7 +1,8 @@", change.Patch[0].Text);
            var removed = change.Patch.Single(l => l.Kind == DiffLineKind.Removed);
            Assert.Equal("four", removed.Text);
            Assert.Equal(4, removed.OldLine);
            var added = change.Patch.Where(l => l.Kind == DiffLineKind.Added).ToList();
            Assert.Equal(["FOUR", "four and a half"], added.Select(l => l.Text));
            Assert.Equal(4, added[0].NewLine);
            // 3 changed lines: below the snippet limit.
            Assert.Equal(change.Patch, change.Snippet);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void WriteOfAMissingFileIsAllAdded()
    {
        var change = DiffBuilder.ForWrite(@"C:\nowhere", @"C:\nowhere\new.cs", "a\nb\nc\n", readsDisk: true);
        Assert.Equal("new.cs", change.Path);
        Assert.Equal("new", change.Kind);
        Assert.Equal(3, change.Added);
        Assert.Equal("@@ -0,0 +1,3 @@", change.Patch[0].Text);
    }

    [Fact]
    public void MultiEditWithoutAFileDiffsEachEditAlone()
    {
        var change = DiffBuilder.ForMultiEdit("", "x.txt",
            [new("a", "b", false), new("c\nd", "c", false)], readsDisk: false);
        // "a" -> "b" is +1 -1; "c\nd" -> "c" keeps c and drops d: -1.
        Assert.Equal(1, change.Added);
        Assert.Equal(2, change.Removed);
        Assert.Equal(2, change.Patch.Count(l => l.Kind == DiffLineKind.Hunk));
    }

    [Fact]
    public void MyersFindsTheMinimalScript()
    {
        // b goes, x comes: one each, everything else is context.
        var change = DiffBuilder.ForEdit("", "f", "a\nb\nc\nd\ne", "a\nc\nd\nx\ne", false, readsDisk: false);
        Assert.Equal(1, change.Added);
        Assert.Equal(1, change.Removed);
        Assert.Equal(["a", "b", "c", "d", "x", "e"], change.Patch.Skip(1).Select(l => l.Text));
    }

    // MARK: UnifiedDiff

    private const string TwoFiles =
        "diff --git a/src/app.cs b/src/app.cs\r\n" +
        "index 1111111..2222222 100644\r\n" +
        "--- a/src/app.cs\r\n" +
        "+++ b/src/app.cs\r\n" +
        "@@ -1,3 +1,3 @@ class App\r\n" +
        " one\r\n" +
        "-two\r\n" +
        "+TWO\r\n" +
        " three\r\n" +
        "diff --git a/new file.txt b/new file.txt\n" +
        "new file mode 100644\n" +
        "index 0000000..94954ab\n" +
        "--- a/NUL\n" +
        "+++ b/new file.txt\t\n" +
        "@@ -0,0 +1,2 @@\n" +
        "+hello\n" +
        "+world\n" +
        "\\ No newline at end of file\n";

    [Fact]
    public void ParseReadsCrlfAndNulHeaders()
    {
        var files = UnifiedDiff.Parse(TwoFiles);
        Assert.Equal(2, files.Count);
        Assert.Equal("src/app.cs", files[0].Path);
        Assert.Equal(1, files[0].Added);
        Assert.Equal(1, files[0].Removed);
        Assert.DoesNotContain(files[0].Lines, l => l.Text.Contains('\r'));
        Assert.Equal("@@ -1,3 +1,3 @@", files[0].Lines[0].Text);
        Assert.Equal("TWO", files[0].Lines.Single(l => l.Kind == DiffLineKind.Added).Text);
        Assert.Equal("new file.txt", files[1].Path);
        Assert.Equal("new", files[1].Kind);
        Assert.Equal(2, files[1].Added);
        Assert.NotEqual(0, files[1].TextHash);
    }

    [Fact]
    public void ParseReadsTheDevNullFormToo()
    {
        var text = "diff --git a/x.txt b/x.txt\nnew file mode 100644\n--- /dev/null\n+++ b/x.txt\n@@ -0,0 +1 @@\n+hi\n";
        var file = Assert.Single(UnifiedDiff.Parse(text));
        Assert.Equal("x.txt", file.Path);
        Assert.Equal("@@ -0,0 +1,1 @@", file.Lines[0].Text);
        // "diff --git a/NUL b/x.txt" (an unrewritten Windows header): the +++ line names the file.
        var nul = Assert.Single(UnifiedDiff.Parse("diff --git a/NUL b/x.txt\n--- a/NUL\n+++ b/x.txt\n@@ -0,0 +1 @@\n+hi\n"));
        Assert.Equal("x.txt", nul.Path);
    }

    [Fact]
    public void StatusReadsRenamesAndQuotes()
    {
        var entries = UnifiedDiff.Status([" M a.txt", "R  old.txt -> new.txt", "?? \"sp\\303\\251cial.txt\"", "x"]);
        Assert.Equal(3, entries.Count);
        Assert.Equal(new StatusEntry("a.txt", " M", null), entries[0]);
        Assert.Equal(new StatusEntry("new.txt", "R ", "old.txt"), entries[1]);
        Assert.Equal("spécial.txt", entries[2].Path);
    }

    [Fact]
    public void ChangesSeeNewChangedAndRevertedFiles()
    {
        var baseline = UnifiedDiff.Snapshot(new TreeReport
        {
            Root = "C:/repo", Head = "abc",
            Status = [" M src/app.cs", " M gone.txt"],
            Diff = TwoFiles.Replace("new file.txt", "gone.txt").Replace("new file mode 100644\n", ""),
        });
        var after = UnifiedDiff.Snapshot(new TreeReport
        {
            Root = "C:/repo", Head = "abc",
            Status = [" M src/app.cs", "?? new file.txt"],
            Diff = TwoFiles,
        });
        var changes = UnifiedDiff.Changes(baseline, after, @"C:\repo");
        Assert.Equal(["new file.txt", "gone.txt"], changes.Select(c => c.Path));
        Assert.All(changes, c => Assert.Equal("shell", c.Kind));
        // gone.txt went back to HEAD: the reverse of its diff.
        Assert.Equal(0, changes[1].Added);
        Assert.Equal(2, changes[1].Removed);
        Assert.Equal("@@ -1,2 +0,0 @@", changes[1].Patch[0].Text);
    }

    [Fact]
    public void StagingAloneIsNotAChange()
    {
        var a = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = [" M src/app.cs"], Diff = TwoFiles });
        var b = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = ["M  src/app.cs"], Diff = TwoFiles.Replace("index 1111111..2222222", "index 1111111..3333333") });
        Assert.DoesNotContain(UnifiedDiff.Changes(a, b, @"C:\r"), c => c.Path == "src/app.cs");
    }

    /// Wave 3d: the last file of a report kept its final newline (the exe may send it, the
    /// macOS `$(…)` drops it) and hashed with an extra empty line, so once another file
    /// followed it, it read as a shell change it never had.
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void AFileHashesTheSameLastOrNot(bool keepFinalNewline)
    {
        static string File(string path, string added)
            => $"diff --git a/{path} b/{path}\nindex 1..2 100644\n--- a/{path}\n+++ b/{path}\n@@ -1,1 +1,2 @@\n ctx\n+{added}\n";
        string Text(string s) => keepFinalNewline ? s : s.TrimEnd('\n');
        var a = File("a.txt", "one");
        var b = File("b.txt", "two");
        var first = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = [" M a.txt", " M b.txt"], Diff = Text(a + b) });
        var swapped = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = [" M b.txt", " M a.txt"], Diff = Text(b + a) });
        var trimmed = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = [" M a.txt", " M b.txt"], Diff = (a + b).TrimEnd('\n') });
        Assert.Empty(UnifiedDiff.Changes(first, swapped, @"C:\r"));
        Assert.Empty(UnifiedDiff.Changes(swapped, first, @"C:\r"));
        Assert.Empty(UnifiedDiff.Changes(trimmed, first, @"C:\r"));
        Assert.Equal(first.Files["b.txt"].DiffHash, swapped.Files["b.txt"].DiffHash);
        // A real change still counts.
        var edited = UnifiedDiff.Snapshot(new TreeReport { Root = "C:/r", Head = "h", Status = [" M a.txt", " M b.txt"], Diff = Text(a + File("b.txt", "three")) });
        Assert.Equal(["b.txt"], UnifiedDiff.Changes(first, edited, @"C:\r").Select(c => c.Path));
    }

    /// The hook's 256 KB cap cuts bytes, so it can split a UTF-8 sequence: the report still
    /// decodes (U+FFFD for the cut byte) and the cut file counts as having no diff.
    [Fact]
    public void ACapThatSplitsAUtf8SequenceStillDecodes()
    {
        var full = Encoding.UTF8.GetBytes("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\n"
                                          + "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+caf\u00e9\n");
        var cut = full[..^2]; // the last two bytes: the second half of "é" and the newline
        var json = "{\"root\":\"C:/r\",\"head\":\"h\",\"status_b64\":\"" + Convert.ToBase64String(Encoding.UTF8.GetBytes(" M a.txt\n M b.txt"))
                   + "\",\"diff_b64\":\"" + Convert.ToBase64String(cut) + "\",\"truncated\":true}";
        var report = System.Text.Json.JsonSerializer.Deserialize<TreeReport>(json, ContractJson.Options)!;
        Assert.EndsWith("caf\uFFFD", report.Diff);
        var snapshot = UnifiedDiff.Snapshot(report);
        Assert.Equal(1, snapshot.Files["a.txt"].Added);
        Assert.Equal(0, snapshot.Files["b.txt"].DiffHash);
    }

    // MARK: WordDiff

    [Fact]
    public void WordDiffMarksOnlyChangedWords()
    {
        List<DiffLine> lines =
        [
            new() { Kind = DiffLineKind.Hunk, Text = "@@ -1 +1 @@" },
            new() { Kind = DiffLineKind.Removed, Text = "let color = clay  red" },
            new() { Kind = DiffLineKind.Added, Text = "let colour = amber  blue" },
        ];
        var marks = WordDiff.Marks(lines);
        Assert.Equal(new CharRange(4, 9), marks[1][0]);
        Assert.Equal(new CharRange(12, 21), marks[1][1]); // "clay  red" merged across the spaces
        Assert.Equal(new[] { new CharRange(4, 10), new CharRange(13, 24) }, marks[2]);
    }

    [Fact]
    public void WordDiffSkipsPairsWithNothingInCommon()
    {
        List<DiffLine> lines =
        [
            new() { Kind = DiffLineKind.Removed, Text = "alpha beta" },
            new() { Kind = DiffLineKind.Added, Text = "gamma delta" },
        ];
        Assert.Empty(WordDiff.Marks(lines));
    }
}
