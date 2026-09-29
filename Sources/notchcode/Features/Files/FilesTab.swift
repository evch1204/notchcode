// FilesTab.swift
// An IDE side panel for the selected session's repository. Left (40%): a filter field and
// the tree, folders with a disclosure chevron (top level open, deeper closed), files this
// session changed with a small ±badge. Right: the chosen file, mono, line numbers, no
// wrapping; lines this session added tinted green, a red mark where lines were removed.
//
// Keys: ↑↓ move, → opens a folder, ← closes it, ⏎ opens the file, / filters (esc clears),
// y copies path:line of the first changed line, ⌥⏎ teleports. All in AppState.handleFilesKey.
// ⌘B collapses the tree so the preview takes the whole well; P flips a Markdown file between
// its rendered Preview and its Code. Both through handleFilesKey.

import SwiftUI

@MainActor
struct FilesTab: View {
    @ObservedObject var state: AppState
    @FocusState private var filterFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let treeWidth = (geo.size.width * Theme.Size.fileTreeShare).rounded(.down)
            let collapsed = state.filesTreeCollapsed
            HStack(alignment: .top, spacing: 0) {
                // The tree keeps its width and slides out to the left behind a clip.
                VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                    filterField
                    tree
                }
                .frame(width: treeWidth)
                .padding(.trailing, Theme.Size.filesColumnGap)
                .frame(width: collapsed ? 0 : treeWidth + Theme.Size.filesColumnGap, alignment: .trailing)
                .clipped()
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(!collapsed)

                Rectangle()
                    .fill(Theme.Colors.paneDivider)
                    .frame(width: collapsed ? 0 : Theme.Size.hairline)
                    .padding(.trailing, collapsed ? 0 : Theme.Size.filesColumnGap)

                PreviewPane(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .parallaxGroup()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onAppear {
            state.loadRepoTree()
        }
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
                InlineKeycap(Theme.Keys.slash)
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
            EmptyNote(text: "No session", font: Theme.Fonts.caption)
        } else if let nodes = state.focusedTree {
            if nodes.isEmpty {
                EmptyNote(text: "No files here", font: Theme.Fonts.caption)
            } else {
                treeList
            }
        } else {
            EmptyNote(text: "Reading files" + Theme.Glyphs.ellipsis, font: Theme.Fonts.caption)
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
                if rows.isEmpty { EmptyNote(text: "No matches", font: Theme.Fonts.caption) }
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
                    RowChevron(open: row.isOpen, font: Theme.Fonts.treeChevron, color: Theme.Colors.treeChevron, width: nil)
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
        .capsuleTag(fill: Theme.Colors.badgeFill, hPadding: Theme.Size.badgeHPadding, height: Theme.Size.badgeHeight)
        .fixedSize()
    }
}

// MARK: - Preview

/// The right column: a header row (the collapse pill, then the file's name, the Markdown
/// switch and its ±counts), and below it the file. Both crossfade 0.2 s from file to file.
@MainActor
private struct PreviewPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        let path = state.openedFilePath
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            HStack(spacing: Theme.Size.spaceM) {
                TreeTogglePill(collapsed: state.filesTreeCollapsed, enabled: path != nil) {
                    state.toggleFilesTree()
                }
                ZStack(alignment: .leading) {
                    if let path {
                        PreviewHeader(
                            path: path,
                            count: state.sessionChangeCounts[path],
                            showsCode: markdownBinding
                        )
                        .id(path)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Size.previewHPadding)

            ZStack {
                if let path {
                    if let loaded = state.openedPreview {
                        PreviewBody(
                            loaded: loaded,
                            marks: state.changeMarks(forPath: path),
                            rendersMarkdown: AppState.isMarkdown(path) && !state.markdownShowsCode
                        )
                        .id(path)
                        .transition(.opacity)
                    } else {
                        EmptyNote(text: Theme.Glyphs.ellipsis)
                            .id("loading|" + path)
                            .transition(.opacity)
                    }
                } else {
                    EmptyNote(text: "Select a file")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Theme.Motion.previewFade, value: path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markdownBinding: Binding<Bool> {
        Binding(
            get: { state.markdownShowsCode },
            set: { state.markdownShowsCode = $0 }
        )
    }
}

/// The sidebar pill and its ⌘B keycap. Disabled (dimmed) with no file open. The Git tool
/// hides its file list with it.
@MainActor
struct TreeTogglePill: View {
    let collapsed: Bool
    let enabled: Bool
    /// What the pill hides: "file tree" (Files), "file list" (Git).
    var subject = "file tree"
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Button(action: action) {
                Image(systemName: Theme.Symbols.sidebar)
                    .font(Theme.Fonts.symbol(Theme.Fonts.tinySize))
            }
            .buttonStyle(SmallPillStyle())
            .help(collapsed ? "Show the " + subject : "Hide the " + subject)
            InlineKeycap(Theme.Keys.toggleTree)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.disabled)
        .fixedSize()
    }
}

/// "FilesTab.swift   Preview · Code  P   +12 −3". The switch shows only for Markdown files.
@MainActor
private struct PreviewHeader: View {
    let path: String
    let count: FileChangeCount?
    @Binding var showsCode: Bool

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            PathLabel(path: path)
                .layoutPriority(1)
            Spacer(minLength: Theme.Size.spaceM)
            if AppState.isMarkdown(path) {
                HStack(spacing: Theme.Size.spaceS) {
                    SegmentedPills(selection: $showsCode, options: [
                        (false, "Preview"),
                        (true, "Code"),
                    ])
                    InlineKeycap(Theme.Keys.markdownMode)
                }
                .fixedSize()
            }
            if let count {
                DiffCounts(added: count.added, removed: count.removed)
            }
        }
    }
}

@MainActor
private struct PreviewBody: View {
    let loaded: LoadedPreview
    let marks: ChangeMarks
    /// A Markdown file on Preview: rendered blocks instead of numbered lines.
    let rendersMarkdown: Bool

    var body: some View {
        if loaded.preview.isBinary {
            EmptyNote(text: "Binary file")
        } else if loaded.preview.lines.isEmpty {
            EmptyNote(text: loaded.preview.truncated ? "Too large to preview" : "Empty file")
        } else if rendersMarkdown {
            MarkdownView(lines: loaded.preview.lines, footer: footer)
                .transition(.opacity)
        } else {
            PreviewLines(lines: loaded.preview.lines, marks: marks, footer: footer)
                .transition(.opacity)
        }
    }

    /// "… 212 more lines" when RepoFiles capped the file.
    private var footer: String? {
        guard loaded.preview.truncated else { return nil }
        return Format.moreLines(loaded.totalLines.map { $0 - loaded.preview.lines.count })
    }
}

/// The file's lines, scrollable both ways, never wrapped. Opens scrolled to the first change.
@MainActor
private struct PreviewLines: View {
    let lines: [String]
    let marks: ChangeMarks
    let footer: String?

    var body: some View {
        WideLinesScroll(
            texts: lines,
            gutter: Theme.Size.previewNumberWidth + Theme.Size.previewGutterSpacing,
            lineHeight: Theme.Size.previewLineHeight,
            footer: footer,
            onAppear: { proxy in
                if let first = marks.firstLine, first > 1 {
                    proxy.scrollTo(first, anchor: .top)
                }
            }
        ) { contentWidth in
            ForEach(lines.indices, id: \.self) { index in
                let number = index + 1
                let added = marks.added.contains(number)
                let removedHere = marks.removedAt.contains(number)
                CodeLineRow(
                    numbers: [number],
                    numberWidth: Theme.Size.previewNumberWidth,
                    numberColor: added ? Theme.Colors.previewAddedNumber
                        : removedHere ? Theme.Colors.previewRemovedMark : Theme.Colors.previewLineNumber,
                    height: Theme.Size.previewLineHeight,
                    minWidth: contentWidth,
                    tint: added ? Theme.Colors.previewAddedBackground : Color.clear
                ) {
                    Text(lines[index].replacingOccurrences(of: "\t", with: "    "))
                        .foregroundStyle(added ? Theme.Colors.ink : Theme.Colors.previewText)
                }
                .overlay(alignment: .leading) {
                    if removedHere {
                        Rectangle()
                            .fill(Theme.Colors.previewRemovedMark)
                            .frame(width: Theme.Size.removedMarkWidth)
                    }
                }
                .id(number)
            }
        } accessory: { _ in
            EmptyView()
        }
    }
}
