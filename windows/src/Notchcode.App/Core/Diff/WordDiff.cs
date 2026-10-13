// WordDiff.cs
// Port of Sources/notchcode/Core/Diff/WordDiff.swift.
// Word highlights for the Git tool's reviewer diff: which words changed inside paired
// −/+ lines. A pure algorithm over DiffLines; DiffView draws the result.
//
// Offsets are UTF-16 code unit indices into DiffLine.Text (what WPF text runs use); the
// Swift version counts Characters. They agree for every line without surrogate pairs or
// combining marks, and a word is never split either way.

using Notchcode.UI;

namespace Notchcode.Core;

/// A half-open range of character offsets, Swift's `Range<Int>`: `Lower..<Upper`.
public readonly record struct CharRange(int Lower, int Upper)
{
    public int Length => Upper - Lower;
}

/// The words that differ between a removed line and the added line that replaced it.
/// Inside each hunk, a run of removed lines followed by a run of added lines is paired
/// line by line (the first removed with the first added, and so on); a line with no
/// partner stays as it is. Each pair is split into whitespace-separated words, and the
/// words outside their longest common subsequence are marked. A pair with no word in
/// common, or longer than `WordDiffMaxTokens`, is left with the line tint alone.
public static class WordDiff
{
    /// Line index -> character ranges to tint, merged across the spaces between them.
    public static Dictionary<int, IReadOnlyList<CharRange>> Marks(IReadOnlyList<DiffLine> lines)
    {
        var result = new Dictionary<int, IReadOnlyList<CharRange>>();
        int index = 0;
        while (index < lines.Count)
        {
            if (lines[index].Kind != DiffLineKind.Removed) { index++; continue; }
            int removedEnd = index;
            while (removedEnd < lines.Count && lines[removedEnd].Kind == DiffLineKind.Removed) removedEnd++;
            int addedEnd = removedEnd;
            while (addedEnd < lines.Count && lines[addedEnd].Kind == DiffLineKind.Added) addedEnd++;
            int pairs = Math.Min(removedEnd - index, addedEnd - removedEnd);
            for (int offset = 0; offset < pairs; offset++)
            {
                int old = index + offset;
                int @new = removedEnd + offset;
                if (Compare(lines[old].Text, lines[@new].Text) is { } pair)
                {
                    if (pair.A.Count > 0) result[old] = pair.A;
                    if (pair.B.Count > 0) result[@new] = pair.B;
                }
            }
            index = Math.Max(addedEnd, index + 1);
        }
        return result;
    }

    /// A word or a run of spaces, with its character offsets.
    private readonly record struct Token(string Text, CharRange Range, bool IsSpace);

    private static List<Token> Tokens(string line)
    {
        var output = new List<Token>();
        int start = 0;
        while (start < line.Length)
        {
            bool space = char.IsWhiteSpace(line[start]);
            int end = start;
            while (end < line.Length && char.IsWhiteSpace(line[end]) == space) end++;
            output.Add(new Token(line[start..end], new CharRange(start, end), space));
            start = end;
        }
        return output;
    }

    /// The differing words of each side, or null when the pair shares no word (or is too long).
    private static (List<CharRange> A, List<CharRange> B)? Compare(string old, string @new)
    {
        var a = Tokens(old);
        var b = Tokens(@new);
        var wa = Enumerable.Range(0, a.Count).Where(i => !a[i].IsSpace).ToList();
        var wb = Enumerable.Range(0, b.Count).Where(i => !b[i].IsSpace).ToList();
        if (wa.Count == 0 || wb.Count == 0
            || wa.Count > Theme.Limits.WordDiffMaxTokens || wb.Count > Theme.Limits.WordDiffMaxTokens) return null;
        // Longest common subsequence over the words.
        int n = wa.Count, m = wb.Count;
        var table = new int[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
        {
            for (int j = m - 1; j >= 0; j--)
            {
                table[i, j] = a[wa[i]].Text == b[wb[j]].Text
                    ? table[i + 1, j + 1] + 1
                    : Math.Max(table[i + 1, j], table[i, j + 1]);
            }
        }
        if (table[0, 0] <= 0) return null;
        var keepA = new HashSet<int>();
        var keepB = new HashSet<int>();
        {
            int i = 0, j = 0;
            while (i < n && j < m)
            {
                if (a[wa[i]].Text == b[wb[j]].Text)
                {
                    keepA.Add(wa[i]); keepB.Add(wb[j]); i++; j++;
                }
                else if (table[i + 1, j] >= table[i, j + 1])
                {
                    i++;
                }
                else
                {
                    j++;
                }
            }
        }
        return (Ranges(a, keepA), Ranges(b, keepB));
    }

    /// The changed words' ranges; two changed words with only spaces between them become one.
    private static List<CharRange> Ranges(List<Token> tokens, HashSet<int> keep)
    {
        var output = new List<CharRange>();
        CharRange? pendingSpace = null;
        for (int index = 0; index < tokens.Count; index++)
        {
            var token = tokens[index];
            if (token.IsSpace)
            {
                pendingSpace = token.Range;
                continue;
            }
            if (keep.Contains(index))
            {
                pendingSpace = null;
                continue;
            }
            if (output.Count > 0 && pendingSpace is { } space && output[^1].Upper == space.Lower)
                output[^1] = new CharRange(output[^1].Lower, token.Range.Upper);
            else
                output.Add(token.Range);
            pendingSpace = null;
        }
        return output;
    }
}
