// MarkdownParser.cs
// Port of Sources/notchcode/Features/Files/MarkdownParser.swift.
// Turns a Markdown file's lines into MarkdownView's blocks: headings, paragraphs, lists,
// fenced code, quotes, rules, pipe tables and YAML front matter, with inline styling (bold,
// italic, code spans, strikethrough, links). The Swift version took the inline part from
// AttributedString's inline-only Markdown; WPF has none, so `Inline` is a small parser for
// the same subset.

using System.Text;
using Notchcode.UI;

namespace Notchcode.Features.Files;

[Flags]
public enum InlineStyle { None = 0, Bold = 1, Italic = 2, Code = 4, Strike = 8 }

/// One styled run of inline text; `Link` is the target when the run is a link's text.
public sealed record InlineRun(string Text, InlineStyle Style = InlineStyle.None, string? Link = null);

/// Inline Markdown as runs (Swift's AttributedString).
public sealed record InlineText(IReadOnlyList<InlineRun> Runs)
{
    public static readonly InlineText Empty = new([]);
    public string PlainText => string.Concat(Runs.Select(r => r.Text));

    public bool Equals(InlineText? o) => o is not null && Runs.SequenceEqual(o.Runs);
    public override int GetHashCode() => Runs.Count;
}

/// One item of a list block: its marker ("•", "3."), text and nesting depth (0–3).
public sealed record MarkdownListItem(string Marker, InlineText Text, int Depth);

/// What a block is (`MarkdownBlock.Kind`).
public abstract record MarkdownBlockKind
{
    private MarkdownBlockKind() { }

    public sealed record Heading(int Level, InlineText Text) : MarkdownBlockKind;
    public sealed record Paragraph(InlineText Text) : MarkdownBlockKind;
    public sealed record List(IReadOnlyList<MarkdownListItem> Items) : MarkdownBlockKind;
    public sealed record Code(IReadOnlyList<string> Lines) : MarkdownBlockKind;
    public sealed record Quote(InlineText Text) : MarkdownBlockKind;
    public sealed record Rule : MarkdownBlockKind;
    public sealed record Table(IReadOnlyList<InlineText> Header, IReadOnlyList<IReadOnlyList<InlineText>> Rows) : MarkdownBlockKind;
}

/// One block, numbered in document order.
public sealed record MarkdownBlock(int Id, MarkdownBlockKind Kind);

public static class MarkdownParser
{
    public static List<MarkdownBlock> Parse(IReadOnlyList<string> source)
    {
        var lines = source.Select(l => l.Replace("\t", "    ")).ToList();
        var kinds = new List<MarkdownBlockKind>();
        var paragraph = new List<string>();
        int i = 0;

        void FlushParagraph()
        {
            if (paragraph.Count == 0) return;
            kinds.Add(new MarkdownBlockKind.Paragraph(Inline(string.Join(" ", paragraph))));
            paragraph.Clear();
        }

        // YAML front matter at the very top reads as a code block.
        if (lines.Count > 0 && lines[0].Trim() == "---")
        {
            int end = lines.FindIndex(1, l => l.Trim() == "---");
            if (end > 0)
            {
                kinds.Add(new MarkdownBlockKind.Code(lines.GetRange(0, end + 1)));
                i = end + 1;
            }
        }

        while (i < lines.Count)
        {
            var line = lines[i];
            var trimmed = line.Trim(' ');

            if (trimmed.Length == 0)
            {
                FlushParagraph();
                i++;
                continue;
            }

            // Fenced code: ``` or ~~~ up to the matching fence (or the end of what was read).
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                FlushParagraph();
                var fence = trimmed[..3];
                var body = new List<string>();
                i++;
                while (i < lines.Count && !lines[i].Trim(' ').StartsWith(fence, StringComparison.Ordinal))
                {
                    body.Add(lines[i]);
                    i++;
                }
                i++;
                kinds.Add(new MarkdownBlockKind.Code(body));
                continue;
            }

            // Setext: a line of = or - under paragraph text makes it a heading.
            if (paragraph.Count > 0 && IsUnderline(trimmed))
            {
                int level = trimmed.StartsWith('=') ? 1 : 2;
                kinds.Add(new MarkdownBlockKind.Heading(level, Inline(string.Join(" ", paragraph))));
                paragraph.Clear();
                i++;
                continue;
            }

            if (AtxHeading(trimmed) is { } heading)
            {
                FlushParagraph();
                kinds.Add(new MarkdownBlockKind.Heading(heading.Level, Inline(heading.Text)));
                i++;
                continue;
            }

            if (IsRule(trimmed))
            {
                FlushParagraph();
                kinds.Add(new MarkdownBlockKind.Rule());
                i++;
                continue;
            }

            if (trimmed.StartsWith('>'))
            {
                FlushParagraph();
                var quoted = new List<string>();
                while (i < lines.Count)
                {
                    var t = lines[i].Trim(' ');
                    if (!t.StartsWith('>')) break;
                    var rest = t[1..];
                    if (rest.StartsWith(' ')) rest = rest[1..];
                    quoted.Add(rest);
                    i++;
                }
                // Blank quote lines break paragraphs; the rest joins like prose.
                var paragraphs = new List<string>();
                var current = new List<string>();
                foreach (var q in quoted)
                {
                    if (q.Length == 0)
                    {
                        if (current.Count > 0) paragraphs.Add(string.Join(" ", current));
                        current.Clear();
                    }
                    else
                    {
                        current.Add(q);
                    }
                }
                if (current.Count > 0) paragraphs.Add(string.Join(" ", current));
                kinds.Add(new MarkdownBlockKind.Quote(Inline(string.Join("\n", paragraphs))));
                continue;
            }

            if (trimmed.StartsWith('|') && i + 1 < lines.Count && IsTableSeparator(lines[i + 1]))
            {
                FlushParagraph();
                var header = Cells(trimmed);
                var rows = new List<List<string>>();
                i += 2;
                while (i < lines.Count)
                {
                    var t = lines[i].Trim(' ');
                    if (t.Length == 0 || !t.Contains('|')) break;
                    rows.Add(Cells(t));
                    i++;
                }
                int columns = Math.Max(header.Count, rows.Count == 0 ? 0 : rows.Max(r => r.Count));
                IReadOnlyList<InlineText> Padded(List<string> row)
                    => row.Concat(Enumerable.Repeat("", Math.Max(0, columns - row.Count))).Select(Inline).ToList();
                kinds.Add(new MarkdownBlockKind.Table(Padded(header), rows.Select(Padded).ToList()));
                continue;
            }

            if (ListItem(line) is not null)
            {
                FlushParagraph();
                var items = new List<(string Marker, string Text, int Depth)>();
                while (i < lines.Count)
                {
                    var current = lines[i];
                    var t = current.Trim(' ');
                    if (ListItem(current) is { } item)
                    {
                        items.Add(item);
                        i++;
                    }
                    else if (t.Length == 0)
                    {
                        // A blank line inside a list continues it only if another item follows.
                        if (!(i + 1 < lines.Count && (ListItem(lines[i + 1]) is not null || Indent(lines[i + 1]) >= 2))) break;
                        i++;
                    }
                    else if (Indent(current) >= 2 && items.Count > 0 && !t.StartsWith("```", StringComparison.Ordinal)
                             && !t.StartsWith("~~~", StringComparison.Ordinal))
                    {
                        // An indented continuation line joins the item above.
                        items[^1] = items[^1] with { Text = items[^1].Text + " " + t };
                        i++;
                    }
                    else
                    {
                        break;
                    }
                }
                kinds.Add(new MarkdownBlockKind.List(items.Select(x => new MarkdownListItem(x.Marker, Inline(x.Text), x.Depth)).ToList()));
                continue;
            }

            paragraph.Add(trimmed);
            i++;
        }
        FlushParagraph();
        return kinds.Select((kind, index) => new MarkdownBlock(index, kind)).ToList();
    }

    // MARK: Line tests

    private static int Indent(string line) => line.TakeWhile(c => c == ' ').Count();

    private static (int Level, string Text)? AtxHeading(string trimmed)
    {
        int hashes = trimmed.TakeWhile(c => c == '#').Count();
        if (hashes < 1 || hashes > 6) return null;
        var rest = trimmed[hashes..];
        if (rest.Length > 0 && !rest.StartsWith(' ')) return null;
        var text = rest.Trim(' ');
        // A closing run of #s is decoration.
        while (text.EndsWith('#')) text = text[..^1];
        return (Math.Min(hashes, 4), text.Trim(' '));
    }

    private static bool IsRule(string trimmed)
    {
        var chars = trimmed.Replace(" ", "");
        if (chars.Length < 3 || "-*_".IndexOf(chars[0]) < 0) return false;
        return chars.All(c => c == chars[0]);
    }

    private static bool IsUnderline(string trimmed)
    {
        if (trimmed.Length == 0 || (trimmed[0] != '=' && trimmed[0] != '-')) return false;
        return trimmed.All(c => c == trimmed[0]);
    }

    private static bool IsTableSeparator(string line)
    {
        var t = line.Trim(' ');
        if (!t.Contains('-') || !(t.Contains('|') || t.StartsWith('-') || t.StartsWith(':'))) return false;
        return t.All(c => "|-: ".Contains(c));
    }

    private static List<string> Cells(string trimmed)
    {
        var t = trimmed;
        if (t.StartsWith('|')) t = t[1..];
        if (t.EndsWith('|')) t = t[..^1];
        return t.Split('|').Select(c => c.Trim(' ')).ToList();
    }

    /// "- item", "* item", "+ item", "1. item", "2) item", with the depth from its indent.
    private static (string Marker, string Text, int Depth)? ListItem(string line)
    {
        int depth = Math.Min(Indent(line) / 2, 3);
        var t = line.Trim(' ');
        if (t.Length >= 2 && "-*+".IndexOf(t[0]) >= 0 && t[1] == ' ')
        {
            if (IsRule(t)) return null;
            return (Theme.Glyphs.Bullet, t[2..], depth);
        }
        var digits = new string(t.TakeWhile(char.IsAsciiDigit).ToArray());
        if (digits.Length == 0 || digits.Length > 9) return null;
        var after = t[digits.Length..];
        if (after.Length < 2 || (after[0] != '.' && after[0] != ')') || after[1] != ' ') return null;
        return (digits + ".", after[2..], depth);
    }

    // MARK: Inline

    /// Bold, italic, code, strikethrough and links. Views give code runs the small mono font
    /// on the code fill and links the link colour.
    public static InlineText Inline(string text) => new(Runs(text, InlineStyle.None, null));

    private static List<InlineRun> Runs(string s, InlineStyle style, string? link)
    {
        var runs = new List<InlineRun>();
        var sb = new StringBuilder();
        void Flush()
        {
            if (sb.Length == 0) return;
            runs.Add(new InlineRun(sb.ToString(), style, link));
            sb.Clear();
        }

        int i = 0;
        while (i < s.Length)
        {
            char c = s[i];
            // Backslash escapes.
            if (c == '\\' && i + 1 < s.Length && char.IsPunctuation(s[i + 1]) | char.IsSymbol(s[i + 1]))
            {
                sb.Append(s[i + 1]);
                i += 2;
                continue;
            }
            // Code spans: a run of n backticks up to the next run of exactly n.
            if (c == '`')
            {
                int n = Run(s, i, '`');
                int close = FindRun(s, i + n, '`', n);
                if (close >= 0)
                {
                    Flush();
                    var code = s[(i + n)..close];
                    if (code.Length >= 2 && code.StartsWith(' ') && code.EndsWith(' ')) code = code[1..^1];
                    runs.Add(new InlineRun(code, style | InlineStyle.Code, link));
                    i = close + n;
                    continue;
                }
                sb.Append(s, i, n);
                i += n;
                continue;
            }
            // Links: [text](target).
            if (c == '[' && link is null && LinkAt(s, i) is { } found)
            {
                Flush();
                runs.AddRange(Runs(found.Label, style, found.Target));
                i = found.End;
                continue;
            }
            // Autolinks: <https://…>.
            if (c == '<' && link is null)
            {
                int close = s.IndexOf('>', i + 1);
                if (close > i)
                {
                    var inner = s[(i + 1)..close];
                    if ((inner.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || inner.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                        && !inner.Contains(' '))
                    {
                        Flush();
                        runs.Add(new InlineRun(inner, style, inner));
                        i = close + 1;
                        continue;
                    }
                }
            }
            // Emphasis and strikethrough.
            if (c is '*' or '_' or '~')
            {
                int n = Run(s, i, c);
                string? delimiter = c == '~'
                    ? (n >= 2 ? "~~" : null)
                    : new string(c, Math.Min(n, 3));
                bool opens = delimiter is not null && i + delimiter.Length < s.Length && !char.IsWhiteSpace(s[i + delimiter.Length])
                             && (c != '_' || i == 0 || !char.IsLetterOrDigit(s[i - 1]));
                if (opens)
                {
                    int close = FindCloser(s, i + delimiter!.Length, delimiter);
                    if (close > i + delimiter.Length)
                    {
                        Flush();
                        var flag = c == '~' ? InlineStyle.Strike
                            : delimiter.Length == 1 ? InlineStyle.Italic
                            : delimiter.Length == 2 ? InlineStyle.Bold
                            : InlineStyle.Bold | InlineStyle.Italic;
                        runs.AddRange(Runs(s[(i + delimiter.Length)..close], style | flag, link));
                        i = close + delimiter.Length;
                        continue;
                    }
                }
                sb.Append(s, i, n);
                i += n;
                continue;
            }
            sb.Append(c);
            i++;
        }
        Flush();
        return runs;
    }

    private static int Run(string s, int i, char c)
    {
        int n = 0;
        while (i + n < s.Length && s[i + n] == c) n++;
        return n;
    }

    /// The start of the next run of exactly `n` `c`s at or after `from`, or -1.
    private static int FindRun(string s, int from, char c, int n)
    {
        int i = from;
        while (i < s.Length)
        {
            if (s[i] == c)
            {
                int run = Run(s, i, c);
                if (run == n) return i;
                i += run;
            }
            else
            {
                i++;
            }
        }
        return -1;
    }

    /// The closing `delimiter`: not after whitespace, not part of a longer run, not inside a
    /// code span; for '_' not before a letter or digit.
    private static int FindCloser(string s, int from, string delimiter)
    {
        char c = delimiter[0];
        int i = from;
        while (i < s.Length)
        {
            if (s[i] == '`')
            {
                int n = Run(s, i, '`');
                int close = FindRun(s, i + n, '`', n);
                i = close >= 0 ? close + n : i + n;
                continue;
            }
            if (s[i] == c)
            {
                int run = Run(s, i, c);
                bool afterText = i > from && !char.IsWhiteSpace(s[i - 1]);
                bool wordEnd = c != '_' || i + run >= s.Length || !char.IsLetterOrDigit(s[i + run]);
                if (afterText && wordEnd && run == delimiter.Length) return i;
                if (afterText && wordEnd && run > delimiter.Length && c != '~') return i + run - delimiter.Length;
                i += run;
                continue;
            }
            i++;
        }
        return -1;
    }

    /// `[label](target)` at `i`: the label, the target and the index after the closing ')'.
    private static (string Label, string Target, int End)? LinkAt(string s, int i)
    {
        int depth = 0;
        int j = i;
        for (; j < s.Length; j++)
        {
            if (s[j] == '\\') { j++; continue; }
            if (s[j] == '[') depth++;
            else if (s[j] == ']' && --depth == 0) break;
        }
        if (j >= s.Length || j + 1 >= s.Length || s[j + 1] != '(') return null;
        int k = j + 2;
        int parens = 1;
        for (; k < s.Length; k++)
        {
            if (s[k] == '(') parens++;
            else if (s[k] == ')' && --parens == 0) break;
        }
        if (k >= s.Length) return null;
        var target = s[(j + 2)..k].Trim();
        // An optional title after the target: [x](url "title").
        int space = target.IndexOf(' ');
        if (space > 0) target = target[..space];
        target = target.Trim('<', '>');
        return (s[(i + 1)..j], target, k + 1);
    }
}
