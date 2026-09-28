// FilesBrowser.swift
// The Files tab's model: the repository tree from RepoFiles, which folders are open,
// the name filter, the keyboard cursor, the previewed file (remembered per session),
// and which lines of that file this session changed.
//
// Reading only. RepoFiles reads the disk off the main thread; nothing here writes a file.

import AppKit
import SwiftUI

/// One visible row of the tree.
struct TreeRow: Identifiable, Equatable {
    var id: String { node.path }
    var node: FileTreeNode
    var depth: Int
    var isOpen: Bool
    /// Position among its parent's children, for the 40 ms stagger when a folder opens.
    var childIndex: Int
}

/// ±counts of a file across the session's turns.
struct FileChangeCount: Equatable {
    var added: Int
    var removed: Int
}

/// Lines of the current file this session changed. `added` are new-file line numbers;
/// `removedAt` are the lines that now sit where removed lines used to be.
struct ChangeMarks: Equatable {
    var added: Set<Int> = []
    var removedAt: Set<Int> = []
    var isEmpty: Bool { added.isEmpty && removedAt.isEmpty }
    var firstLine: Int? { (added.union(removedAt)).min() }
}

extension AppState {

    // MARK: Tree

    /// The focused session's tree, if read.
    var focusedTree: [FileTreeNode]? {
        guard let cwd = focusedSession?.cwd, !cwd.isEmpty else { return nil }
        return repoTrees[cwd]
    }

    /// Reads the focused session's tree in the background. RepoFiles caches it, so calling
    /// this every time the tab shows is cheap.
    func loadRepoTree() {
        guard let cwd = focusedSession?.cwd, !cwd.isEmpty, !repoTreesLoading.contains(cwd) else { return }
        repoTreesLoading.insert(cwd)
        Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = RepoFiles.tree(cwd: cwd)
            await self?.applyTree(nodes, cwd: cwd)
        }
    }

    private func applyTree(_ nodes: [FileTreeNode], cwd: String) {
        repoTreesLoading.remove(cwd)
        if repoTrees[cwd] != nodes { repoTrees[cwd] = nodes }
        if let sid = focusedSession?.id, focusedSession?.cwd == cwd,
           let path = openedFile[sid], previews[Self.previewKey(cwd: cwd, path: path)] == nil {
            loadPreview(cwd: cwd, path: path)
        }
    }

    static func depth(of path: String) -> Int {
        path.split(separator: "/").count - 1
    }

    /// Top-level folders start open, deeper ones closed; a click or ←/→ flips one.
    func isFolderOpen(_ path: String, sessionId: String) -> Bool {
        let openByDefault = Self.depth(of: path) == 0
        return openByDefault != (treeToggled[sessionId]?.contains(path) ?? false)
    }

    func setFolder(_ path: String, open: Bool, sessionId: String) {
        guard isFolderOpen(path, sessionId: sessionId) != open else { return }
        var set = treeToggled[sessionId] ?? []
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        treeToggled[sessionId] = set
    }

    /// The rows the tree shows right now. With a filter: files whose name contains it, and the
    /// folders above them, all open; a folder whose own name matches keeps its whole subtree.
    func visibleTreeRows() -> [TreeRow] {
        guard let sid = focusedSession?.id, let tree = focusedTree else { return [] }
        let query = fileFilter.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [TreeRow] = []

        func matches(_ node: FileTreeNode) -> Bool {
            node.name.lowercased().contains(query)
        }
        func hasMatch(_ node: FileTreeNode) -> Bool {
            if matches(node) { return true }
            return node.isDirectory && node.children.contains(where: hasMatch)
        }
        func add(_ nodes: [FileTreeNode], depth: Int, filtering: Bool) {
            var index = 0
            for node in nodes {
                if filtering && !hasMatch(node) { continue }
                // Inside a folder whose own name matched, everything below shows normally.
                let keepFiltering = filtering && !matches(node)
                let open: Bool
                if node.isDirectory {
                    open = keepFiltering ? true : isFolderOpen(node.path, sessionId: sid)
                } else {
                    open = false
                }
                rows.append(TreeRow(node: node, depth: depth, isOpen: open, childIndex: index))
                index += 1
                if node.isDirectory && open {
                    add(node.children, depth: depth + 1, filtering: keepFiltering)
                }
            }
        }
        add(tree, depth: 0, filtering: !query.isEmpty)
        return rows
    }

    // MARK: Cursor and keys

    var treeCursorPath: String? {
        focusedSession.flatMap { treeCursor[$0.id] }
    }

    var openedFilePath: String? {
        focusedSession.flatMap { openedFile[$0.id] }
    }

    /// The Files tab's keys. Nil: not a Files key, let the card handle it.
    func handleFilesKey(_ key: NotchKey) -> Bool? {
        guard let sid = focusedSession?.id else { return nil }
        switch key {
        case .filter:
            fileFilterFocused = true
            return true
        case .up, .down:
            let rows = visibleTreeRows()
            guard !rows.isEmpty else { return false }
            let current = rows.firstIndex { $0.id == treeCursor[sid] }
            let next: Int
            if let current {
                next = max(0, min(rows.count - 1, current + (key == .down ? 1 : -1)))
            } else {
                next = key == .down ? 0 : rows.count - 1
            }
            treeCursor[sid] = rows[next].id
            return true
        case .right:
            guard let row = cursorRow(), row.node.isDirectory else { return false }
            if row.isOpen {
                // Already open: step onto its first child, as Finder and Xcode do.
                if let first = visibleTreeRows().first(where: { Self.parent(of: $0.id) == row.id }) {
                    treeCursor[sid] = first.id
                }
            } else {
                withAnimation(Theme.Motion.disclosure) { setFolder(row.id, open: true, sessionId: sid) }
            }
            return true
        case .left:
            guard let row = cursorRow() else { return false }
            if row.node.isDirectory && row.isOpen && fileFilter.isEmpty {
                withAnimation(Theme.Motion.disclosure) { setFolder(row.id, open: false, sessionId: sid) }
            } else if let parent = Self.parent(of: row.id) {
                treeCursor[sid] = parent
            }
            return true
        case .primary:
            guard let row = cursorRow() else { return false }
            if row.node.isDirectory {
                guard fileFilter.isEmpty else { return true }
                withAnimation(Theme.Motion.disclosure) { setFolder(row.id, open: !row.isOpen, sessionId: sid) }
            } else {
                openFile(row.id)
            }
            return true
        case .copy:
            return copyFileLocation()
        default:
            return nil
        }
    }

    private func cursorRow() -> TreeRow? {
        guard let path = treeCursorPath else { return nil }
        return visibleTreeRows().first { $0.id == path }
    }

    static func parent(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// A click on a tree row: folders open or close, files open in the preview.
    func clickTreeRow(_ row: TreeRow) {
        guard let sid = focusedSession?.id else { return }
        treeCursor[sid] = row.id
        if row.node.isDirectory {
            guard fileFilter.isEmpty else { return }
            withAnimation(Theme.Motion.disclosure) { setFolder(row.id, open: !row.isOpen, sessionId: sid) }
        } else {
            openFile(row.id)
        }
    }

    /// Shows a file in the preview and remembers it for this session.
    func openFile(_ path: String) {
        guard let session = focusedSession else { return }
        treeCursor[session.id] = path
        withAnimation(Theme.Motion.previewFade) { openedFile[session.id] = path }
        loadPreview(cwd: session.cwd, path: path)
    }

    /// "y" in Files: `path:line` of the first changed line of the file under the cursor
    /// (else the previewed file). Line 1 when this session did not change it.
    func copyFileLocation() -> Bool {
        guard let sid = focusedSession?.id else { return false }
        var path = openedFile[sid]
        if let cursor = treeCursor[sid], let row = visibleTreeRows().first(where: { $0.id == cursor }), !row.node.isDirectory {
            path = cursor
        }
        guard let path else { return false }
        copyLocation(path: path, line: changeMarks(forPath: path).firstLine ?? 1)
        return true
    }

    // MARK: Preview

    static func previewKey(cwd: String, path: String) -> String { cwd + "|" + path }

    /// The previewed file of the focused session, when loaded.
    var openedPreview: LoadedPreview? {
        guard let session = focusedSession, let path = openedFile[session.id] else { return nil }
        return previews[Self.previewKey(cwd: session.cwd, path: path)]
    }

    func reloadOpenedPreview() {
        guard let session = focusedSession, let path = openedFile[session.id] else { return }
        loadPreview(cwd: session.cwd, path: path)
    }

    /// Reads the file off the main thread. When RepoFiles capped it, also counts the whole
    /// file's lines for the "… N more lines" footer.
    func loadPreview(cwd: String, path: String) {
        guard !cwd.isEmpty else { return }
        let key = Self.previewKey(cwd: cwd, path: path)
        Task.detached(priority: .userInitiated) { [weak self] in
            let preview = RepoFiles.preview(cwd: cwd, relativePath: path)
            var total: Int?
            if preview.truncated && !preview.isBinary {
                total = Self.countLines(atPath: (cwd as NSString).appendingPathComponent(path))
            }
            let loaded = LoadedPreview(preview: preview, totalLines: total)
            await self?.applyPreview(loaded, key: key)
        }
    }

    private func applyPreview(_ loaded: LoadedPreview, key: String) {
        if previews[key] == loaded { return }
        // Keep the newest few: the one showing plus a handful to flip back to.
        if previews[key] == nil && previews.count >= Theme.Limits.maxCachedPreviews {
            let keep = focusedSession.flatMap { s in openedFile[s.id].map { Self.previewKey(cwd: s.cwd, path: $0) } }
            if let drop = previews.keys.first(where: { $0 != keep }) { previews[drop] = nil }
        }
        withAnimation(Theme.Motion.previewFade) { previews[key] = loaded }
    }

    nonisolated static func countLines(atPath path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        var count = 0
        data.withUnsafeBytes { raw in
            for byte in raw where byte == 0x0A { count += 1 }
        }
        if let last = data.last, last != 0x0A { count += 1 }
        return count
    }

    // MARK: What this session changed

    /// A path from a FileChange, relative to the session's cwd when it lies inside it.
    func relativePath(_ path: String) -> String {
        guard path.hasPrefix("/"), let cwd = focusedSession?.cwd, !cwd.isEmpty else { return path }
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Relative path -> summed ±counts across every turn of the focused session.
    var sessionChangeCounts: [String: FileChangeCount] {
        var result: [String: FileChangeCount] = [:]
        for turn in turns(for: focusedSession?.id) {
            for file in turn.files {
                let key = relativePath(file.path)
                var count = result[key] ?? FileChangeCount(added: 0, removed: 0)
                count.added += file.added
                count.removed += file.removed
                result[key] = count
            }
        }
        return result
    }

    /// The lines of `path` this session changed, in the file's current numbering. Patches are
    /// applied oldest first; each newer patch moves (or drops) the marks older ones left.
    /// Best effort: a patch Claude Code capped at 400 lines only marks what it recorded.
    func changeMarks(forPath path: String) -> ChangeMarks {
        var marks = ChangeMarks()
        let oldestFirst = turns(for: focusedSession?.id).reversed()
        for turn in oldestFirst {
            for file in turn.files where relativePath(file.path) == path {
                let patch = file.patch.isEmpty ? file.snippet : file.patch
                guard !patch.isEmpty else { continue }
                marks.added = Set(marks.added.compactMap { Self.mapLine($0, through: patch) })
                marks.removedAt = Set(marks.removedAt.compactMap { Self.mapLine($0, through: patch) })
                var delta = 0
                for line in patch {
                    switch line.kind {
                    case .context:
                        if let old = line.oldLine, let new = line.newLine { delta = new - old }
                    case .added:
                        if let new = line.newLine { marks.added.insert(new) }
                        delta += 1
                    case .removed:
                        if let old = line.oldLine { marks.removedAt.insert(old + delta) }
                        delta -= 1
                    case .hunk:
                        break
                    }
                }
            }
        }
        // A removal that sits on an added line reads as a change already; keep one tint per line.
        marks.removedAt.subtract(marks.added)
        return marks
    }

    /// Where old line `n` ends up after `patch`, or nil when the patch removed it.
    static func mapLine(_ n: Int, through patch: [DiffLine]) -> Int? {
        var delta = 0
        for line in patch {
            switch line.kind {
            case .context:
                guard let old = line.oldLine, let new = line.newLine else { continue }
                if old == n { return new }
                if old > n { return n + delta }
                delta = new - old
            case .removed:
                guard let old = line.oldLine else { continue }
                if old == n { return nil }
                if old > n { return n + delta }
                delta -= 1
            case .added:
                delta += 1
            case .hunk:
                break
            }
        }
        return n + delta
    }
}
