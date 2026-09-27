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

    private var lines: [DiffLine] { AppState.diffLines(file) }

    var body: some View {
        let lines = self.lines
        let contentHeight = CGFloat(lines.count) * Theme.Size.diffLineHeight + 2 * Theme.Size.diffVPadding
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { item in
                        DiffLineRow(line: item.element)
                    }
                }
                .padding(.vertical, Theme.Size.diffVPadding)
            }
            .frame(height: min(contentHeight, Theme.Size.diffMaxHeight))

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
                HStack(spacing: Theme.Size.spaceM) {
                    Image(systemName: Theme.Symbols.chevron)
                        .font(Theme.Fonts.chevron)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
                        .opacity(hasDiff ? 1 : 0)
                    HStack(spacing: 0) {
                        if showDirectory {
                            Text(Format.directory(file.path))
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Text(Format.fileName(file.path))
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                    .font(Theme.Fonts.monoCaption)
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
            .buttonStyle(.plain)

            if open {
                DiffView(file: file)
            }
        }
        .id(item.key)
    }
}
