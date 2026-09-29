// RepoFiles.swift
// The session's working directory as a file tree for the Files tab, and a capped text
// preview of one file. Reads the disk directly; never runs git.
//
// Ignored: a fixed list of build and tool folders, plus the patterns in <cwd>/.gitignore
// (common subset: plain names, `dir/`, `*.ext` globs, leading `/`, `**/` prefixes, and
// `a/b` paths, which are anchored like git does). Negations (`!x`) are skipped.

import Foundation
import Darwin

enum RepoFiles {

    static let alwaysIgnored: Set<String> = [
        ".git", "node_modules", "build", "DerivedData", ".build", ".swiftpm", "Pods", "dist", ".DS_Store",
    ]

    // MARK: Tree

    /// Every file and folder under `cwd` that is not ignored, as a tree sorted directories
    /// first, then files, case-insensitively. Walked breadth first, so when more than
    /// `maxEntries` exist the top levels are complete and the deepest folders are left empty.
    /// Cached per cwd for 10 s, and dropped sooner when the top-level folder's mtime changes.
    static func tree(cwd: String, maxEntries: Int = 4000) -> [FileTreeNode] {
        let root = normalized(cwd)
        guard let stamp = FileStamp(path: root) else { return [] }
        let now = Date()

        treeLock.lock()
        if let hit = treeCache[root], hit.mtime == stamp.mtime, hit.maxEntries == maxEntries,
           now.timeIntervalSince(hit.builtAt) < 10 {
            treeLock.unlock()
            return hit.nodes
        }
        treeLock.unlock()

        let nodes = walk(root: root, maxEntries: maxEntries)
        treeLock.lock()
        treeCache[root] = TreeEntry(mtime: stamp.mtime, maxEntries: maxEntries, builtAt: now, nodes: nodes)
        treeLock.unlock()
        return nodes
    }

    private struct TreeEntry {
        var mtime: Double
        var maxEntries: Int
        var builtAt: Date
        var nodes: [FileTreeNode]
    }
    private static let treeLock = NSLock()
    private static var treeCache: [String: TreeEntry] = [:]

    /// Mutable while walking; turned into value-type FileTreeNodes at the end.
    private final class Box {
        let path: String
        let name: String
        let isDirectory: Bool
        var children: [Box] = []
        init(path: String, name: String, isDirectory: Bool) {
            self.path = path; self.name = name; self.isDirectory = isDirectory
        }
        func node() -> FileTreeNode {
            FileTreeNode(path: path, name: name, isDirectory: isDirectory, children: children.map { $0.node() })
        }
    }

    private static func walk(root: String, maxEntries: Int) -> [FileTreeNode] {
        let rules = ignoreRules(cwd: root)
        let fm = FileManager.default
        let top = Box(path: "", name: "", isDirectory: true)
        var queue: [Box] = [top]
        var head = 0
        var count = 0

        while head < queue.count, count < maxEntries {
            let dir = queue[head]; head += 1
            let absolute = dir.path.isEmpty ? root : root + "/" + dir.path
            guard let names = try? fm.contentsOfDirectory(atPath: absolute) else { continue }

            var kids: [Box] = []
            for name in names {
                let rel = dir.path.isEmpty ? name : dir.path + "/" + name
                let isDir = isRealDirectory(absolute + "/" + name)
                if alwaysIgnored.contains(name) || rules.matches(rel, name: name, isDirectory: isDir) { continue }
                kids.append(Box(path: rel, name: name, isDirectory: isDir))
            }
            kids.sort(by: order)
            for kid in kids {
                guard count < maxEntries else { break }
                dir.children.append(kid)
                count += 1
                if kid.isDirectory { queue.append(kid) }
            }
        }
        return top.children.map { $0.node() }
    }

    private static func order(_ a: Box, _ b: Box) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let c = a.name.caseInsensitiveCompare(b.name)
        return c == .orderedSame ? a.name < b.name : c == .orderedAscending
    }

    /// A directory that is not a symlink (symlinked folders are shown as leaves, never followed).
    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Ignore

    struct IgnoreRules {
        struct Rule {
            var pattern: String
            var anchored: Bool      // match against the whole relative path, not just the name
            var directoryOnly: Bool
        }
        var rules: [Rule] = []

        init(text: String) {
            for raw in text.split(whereSeparator: \.isNewline) {
                var p = String(raw)
                while p.hasSuffix(" ") && !p.hasSuffix("\\ ") { p.removeLast() }
                if p.hasSuffix("\r") { p.removeLast() }
                guard !p.isEmpty, !p.hasPrefix("#"), !p.hasPrefix("!") else { continue }
                if p.hasPrefix("\\") { p.removeFirst() }
                var directoryOnly = false
                if p.hasSuffix("/") { directoryOnly = true; p.removeLast() }
                var anchored = false
                if p.hasPrefix("/") { anchored = true; p.removeFirst() }
                while p.hasPrefix("**/") { p.removeFirst(3); anchored = false }
                if p.contains("/") && !p.hasPrefix("**") { anchored = true }
                if p.hasSuffix("/**") { p.removeLast(3); directoryOnly = true }
                guard !p.isEmpty else { continue }
                rules.append(Rule(pattern: p, anchored: anchored, directoryOnly: directoryOnly))
            }
        }

        func matches(_ relativePath: String, name: String, isDirectory: Bool) -> Bool {
            for r in rules {
                if r.directoryOnly && !isDirectory { continue }
                if r.anchored {
                    let flags = r.pattern.contains("**") ? 0 : FNM_PATHNAME
                    if fnmatch(r.pattern, relativePath, flags) == 0 { return true }
                } else if r.pattern.contains("/") {
                    // "**/a/b": the tail may sit at any depth.
                    if fnmatch(r.pattern, relativePath, 0) == 0 || fnmatch("*/" + r.pattern, relativePath, 0) == 0 {
                        return true
                    }
                } else if fnmatch(r.pattern, name, 0) == 0 {
                    return true
                }
            }
            return false
        }
    }

    private static let rulesLock = NSLock()
    private static var rulesCache: [String: (mtime: Double?, rules: IgnoreRules)] = [:]

    /// <cwd>/.gitignore, re-read when its mtime changes.
    private static func ignoreRules(cwd root: String) -> IgnoreRules {
        let path = root + "/.gitignore"
        let mtime = FileStamp(path: path)?.mtime
        rulesLock.lock()
        if let hit = rulesCache[root], hit.mtime == mtime {
            rulesLock.unlock()
            return hit.rules
        }
        rulesLock.unlock()
        let text = mtime == nil ? "" : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        let rules = IgnoreRules(text: text)
        rulesLock.lock()
        rulesCache[root] = (mtime, rules)
        rulesLock.unlock()
        return rules
    }

    // MARK: Preview

    static let maxPreviewBytes = 4 * 1024 * 1024

    /// The file's lines as text, at most `maxLines` (then `truncated`). A file whose first 8 KB
    /// hold a NUL byte is binary: `isBinary` and no lines. Files over 4 MB are read in part and
    /// marked truncated. Paths escaping `cwd` or unreadable files give an empty preview.
    static func preview(cwd: String, relativePath: String, maxLines: Int = 3000) -> FilePreview {
        let empty = FilePreview(path: relativePath, lines: [], truncated: false, isBinary: false)
        let root = normalized(cwd)
        let absolute = URL(fileURLWithPath: root).appendingPathComponent(relativePath).standardizedFileURL.path
        // Regular files only: a FIFO or device in the tree would block the read forever.
        guard absolute.hasPrefix(root + "/"), let handle = RegularFile.open(absolute) else { return empty }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxPreviewBytes + 1) else { return empty }

        let head = data.prefix(8192)
        if head.contains(0) {
            return FilePreview(path: relativePath, lines: [], truncated: false, isBinary: true)
        }
        var truncated = false
        if data.count > maxPreviewBytes {
            data = data.prefix(maxPreviewBytes)
            truncated = true
        }

        let text = decode(data)
        var lines: [String] = []
        lines.reserveCapacity(min(maxLines, 1024))
        for raw in text.fileLines {
            if lines.count >= maxLines { truncated = true; break }
            lines.append(String(raw))
        }
        return FilePreview(path: relativePath, lines: lines, truncated: truncated, isBinary: false)
    }

    /// UTF-8, tolerating a character cut in half at the end; otherwise ISO Latin-1.
    private static func decode(_ data: Data) -> String {
        for cut in 0...3 where data.count >= cut {
            if let s = String(data: data.prefix(data.count - cut), encoding: .utf8) { return s }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Helpers

    /// Drops the tree and .gitignore cached for this folder, when no session uses it any more.
    static func forget(root cwd: String) {
        let root = normalized(cwd)
        treeLock.lock(); treeCache[root] = nil; treeLock.unlock()
        rulesLock.lock(); rulesCache[root] = nil; rulesLock.unlock()
    }

    /// True when both folders key the same cache entry.
    static func sameRoot(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ cwd: String) -> String {
        var p = URL(fileURLWithPath: cwd).standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
