// DiffBuilder.swift
// Builds the diff a permission request is about, before Claude makes the change.
// The PermissionRequest payload carries the tool input (old and new strings, or the
// whole new content); the file on disk is still the old version, so applying the
// input to it gives real line numbers and surrounding context. A plain Myers line
// diff, no packages. Reads files only; never writes.

import Foundation

enum DiffBuilder {
    /// Changed lines below this count also fill `snippet`, as the transcript reader does.
    static let snippetLimit = 8
    /// Past this many edit steps the diff gives up on alignment: all old lines out, all new in.
    static let maxEditDistance = 4000
    /// Files larger than this are not read; the diff falls back to the strings alone.
    static let maxFileBytes = 4 * 1024 * 1024

    // MARK: Line diff

    /// A unified line diff of two texts: `@@ -a,b +c,d @@` hunk headers, then context,
    /// removed and added lines with old and new line numbers. At most `cap` lines
    /// (then `truncated`). Line numbers start at 1.
    static func lines(old: String, new: String, context: Int = 3, cap: Int = 400) -> (lines: [DiffLine], truncated: Bool) {
        let result = diff(old: old, new: new, context: context, cap: cap)
        return (result.lines, result.truncated)
    }

    // MARK: Tools

    static func forEdit(cwd: String, filePath: String, oldString: String, newString: String, replaceAll: Bool) -> FileChange {
        forEdit(cwd: cwd, filePath: filePath, oldString: oldString, newString: newString, replaceAll: replaceAll, readsDisk: true)
    }

    static func forEdit(cwd: String, filePath: String, oldString: String, newString: String, replaceAll: Bool, readsDisk: Bool) -> FileChange {
        let path = Paths.relative(filePath, cwd: cwd)
        let original = readsDisk ? read(Paths.absolute(filePath, cwd: cwd)) : nil
        if let original {
            if let updated = apply(old: oldString, new: newString, replaceAll: replaceAll, to: original) {
                return change(path: path, kind: "edit", diff: diff(old: original, new: updated))
            }
        } else if oldString.isEmpty {
            // Edit with an empty old_string on a missing file creates it.
            return change(path: path, kind: "new", diff: diff(old: "", new: newString))
        }
        return change(path: path, kind: "edit", diff: diff(old: oldString, new: newString))
    }

    /// Diffs against the file on disk when it exists (kind "write"), else all added (kind "new").
    static func forWrite(cwd: String, filePath: String, content: String) -> FileChange {
        forWrite(cwd: cwd, filePath: filePath, content: content, readsDisk: true)
    }

    static func forWrite(cwd: String, filePath: String, content: String, readsDisk: Bool) -> FileChange {
        let path = Paths.relative(filePath, cwd: cwd)
        if readsDisk, let original = read(Paths.absolute(filePath, cwd: cwd)) {
            return change(path: path, kind: "write", diff: diff(old: original, new: content))
        }
        return change(path: path, kind: "new", diff: diff(old: "", new: content))
    }

    static func forMultiEdit(cwd: String, filePath: String, edits: [(old: String, new: String, replaceAll: Bool)]) -> FileChange {
        forMultiEdit(cwd: cwd, filePath: filePath, edits: edits, readsDisk: true)
    }

    static func forMultiEdit(cwd: String, filePath: String, edits: [(old: String, new: String, replaceAll: Bool)], readsDisk: Bool) -> FileChange {
        let path = Paths.relative(filePath, cwd: cwd)
        let original = readsDisk ? read(Paths.absolute(filePath, cwd: cwd)) : nil
        // Each edit applies to the result of the one before, as Claude Code does.
        if let original {
            var text = original
            var applied = true
            for edit in edits {
                guard let next = apply(old: edit.old, new: edit.new, replaceAll: edit.replaceAll, to: text) else {
                    applied = false
                    break
                }
                text = next
            }
            if applied {
                return change(path: path, kind: "edit", diff: diff(old: original, new: text))
            }
        }
        if original == nil, let first = edits.first, first.old.isEmpty {
            // The first edit creates the file; the rest apply to what it wrote.
            var text = first.new
            for edit in edits.dropFirst() {
                text = apply(old: edit.old, new: edit.new, replaceAll: edit.replaceAll, to: text) ?? text
            }
            return change(path: path, kind: "new", diff: diff(old: "", new: text))
        }
        // No file to anchor on: each edit's strings on their own, numbered from 1.
        var combined = Diff()
        for edit in edits {
            let part = diff(old: edit.old, new: edit.new)
            combined.added += part.added
            combined.removed += part.removed
            for line in part.lines {
                if combined.lines.count >= EditCap.lines { combined.truncated = true; break }
                combined.lines.append(line)
            }
            combined.truncated = combined.truncated || part.truncated
        }
        return change(path: path, kind: "edit", diff: combined)
    }

    // MARK: - Internals

    private enum EditCap { static let lines = 400 }

    private struct Diff {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
        var truncated = false
    }

    private enum Op {
        case equal(Int, Int)    // old index, new index (0-based)
        case delete(Int)
        case insert(Int)
    }

    private static func change(path: String, kind: String, diff: Diff) -> FileChange {
        var file = FileChange(path: path, added: diff.added, removed: diff.removed, kind: kind)
        file.patch = diff.lines
        file.patchTruncated = diff.truncated
        let changed = diff.added + diff.removed
        if !diff.truncated, changed > 0, changed < snippetLimit {
            file.snippet = diff.lines
        }
        return file
    }

    private static func diff(old: String, new: String, context: Int = 3, cap: Int = EditCap.lines) -> Diff {
        let a = splitLines(old)
        let b = splitLines(new)
        let ops = editScript(a, b)
        return hunks(ops: ops, a: a, b: b, context: context, cap: cap)
    }

    /// Lines of a text: "" is none, a trailing line break does not add an empty line; CRLF counts as one break.
    private static func splitLines(_ text: String) -> [String] {
        text.fileLines.map(String.init)
    }

    /// Myers' O(ND) diff on the part between the common prefix and suffix.
    private static func editScript(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        var ops: [Op] = []
        ops.reserveCapacity(a.count + b.count - prefix - suffix)
        for i in 0..<prefix { ops.append(.equal(i, i)) }

        // Compare lines as small integers.
        var ids: [String: Int] = [:]
        func id(_ s: String) -> Int {
            if let v = ids[s] { return v }
            let v = ids.count
            ids[s] = v
            return v
        }
        let x = a[prefix..<(a.count - suffix)].map(id)
        let y = b[prefix..<(b.count - suffix)].map(id)
        for op in myers(x, y) {
            switch op {
            case .equal(let i, let j): ops.append(.equal(i + prefix, j + prefix))
            case .delete(let i): ops.append(.delete(i + prefix))
            case .insert(let j): ops.append(.insert(j + prefix))
            }
        }

        for s in 0..<suffix {
            ops.append(.equal(a.count - suffix + s, b.count - suffix + s))
        }
        return ops
    }

    private static func myers(_ a: [Int], _ b: [Int]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }

        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // trace[d] holds v[-(d+1)...(d+1)] as it was at the start of step d.
        var trace: [[Int]] = []
        var found = false

        search: for d in 0...maxD {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    found = true
                    break search
                }
            }
        }

        guard found else {
            // Too different to align cheaply: replace everything.
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }

        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let snap = trace[d]
            func at(_ k: Int) -> Int { snap[k + d + 1] }
            let k = x - y
            let prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : at(prevK)
            let prevY = d == 0 ? 0 : prevX - prevK
            while x > prevX, y > prevY {
                ops.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX {
                    ops.append(.insert(y - 1))
                } else {
                    ops.append(.delete(x - 1))
                }
            }
            x = prevX
            y = prevY
        }
        return ops.reversed()
    }

    /// Groups the edit script into hunks with `context` unchanged lines around each change.
    private static func hunks(ops: [Op], a: [String], b: [String], context: Int, cap: Int) -> Diff {
        var out = Diff()
        let changes = ops.indices.filter {
            if case .equal = ops[$0] { return false }
            return true
        }
        for i in changes {
            if case .delete = ops[i] { out.removed += 1 } else { out.added += 1 }
        }
        guard !changes.isEmpty else { return out }

        // Ranges of ops, merged when the gap between changes is small.
        var ranges: [ClosedRange<Int>] = []
        var start = max(0, changes[0] - context)
        var end = min(ops.count - 1, changes[0] + context)
        for i in changes.dropFirst() {
            if i - context <= end + 1 {
                end = min(ops.count - 1, i + context)
            } else {
                ranges.append(start...end)
                start = max(0, i - context)
                end = min(ops.count - 1, i + context)
            }
        }
        ranges.append(start...end)

        // Old and new line counts before each op, for hunk starts.
        for range in ranges {
            var oldBefore = 0, newBefore = 0
            // Count lines before the hunk from the first op that carries an index.
            switch ops[range.lowerBound] {
            case .equal(let i, let j): oldBefore = i; newBefore = j
            case .delete(let i):
                oldBefore = i
                newBefore = newIndex(before: range.lowerBound, ops: ops)
            case .insert(let j):
                newBefore = j
                oldBefore = oldIndex(before: range.lowerBound, ops: ops)
            }
            var oldCount = 0, newCount = 0
            for idx in range {
                switch ops[idx] {
                case .equal: oldCount += 1; newCount += 1
                case .delete: oldCount += 1
                case .insert: newCount += 1
                }
            }
            let oldStart = oldCount == 0 ? oldBefore : oldBefore + 1
            let newStart = newCount == 0 ? newBefore : newBefore + 1
            if !append(DiffLine(kind: .hunk, text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                                oldLine: nil, newLine: nil), to: &out, cap: cap) { return out }
            for idx in range {
                let line: DiffLine
                switch ops[idx] {
                case .equal(let i, let j):
                    line = DiffLine(kind: .context, text: a[i], oldLine: i + 1, newLine: j + 1)
                case .delete(let i):
                    line = DiffLine(kind: .removed, text: a[i], oldLine: i + 1, newLine: nil)
                case .insert(let j):
                    line = DiffLine(kind: .added, text: b[j], oldLine: nil, newLine: j + 1)
                }
                if !append(line, to: &out, cap: cap) { return out }
            }
        }
        return out
    }

    private static func append(_ line: DiffLine, to diff: inout Diff, cap: Int) -> Bool {
        guard diff.lines.count < cap else {
            diff.truncated = true
            return false
        }
        diff.lines.append(line)
        return true
    }

    /// Old lines consumed before op `index`.
    private static func oldIndex(before index: Int, ops: [Op]) -> Int {
        for idx in stride(from: index - 1, through: 0, by: -1) {
            switch ops[idx] {
            case .equal(let i, _), .delete(let i): return i + 1
            case .insert: continue
            }
        }
        return 0
    }

    /// New lines produced before op `index`.
    private static func newIndex(before index: Int, ops: [Op]) -> Int {
        for idx in stride(from: index - 1, through: 0, by: -1) {
            switch ops[idx] {
            case .equal(_, let j), .insert(let j): return j + 1
            case .delete: continue
            }
        }
        return 0
    }

    // MARK: Files

    /// `old` replaced by `new` in `text`: the first occurrence, or all of them. Nil when absent.
    private static func apply(old: String, new: String, replaceAll: Bool, to text: String) -> String? {
        guard !old.isEmpty, let range = text.range(of: old, options: .literal) else { return nil }
        if replaceAll {
            return text.replacingOccurrences(of: old, with: new, options: .literal)
        }
        return text.replacingCharacters(in: range, with: new)
    }

    /// The file's text, or nil when missing, not a regular file, too large, or binary.
    /// Runs on the main thread for a permission request, so a FIFO or device (which would
    /// block the read forever) is refused, and the size cap applies to what a symlink points at.
    private static func read(_ path: String) -> String? {
        guard !path.isEmpty, let handle = RegularFile.open(path, maxBytes: maxFileBytes) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes) ?? Data() else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
