// FilesTab.swift
// An IDE side panel for the selected session's repository. Left (40%): a filter field and
// the tree, folders with a disclosure chevron (top level open, deeper closed), files this
// session changed with a small ±badge. Right: the chosen file, mono, line numbers, no
// wrapping; lines this session added tinted green, a red mark where lines were removed.
//
// Keys: ↑↓ move, → opens a folder, ← closes it, ⏎ opens the file, / filters (esc clears),
// y copies path:line of the first changed line, ⌥⏎ teleports. All in AppState.handleFilesKey.

import SwiftUI

@MainActor
struct FilesTab: View {
    @ObservedObject var state: AppState
    @FocusState private var filterFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let treeWidth = (geo.size.width * Theme.Size.fileTreeShare).rounded(.down)
            HStack(alignment: .top, spacing: Theme.Size.filesColumnGap) {
                VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                    filterField
                    tree
                }
                .frame(width: treeWidth)

                Rectangle()
                    .fill(Theme.Colors.paneDivider)
                    .frame(width: Theme.Size.hairline)

                PreviewPane(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .parallaxGroup()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onAppear { state.loadRepoTree() }
        .onChange(of: filterFocused) { _, focused in
            if state.fileFilterFocused != focused { state.fileFilterFocused = focused }
        }
        .onChange(of: state.fileFilterFocused, initial: true) { _, focused in
            if filterFocused != focused { filterFocused = focused }
        }
    }

    // MARK: Filter

    private var filterField: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Image(systemName: Theme.Symbols.filter)
                .font(Theme.Fonts.symbol(Theme.Fonts.tinySize))
                .foregroundStyle(Theme.Colors.filterPlaceholder)
            TextField(
                "",
                text: Binding(
                    get: { state.fileFilter },
                    set: { value in withAnimation(Theme.Motion.filterRows) { state.fileFilter = value } }
                ),
                prompt: Text("Filter").foregroundStyle(Theme.Colors.filterPlaceholder)
            )
            .textFieldStyle(.plain)
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(Theme.Colors.ink)
            .focused($filterFocused)
            if state.fileFilter.isEmpty && !filterFocused {
                Keycap(Theme.Keys.slash)
            }
        }
        .padding(.horizontal, Theme.Size.filterHPadding)
        .frame(height: Theme.Size.filterHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    // MARK: Tree

    @ViewBuilder
    private var tree: some View {
        if state.focusedSession == nil {
            note("No session")
        } else if let nodes = state.focusedTree {
            if nodes.isEmpty {
                note("No files here")
            } else {
                treeList
            }
        } else {
            note("Reading files" + Theme.Glyphs.ellipsis)
        }
    }

    private var treeList: some View {
        let rows = state.visibleTreeRows()
        let counts = state.sessionChangeCounts
        let cursor = state.treeCursorPath
        let opened = state.openedFilePath
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TreeRowView(
                            row: row,
                            count: row.node.isDirectory ? nil : counts[row.id],
                            isCursor: cursor == row.id,
                            isOpened: opened == row.id
                        )
                        .onTapGesture { state.clickTreeRow(row) }
                        .transition(Theme.Motion.childTransition(row.childIndex))
                        .id(row.id)
                    }
                }
                .animation(Theme.Motion.filterRows, value: state.fileFilter)
            }
            .overlay {
                if rows.isEmpty { note("No matches") }
            }
            .onChange(of: state.treeCursorPath) { _, path in
                guard let path else { return }
                withAnimation(Theme.Motion.tap) { proxy.scrollTo(path) }
            }
            .onAppear {
                // Back on this session: show the file it had open.
                if let path = opened { proxy.scrollTo(path) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tree row: indent, chevron for folders, the name in mono, and a ±badge for changed files.
@MainActor
private struct TreeRowView: View {
    let row: TreeRow
    let count: FileChangeCount?
    let isCursor: Bool
    let isOpened: Bool

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Color.clear
                .frame(width: CGFloat(row.depth) * Theme.Size.treeIndent)
            Group {
                if row.node.isDirectory {
                    Image(systemName: Theme.Symbols.chevron)
                        .font(Theme.Fonts.treeChevron)
                        .foregroundStyle(Theme.Colors.treeChevron)
                        .rotationEffect(.degrees(row.isOpen ? Theme.Motion.chevronOpenDegrees : 0))
                        .animation(Theme.Motion.disclosure, value: row.isOpen)
                } else {
                    Color.clear
                }
            }
            .frame(width: Theme.Size.treeChevronWidth)
            Text(row.node.name)
                .font(Theme.Fonts.monoCaption)
                .foregroundStyle(row.node.isDirectory ? Theme.Colors.treeFolder : Theme.Colors.treeFile)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Size.spaceS)
            if let count {
                ChangeBadge(count: count)
            }
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .frame(height: Theme.Size.treeRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(isOpened ? Theme.Colors.treeOpened : (isCursor ? Theme.Colors.rowCursor : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(isCursor && isOpened ? Theme.Colors.hairline : Color.clear, lineWidth: Theme.Size.hairline)
        )
        .contentShape(Rectangle())
    }
}

/// "+12 −3" in small mono inside a capsule.
@MainActor
private struct ChangeBadge: View {
    let count: FileChangeCount

    var body: some View {
        HStack(spacing: Theme.Size.spaceXS) {
            if count.added > 0 {
                Text(Format.added(count.added)).foregroundStyle(Theme.Colors.green)
            }
            if count.removed > 0 {
                Text(Format.removed(count.removed)).foregroundStyle(Theme.Colors.red)
            }
            if count.added == 0 && count.removed == 0 {
                Text(Format.added(0)).foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
        .font(Theme.Fonts.badge)
        .lineLimit(1)
        .padding(.horizontal, Theme.Size.badgeHPadding)
        .frame(height: Theme.Size.badgeHeight)
        .background(Capsule(style: .continuous).fill(Theme.Colors.badgeFill))
        .fixedSize()
    }
}

// MARK: - Preview

/// The right column. Crossfades 0.2 s from one file to the next.
@MainActor
private struct PreviewPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        let path = state.openedFilePath
        ZStack {
            if let path {
                if let loaded = state.openedPreview {
                    PreviewBody(
                        path: path,
                        loaded: loaded,
                        count: state.sessionChangeCounts[path],
                        marks: state.changeMarks(forPath: path)
                    )
                    .id(path)
                    .transition(.opacity)
                } else {
                    centred(Theme.Glyphs.ellipsis)
                        .id("loading|" + path)
                        .transition(.opacity)
                }
            } else {
                centred("Select a file")
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.previewFade, value: path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centred(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct PreviewBody: View {
    let path: String
    let loaded: LoadedPreview
    let count: FileChangeCount?
    let marks: ChangeMarks

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header
            if loaded.preview.isBinary {
                message("Binary file")
            } else if loaded.preview.lines.isEmpty {
                message(loaded.preview.truncated ? "Too large to preview" : "Empty file")
            } else {
                PreviewLines(lines: loaded.preview.lines, marks: marks, footer: footer)
            }
        }
    }

    /// "FilesTab.swift · Views/Tabs   +12 −3".
    private var header: some View {
        HStack(spacing: Theme.Size.spaceM) {
            PathLabel(path: path)
                .layoutPriority(1)
            Spacer(minLength: Theme.Size.spaceM)
            if let count {
                DiffCounts(added: count.added, removed: count.removed)
            }
        }
        .padding(.horizontal, Theme.Size.previewHPadding)
    }

    /// "… 212 more lines" when RepoFiles capped the file.
    private var footer: String? {
        guard loaded.preview.truncated else { return nil }
        let shown = loaded.preview.lines.count
        if let total = loaded.totalLines, total > shown {
            return Theme.Glyphs.ellipsis + " \(total - shown) more lines"
        }
        return Theme.Glyphs.ellipsis + " more lines"
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The file's lines, scrollable both ways, never wrapped. Opens scrolled to the first change.
@MainActor
private struct PreviewLines: View {
    let lines: [String]
    let marks: ChangeMarks
    let footer: String?

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            let number = index + 1
                            PreviewLineRow(
                                number: number,
                                text: lines[index],
                                added: marks.added.contains(number),
                                removedHere: marks.removedAt.contains(number),
                                minWidth: geo.size.width
                            )
                            .id(number)
                        }
                        if let footer {
                            Text(footer)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .padding(.leading, Theme.Size.previewNumberWidth + Theme.Size.previewGutterSpacing + Theme.Size.previewHPadding)
                                .frame(height: Theme.Size.previewLineHeight)
                        }
                    }
                    .padding(.vertical, Theme.Size.previewVPadding)
                }
                .onAppear {
                    if let first = marks.firstLine, first > 1 {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                .fill(Theme.Colors.inset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous))
    }
}

@MainActor
private struct PreviewLineRow: View {
    let number: Int
    let text: String
    let added: Bool
    let removedHere: Bool
    let minWidth: CGFloat

    var body: some View {
        HStack(spacing: Theme.Size.previewGutterSpacing) {
            Text(String(number))
                .foregroundStyle(numberColor)
                .frame(width: Theme.Size.previewNumberWidth, alignment: .trailing)
            Text(text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(added ? Theme.Colors.ink : Theme.Colors.previewText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(Theme.Fonts.monoSmall)
        .lineLimit(1)
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(height: Theme.Size.previewLineHeight)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(added ? Theme.Colors.previewAddedBackground : Color.clear)
        .overlay(alignment: .leading) {
            if removedHere {
                Rectangle()
                    .fill(Theme.Colors.previewRemovedMark)
                    .frame(width: Theme.Size.removedMarkWidth)
            }
        }
    }

    private var numberColor: Color {
        if added { return Theme.Colors.previewAddedNumber }
        if removedHere { return Theme.Colors.previewRemovedMark }
        return Theme.Colors.previewLineNumber
    }
}
