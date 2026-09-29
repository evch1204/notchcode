// WordDiff.swift
// Word highlights for the Git tool's reviewer diff: which words changed inside paired
// −/+ lines. A pure algorithm over [DiffLine]; DiffView draws the result.

import Foundation

/// The words that differ between a removed line and the added line that replaced it.
/// Inside each hunk, a run of removed lines followed by a run of added lines is paired
/// line by line (the first removed with the first added, and so on); a line with no
/// partner stays as it is. Each pair is split into whitespace-separated words, and the
/// words outside their longest common subsequence are marked. A pair with no word in
/// common, or longer than `wordDiffMaxTokens`, is left with the line tint alone.
enum WordDiff {
    /// Line index -> character ranges to tint, merged across the spaces between them.
    static func marks(_ lines: [DiffLine]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            for offset in 0..<pairs {
                let old = index + offset
                let new = removedEnd + offset
                if let (a, b) = compare(lines[old].text, lines[new].text) {
                    if !a.isEmpty { result[old] = a }
                    if !b.isEmpty { result[new] = b }
                }
            }
            index = max(addedEnd, index + 1)
        }
        return result
    }

    /// A word or a run of spaces, with its character offsets.
    private struct Token {
        var text: Substring
        var range: Range<Int>
        var isSpace: Bool
    }

    private static func tokens(_ line: String) -> [Token] {
        var out: [Token] = []
        var start = line.startIndex
        var offset = 0
        while start < line.endIndex {
            let space = line[start].isWhitespace
            var end = start
            var length = 0
            while end < line.endIndex, line[end].isWhitespace == space {
                end = line.index(after: end)
                length += 1
            }
            out.append(Token(text: line[start..<end], range: offset..<(offset + length), isSpace: space))
            start = end
            offset += length
        }
        return out
    }

    /// The differing words of each side, or nil when the pair shares no word (or is too long).
    private static func compare(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>])? {
        let a = tokens(old)
        let b = tokens(new)
        let wa = a.indices.filter { !a[$0].isSpace }
        let wb = b.indices.filter { !b[$0].isSpace }
        guard !wa.isEmpty, !wb.isEmpty,
              wa.count <= Theme.Limits.wordDiffMaxTokens, wb.count <= Theme.Limits.wordDiffMaxTokens else { return nil }
        // Longest common subsequence over the words.
        let n = wa.count, m = wb.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[wa[i]].text == b[wb[j]].text
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        guard table[0][0] > 0 else { return nil }
        var keepA = Set<Int>(), keepB = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if a[wa[i]].text == b[wb[j]].text {
                keepA.insert(wa[i]); keepB.insert(wb[j]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (ranges(a, keep: keepA), ranges(b, keep: keepB))
    }

    /// The changed words' ranges; two changed words with only spaces between them become one.
    private static func ranges(_ tokens: [Token], keep: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var pendingSpace: Range<Int>?
        for (index, token) in tokens.enumerated() {
            if token.isSpace {
                pendingSpace = token.range
                continue
            }
            if keep.contains(index) {
                pendingSpace = nil
                continue
            }
            if let last = out.last, let space = pendingSpace, last.upperBound == space.lowerBound {
                out[out.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                out.append(token.range)
            }
            pendingSpace = nil
        }
        return out
    }
}
