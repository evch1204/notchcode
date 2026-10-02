// FilesModel.swift
// The Files tool's value types: a loaded preview, a visible tree row, a file's ±counts, the
// lines this session changed, and the tool's state that AppState keeps as one value
// (`filesTool`).

import Foundation

/// A file preview as loaded for the pane, with the line count when RepoFiles capped it.
struct LoadedPreview: Equatable {
    var preview: FilePreview
    /// Lines in the whole file, when the preview was truncated and the count is known.
    var totalLines: Int?
}

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

/// Files tab. Per session: the tree cursor, the file being previewed, and the folders
/// flipped from their default (top level open, deeper closed).
struct FilesToolState: Equatable {
    /// cwd -> the repository tree, as RepoFiles last read it.
    var repoTrees: [String: [FileTreeNode]] = [:]
    /// cwds whose tree is being read right now.
    var repoTreesLoading: Set<String> = []
    var treeCursor: [String: String] = [:]
    var openedFile: [String: String] = [:]
    var treeToggled: [String: Set<String>] = [:]
    /// The Files tab's name filter. Esc clears it.
    var filter = ""
    /// The filter field has keyboard focus: typed keys go to it, not to the card's shortcuts.
    var filterFocused = false
    /// The preview of the opened file, keyed "cwd|path". Only the newest few are kept.
    var previews: [String: LoadedPreview] = [:]
    /// Session id -> a Markdown file shows its source instead of the rendered preview.
    /// In memory only: every run starts on Preview.
    var markdownSource: [String: Bool] = [:]
}
