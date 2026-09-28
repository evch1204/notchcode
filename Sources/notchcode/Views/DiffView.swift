// DiffView.swift
// A file's diff as Claude Code recorded it: mono, old and new line numbers in a
// dim gutter, hunk headers in blue, added rows on green, removed on red. Lines
// never wrap and never scroll sideways: long ones are clipped. Scrolls
// vertically inside a fixed maximum height. Also the expandable file row that
// owns it, shared by the Changes and Files tabs.

import SwiftUI

@MainActor
struct DiffView: View {
    let file: FileChange
    /// Inside a request card: the diff takes what room is left, up to this, instead of a fixed height.
    var maxHeight: CGFloat? = nil
    /// Inside a request card: ↑↓ arrive here as line steps.
    var scroll: RequestDiffScroll? = nil

    /// The line at the top of the viewport; the scroll wheel moves it too.
    @State private var topLine: Int?
    @State private var viewportHeight: CGFloat = 0

    private var lines: [DiffLine] { AppState.diffLines(file) }

    var body: some View {
        let lines = self.lines
        let contentHeight = CGFloat(lines.count) * Theme.Size.diffLineHeight + 2 * Theme.Size.diffVPadding
        VStack(alignment: .leading, spacing: 0) {
            sized(ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { item in
                        DiffLineRow(line: item.element)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, Theme.Size.diffVPadding)
            }
            .scrollPosition(id: $topLine), contentHeight: contentHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: scroll) { _, command in
                guard let command else { return }
                let visible = max(1, Int(viewportHeight / Theme.Size.diffLineHeight) - 1)
                let last = max(0, lines.count - visible)
                let next = max(0, min(last, (topLine ?? 0) + command.delta))
                withAnimation(Theme.Motion.tap) { topLine = next }
            }

            if file.patchTruncated {
                Text(moreLinesText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Size.snippetLinePadding)
                    .padding(.bottom, Theme.Size.diffVPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                .fill(Theme.Colors.inset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous))
    }

    @ViewBuilder
    private func sized(_ view: some View, contentHeight: CGFloat) -> some View {
        if let maxHeight {
            view.frame(
                minHeight: min(contentHeight, Theme.Size.requestDiffMinHeight),
                maxHeight: min(contentHeight, maxHeight)
            )
        } else {
            view.frame(height: min(contentHeight, Theme.Size.diffMaxHeight))
        }
    }

    /// "… 212 more lines in the editor": changed lines the counts know about but the patch left out.
    private var moreLinesText: String {
        let shown = lines.filter { $0.kind == .added || $0.kind == .removed }.count
        let missing = max(0, file.added + file.removed - shown)
        let count = missing > 0 ? "\(missing) more lines" : "more lines"
        return Theme.Glyphs.ellipsis + " " + count + " in the editor"
    }
}

@MainActor
struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: Theme.Size.diffGutterSpacing) {
            if line.kind == .hunk {
                clipped(Text(line.text).foregroundStyle(Theme.Colors.diffHunk))
            } else {
                number(line.kind == .added ? nil : line.oldLine)
                number(line.kind == .removed ? nil : line.newLine)
                Text(prefix)
                    .foregroundStyle(color)
                clipped(Text(line.text).foregroundStyle(line.kind == .context ? Theme.Colors.diffText : color))
            }
        }
        .font(Theme.Fonts.monoSmall)
        .padding(.horizontal, Theme.Size.snippetLinePadding)
        .frame(height: Theme.Size.diffLineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipped()
    }

    /// Full-length text that never wraps or widens the row: it sits in an overlay, so
    /// the row keeps the card's width and whatever runs past the edge is cut off.
    private func clipped(_ text: some View) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                text
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .clipped()
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Theme.Colors.diffLineNumber)
            .lineLimit(1)
            .frame(width: Theme.Size.diffLineNumberWidth, alignment: .trailing)
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return Theme.Glyphs.minus
        case .context, .hunk: return " "
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: return Theme.Colors.green
        case .removed: return Theme.Colors.red
        case .context: return Theme.Colors.inkTertiary
        case .hunk: return Theme.Colors.diffHunk
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Theme.Colors.diffAddedBackground
        case .removed: return Theme.Colors.diffRemovedBackground
        case .context, .hunk: return Color.clear
        }
    }
}

/// A file row that opens to its diff. Click or ⏎ (on the keyboard cursor) toggles it.
@MainActor
struct FileDiffRow: View {
    @ObservedObject var state: AppState
    let item: DiffRowItem
    /// Files tab rows sit under a directory header, so they show the file name only.
    var showDirectory = false

    var body: some View {
        let file = item.file
        let hasDiff = !AppState.diffLines(file).isEmpty
        let open = hasDiff && state.isDiffOpen(item)
        let isCursor = state.cursorRowKey == item.key
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            Button {
                state.setRowCursor(key: item.key)
                guard hasDiff else { return }
                withAnimation(Theme.Motion.tap) { state.toggleDiff(item.key) }
            } label: {
                FileRowLabel(file: file, open: open, hasDiff: hasDiff, isCursor: isCursor, showDirectory: showDirectory)
            }
            .buttonStyle(.plain)

            if open {
                DiffView(file: file)
            }
        }
        .id(item.key)
    }
}

/// "▸ Theme.swift · Sources/notchcode   ▮▮▮▯▯ +12 −3": the row a diff opens under.
@MainActor
struct FileRowLabel: View {
    let file: FileChange
    let open: Bool
    let hasDiff: Bool
    let isCursor: Bool
    var showDirectory = false

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Image(systemName: Theme.Symbols.chevron)
                .font(Theme.Fonts.chevron)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
                .opacity(hasDiff ? 1 : 0)
            PathLabel(path: file.path, showDirectory: showDirectory)
                .layoutPriority(1)
            Spacer(minLength: Theme.Size.spaceM)
            DiffCells(added: file.added, removed: file.removed)
            DiffCounts(added: file.added, removed: file.removed)
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .padding(.vertical, Theme.Size.rowVPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isCursor ? Theme.Colors.rowCursor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// "Theme.swift · Sources/notchcode": the file name first, in ink, always whole while it
/// fits; the folder after it, dim, head-truncated so the nearest folder survives, and
/// dropped when less than `pathFolderMinWidth` is left. A name too long for the row
/// truncates in the middle. Used wherever a changed file is a row: the Changes tool, the
/// commit card's file list, the Files preview header.
@MainActor
struct PathLabel: View {
    let path: String
    var showDirectory = true

    var body: some View {
        let name = Format.fileName(path)
        let folder = showDirectory ? Format.directory(path) : ""
        Group {
            if folder.isEmpty {
                nameText(name)
            } else {
                // The first layout reports the folder's ideal width as its minimum, so it is
                // chosen whenever the whole name and a readable piece of the folder fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Text(name)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                            .fixedSize()
                        Text(Theme.Glyphs.separator)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .lineLimit(1)
                            .fixedSize()
                        Text(folder)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(minWidth: Theme.Size.pathFolderMinWidth, idealWidth: Theme.Size.pathFolderMinWidth, alignment: .leading)
                    }
                    nameText(name)
                }
            }
        }
        .font(Theme.Fonts.monoCaption)
        .help(path)
    }

    private func nameText(_ name: String) -> some View {
        Text(name)
            .foregroundStyle(Theme.Colors.ink)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
