// DiffView.swift
// A file's diff as Claude Code recorded it: a rounded box, two dim line-number columns
// (old, new), then the line with its +/− prefix, in the mono size the Files preview uses.
// Added rows green on a faint green, removed red on a faint red, context grey, hunk
// headers blue. Lines never wrap and never scroll sideways: long ones are clipped. Scrolls
// vertically inside a capped height, with "… 9 more lines · scroll" at the bottom of the
// box while more is below. Also the expandable file row that owns it, shared by the
// Changes tool and the commit card.

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
        let contentHeight = CGFloat(lines.count) * Theme.Size.diffLineHeight
        let overflows = contentHeight > (maxHeight ?? Theme.Size.diffMaxHeight)
        VStack(alignment: .leading, spacing: 0) {
            sized(ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { item in
                        DiffLineRow(line: item.element)
                    }
                }
                .scrollTargetLayout()
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

            if overflows || file.patchTruncated {
                DiffNoteRow(text: footerText(lines: lines, overflows: overflows))
            }
        }
        .padding(.vertical, Theme.Size.previewVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.inset)
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

    /// "… 9 more lines · scroll" while lines are below the viewport; at the bottom,
    /// "… 212 more lines in the editor" when the patch left lines out, else "end of diff".
    private func footerText(lines: [DiffLine], overflows: Bool) -> String {
        let visible = Int(viewportHeight / Theme.Size.diffLineHeight)
        let below = max(0, lines.count - (topLine ?? 0) - max(0, visible))
        if overflows, below > 0 {
            let count = below == 1 ? "1 more line" : "\(below) more lines"
            return Theme.Glyphs.ellipsis + " " + count + Theme.Glyphs.separator + "scroll"
        }
        if file.patchTruncated {
            let shown = lines.filter { $0.kind == .added || $0.kind == .removed }.count
            let missing = max(0, file.added + file.removed - shown)
            let count = missing > 0 ? "\(missing) more lines" : "more lines"
            return Theme.Glyphs.ellipsis + " " + count + " in the editor"
        }
        return "end of diff"
    }
}

/// One diff line: "  42  44  + NotchShape(radius: theme.notchRadius)". The old file's
/// number, then the new file's; a removed line has only the old, an added line only the
/// new, a hunk header neither.
@MainActor
struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        DiffLineLayout(old: old, new: new) {
            Text(prefix + line.text).foregroundStyle(textColor)
        }
        .background(background)
    }

    private var old: Int? { line.oldNumber }
    private var new: Int? { line.newNumber }
    private var prefix: String { line.prefix }
    private var textColor: Color { line.textColor }
    private var background: Color { line.background }
}

extension DiffLine {
    /// The old file's number: a removed or context line has one.
    var oldNumber: Int? {
        switch kind {
        case .removed, .context: return oldLine
        case .added, .hunk: return nil
        }
    }

    /// The new file's number: an added or context line has one.
    var newNumber: Int? {
        switch kind {
        case .added, .context: return newLine
        case .removed, .hunk: return nil
        }
    }

    var prefix: String {
        switch kind {
        case .added: return Theme.Glyphs.diffAdded
        case .removed: return Theme.Glyphs.diffRemoved
        case .context: return Theme.Glyphs.diffContext
        case .hunk: return ""
        }
    }

    var textColor: Color {
        switch kind {
        case .added: return Theme.Colors.green
        case .removed: return Theme.Colors.red
        case .context: return Theme.Colors.diffText
        case .hunk: return Theme.Colors.diffHunk
        }
    }

    var background: Color {
        switch kind {
        case .added: return Theme.Colors.diffAddedBackground
        case .removed: return Theme.Colors.diffRemovedBackground
        case .context, .hunk: return Color.clear
        }
    }
}

/// The line at the bottom of a diff's box ("… 9 more lines · scroll"), in the caption
/// size, lined up with the diff's text column.
@MainActor
private struct DiffNoteRow: View {
    let text: String

    var body: some View {
        DiffLineLayout(old: nil, new: nil) {
            Text(text)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        }
    }
}

/// A diff line's columns: the two dim numbers, then the text. The text never wraps or
/// widens the row: it sits in an overlay, so whatever runs past the edge is cut off.
@MainActor
private struct DiffLineLayout<Content: View>: View {
    let old: Int?
    let new: Int?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.Size.previewGutterSpacing) {
            number(old)
            number(new)
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    content
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .clipped()
        }
        .font(Theme.Fonts.monoSmall)
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(height: Theme.Size.diffLineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Theme.Colors.diffLineNumber)
            .lineLimit(1)
            .frame(width: Theme.Size.diffLineNumberWidth, alignment: .trailing)
    }
}

/// A changed-file row that opens to its diff. Click or ⏎ (on the keyboard cursor)
/// toggles it. The Changes tool indents it one chevron column under its turn.
@MainActor
struct FileDiffRow: View {
    @ObservedObject var state: AppState
    let item: DiffRowItem

    var body: some View {
        let file = item.file
        let hasDiff = !AppState.diffLines(file).isEmpty
        let open = hasDiff && state.isDiffOpen(item)
        let isCursor = state.cursorRowKey == item.key
        VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
            Button {
                state.setRowCursor(key: item.key)
                guard hasDiff else { return }
                withAnimation(Theme.Motion.tap) { state.toggleDiff(item.key) }
            } label: {
                FileRowLabel(file: file, open: open, hasDiff: hasDiff, isCursor: isCursor)
            }
            .buttonStyle(.plain)

            if open {
                DiffView(file: file)
            }
        }
        .id(item.key)
    }
}

/// "▸ NotchView.swift            ▮▮▮▮▮  +12 −12": the row a diff opens under, with a
/// Sessions row's padding, radius and cursor fill. The name truncates in the middle; the
/// cells and counts always keep their room at the right.
@MainActor
struct FileRowLabel: View {
    let file: FileChange
    let open: Bool
    let hasDiff: Bool
    let isCursor: Bool

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            RowChevron(open: open)
                .opacity(hasDiff ? 1 : 0)
            HStack(spacing: Theme.Size.spaceM) {
                PathLabel(path: file.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Size.spaceM) {
                DiffCells(added: file.added, removed: file.removed)
                DiffCounts(added: file.added, removed: file.removed)
            }
            .fixedSize()
        }
        .rowCursorFill(isCursor)
    }
}

/// The disclosure chevron at the front of a turn or file row: a Sessions chevron, turned
/// down while open. Its frame plus the row gap is one `chevronColumn`, so a file row
/// indented by that column puts its chevron under the turn's title.
@MainActor
struct RowChevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: Theme.Symbols.chevron)
            .font(Theme.Fonts.chevron)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
            .animation(Theme.Motion.disclosure, value: open)
            .frame(width: Theme.Size.chevronColumn - Theme.Size.spaceM)
    }
}

extension View {
    /// A list row's padding, and the keyboard cursor's fill behind it: the same as a Sessions row.
    func rowCursorFill(_ isCursor: Bool) -> some View {
        padding(.horizontal, Theme.Size.rowHPadding)
            .padding(.vertical, Theme.Size.rowVPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isCursor ? Theme.Colors.rowCursor : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

/// "Theme.swift": a changed file's name only, in ink, truncated in the middle when long,
/// with the full path on hover. Used wherever a changed file is a row: the Changes tool,
/// the commit card's file list, the Files preview header.
@MainActor
struct PathLabel: View {
    let path: String

    var body: some View {
        Text(Format.fileName(path))
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(Theme.Colors.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}
