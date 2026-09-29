// UnifiedDiff.swift
// Reads the working-tree report a hook sends (git status + `git diff HEAD`, see TreeReport
// in Contract.swift) and finds the files a shell command changed. Pure text parsing: the
// hook script runs git for the tree report, and the Git tool runs it read-only in the app.
//
// A report becomes one FileSnapshot per path. Comparing two snapshots of the same tree
// gives the files that changed in between (new, changed, or back to HEAD), as FileChanges
// of kind "shell" whose diff is the file's whole diff against HEAD, in the same [DiffLine]
// shape the transcript path makes: `@@ -a,b +c,d @@` headers, old and new line numbers,
// capped at 400 lines.

import Foundation

/// One file of a unified diff.
struct FileDiff: Equatable {
    var path: String                // relative to the repository root
    var lines: [DiffLine]           // hunk headers, context, added, removed; capped
    var truncated: Bool             // `lines` stopped at the cap
    var added: Int                  // every added line, capped or not
    var removed: Int
    var textHash: Int               // hash of the diff's body (hunks, or the binary note), not its headers; 0 when none
}

/// What a file looked like in one report: enough to tell whether it changed since.
struct FileSnapshot: Equatable {
    var status: String              // porcelain XY code: " M", "??", "A ", " D", ...
    var added: Int
    var removed: Int
    var diffHash: Int               // hash of its diff's body; 0 when the report had no diff for it
    var lines: [DiffLine] = []      // its parsed diff, so a file that goes back to HEAD can show the reverse
    var truncated = false

    /// The same change as `other`: the same diff body, or, with no diff on either side,
    /// the same status. Staging alone (`git add`) is not a change.
    func sameContent(as other: FileSnapshot) -> Bool {
        if diffHash != 0 || other.diffHash != 0 { return diffHash == other.diffHash }
        return status == other.status
    }
}

/// A report reduced to per-file snapshots, plus the HEAD it was taken against.
struct TreeSnapshot: Equatable {
    var root: String
    var head: String?
    var files: [String: FileSnapshot]
    var order: [String]             // paths in report order
}

enum UnifiedDiff {
    static let patchLimit = 400

    // MARK: Parsing

    /// Splits a multi-file unified diff (`diff --git` sections) into per-file entries.
    static func parse(_ text: String, cap: Int = patchLimit) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var raw: [Substring] = []
        var inHunk = false
        var oldLine = 0, newLine = 0

        func finish() {
            guard var file = current else { return }
            file.textHash = raw.isEmpty ? 0 : raw.joined(separator: "\n").hashValue
            if !file.path.isEmpty { files.append(file) }
            current = nil
            raw = []
        }
        func append(_ line: DiffLine) {
            guard current != nil else { return }
            if current!.lines.count >= cap { current!.truncated = true; return }
            current!.lines.append(line)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finish()
                current = FileDiff(path: headerPath(line.dropFirst("diff --git ".count)),
                                   lines: [], truncated: false, added: 0, removed: 0, textHash: 0)
                raw = []
                inHunk = false
                continue
            }
            guard current != nil else { continue }
            // Only the body counts toward the hash: staging a file changes its headers
            // ("index", "new file mode"), not what changed in it.
            if inHunk || line.hasPrefix("@@") || line.hasPrefix("Binary files") { raw.append(line) }
            if line.hasPrefix("@@") {
                guard let header = hunkHeader(line) else { continue }
                inHunk = true
                oldLine = header.oldStart
                newLine = header.newStart
                append(DiffLine(kind: .hunk,
                                text: "@@ -\(header.oldStart),\(header.oldCount) +\(header.newStart),\(header.newCount) @@",
                                oldLine: nil, newLine: nil))
                continue
            }
            if !inHunk {
                // File headers. "+++ b/path" (or "--- a/path" for a deletion) names the file best.
                if line.hasPrefix("+++ "), let path = sidePath(line.dropFirst(4), prefix: "b/") {
                    current!.path = path
                } else if line.hasPrefix("--- "), let path = sidePath(line.dropFirst(4), prefix: "a/"),
                          current!.path.isEmpty {
                    current!.path = path
                }
                continue
            }
            let marker = line.first
            let body = line.isEmpty ? "" : String(line.dropFirst())
            switch marker {
            case "+":
                current!.added += 1
                append(DiffLine(kind: .added, text: body, oldLine: nil, newLine: newLine))
                newLine += 1
            case "-":
                current!.removed += 1
                append(DiffLine(kind: .removed, text: body, oldLine: oldLine, newLine: nil))
                oldLine += 1
            case " ":
                append(DiffLine(kind: .context, text: body, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            default:
                break   // "\ No newline at end of file", or the empty tail after the last newline
            }
        }
        finish()
        return files
    }

    /// Porcelain v1 status lines as (path, code), in order. A rename's path is its new name.
    static func status(_ lines: [String]) -> [(path: String, code: String)] {
        lines.compactMap { line in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2))
            var rest = Substring(line.dropFirst(3))
            if let arrow = rest.range(of: " -> ") { rest = rest[arrow.upperBound...] }
            return (unquote(rest), code)
        }
    }

    // MARK: Snapshots

    static func snapshot(_ report: TreeReport) -> TreeSnapshot {
        var files: [String: FileSnapshot] = [:]
        var order: [String] = []
        var diffs = parse(report.diff)
        // The hook's cap cut the last file mid-way; where it cuts moves with every other
        // change, so that file counts as having no diff rather than flapping.
        if report.truncated, !diffs.isEmpty { diffs.removeLast() }
        var byPath: [String: FileDiff] = [:]
        for diff in diffs where byPath[diff.path] == nil { byPath[diff.path] = diff }
        for entry in status(report.status) where files[entry.path] == nil {
            let diff = byPath[entry.path]
            files[entry.path] = FileSnapshot(
                status: entry.code,
                added: diff?.added ?? 0,
                removed: diff?.removed ?? 0,
                diffHash: diff?.textHash ?? 0,
                lines: diff?.lines ?? [],
                truncated: diff?.truncated ?? false
            )
            order.append(entry.path)
        }
        // A diffed file the status did not list (should not happen): keep it anyway.
        for diff in diffs where files[diff.path] == nil {
            files[diff.path] = FileSnapshot(status: " M", added: diff.added, removed: diff.removed,
                                            diffHash: diff.textHash, lines: diff.lines, truncated: diff.truncated)
            order.append(diff.path)
        }
        return TreeSnapshot(root: report.root, head: report.head, files: files, order: order)
    }

    /// Files whose snapshot differs between `old` and `new`, as kind "shell" changes, paths
    /// made relative to `cwd` when inside it. New and changed files first (report order),
    /// then files that went back to HEAD. When HEAD moved in between (a commit), files that
    /// simply left the list were committed, not changed, and are skipped.
    static func changes(from old: TreeSnapshot, to new: TreeSnapshot, cwd: String) -> [FileChange] {
        var out: [FileChange] = []
        for path in new.order {
            guard let now = new.files[path] else { continue }
            if let was = old.files[path], was.sameContent(as: now) { continue }
            out.append(change(path: absolute(path, root: new.root), cwd: cwd,
                              added: now.added, removed: now.removed, lines: now.lines, truncated: now.truncated))
        }
        guard old.root == new.root, old.head == new.head else { return out }
        for path in old.order where new.files[path] == nil {
            guard let was = old.files[path] else { continue }
            // Back to HEAD: the reverse of the diff it had.
            out.append(change(path: absolute(path, root: new.root), cwd: cwd,
                              added: was.removed, removed: was.added, lines: was.lines.map(reversed), truncated: was.truncated))
        }
        return out
    }

    static func absolute(_ path: String, root: String) -> String {
        path.hasPrefix("/") || root.isEmpty ? path : (root.hasSuffix("/") ? root : root + "/") + path
    }

    // MARK: - Internals

    private static func change(path: String, cwd: String, added: Int, removed: Int,
                               lines: [DiffLine], truncated: Bool) -> FileChange {
        var file = FileChange(path: relative(path, cwd: cwd), added: added, removed: removed, kind: "shell")
        file.patch = lines
        file.patchTruncated = truncated
        file.snippet = Array(lines.prefix(DiffBuilder.snippetLimit))
        return file
    }

    private static func reversed(_ line: DiffLine) -> DiffLine {
        switch line.kind {
        case .added: return DiffLine(kind: .removed, text: line.text, oldLine: line.newLine, newLine: nil)
        case .removed: return DiffLine(kind: .added, text: line.text, oldLine: nil, newLine: line.oldLine)
        case .context: return DiffLine(kind: .context, text: line.text, oldLine: line.newLine, newLine: line.oldLine)
        case .hunk:
            guard let h = hunkHeader(Substring(line.text)) else { return line }
            return DiffLine(kind: .hunk, text: "@@ -\(h.newStart),\(h.newCount) +\(h.oldStart),\(h.oldCount) @@",
                            oldLine: nil, newLine: nil)
        }
    }

    private static func relative(_ path: String, cwd: String) -> String {
        guard !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// "@@ -a,b +c,d @@ context" -> the four numbers; a missing count is 1.
    private static func hunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = nums.first.flatMap({ Int($0) }) else { return nil }
            let count = nums.count > 1 ? Int(nums[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// The path in "a/P b/P" (same name both sides, as `--no-renames` gives), or quoted forms.
    private static func headerPath(_ rest: Substring) -> String {
        if rest.hasPrefix("\"") {
            // "a/..." "b/...": take the second quoted name.
            if let split = rest.range(of: "\" \"") {
                return strip(unquote(rest[rest.index(before: split.upperBound)...]), prefix: "b/")
            }
            return ""
        }
        let length = (rest.count - 5) / 2
        guard length > 0, rest.hasPrefix("a/") else { return "" }
        return String(rest.dropFirst(2).prefix(length))
    }

    /// The path of a "--- a/P" / "+++ b/P" line, or nil for /dev/null. Git ends a name that
    /// holds a space with a tab.
    private static func sidePath(_ rest: Substring, prefix: String) -> String? {
        var name = rest
        while name.last == "\t" { name = name.dropLast() }
        let path = unquote(name)
        guard path != "/dev/null" else { return nil }
        return strip(path, prefix: prefix)
    }

    private static func strip(_ path: String, prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Git's C-style quoting: "a\tb\303\251" -> the name. Unquoted text comes back as is.
    static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        var bytes: [UInt8] = []
        var chars = Array(text.dropFirst().dropLast().utf8)[...]
        while let c = chars.popFirst() {
            guard c == UInt8(ascii: "\\"), let next = chars.popFirst() else { bytes.append(c); continue }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let d = chars.first, d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") else { break }
                    value = value * 8 + Int(d - UInt8(ascii: "0"))
                    chars = chars.dropFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
