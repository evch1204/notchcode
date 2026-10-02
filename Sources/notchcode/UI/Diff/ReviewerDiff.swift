// ReviewerDiff.swift
// The reviewer diff shared by the Git tool's stage and the Changes tool's diff pane: every
// line whole (it scrolls sideways), both line numbers, changed words tinted, hunk headers in
// blue, the minimap down the right edge. And the M / A / D badge their headers put after a
// file's name.

import SwiftUI

/// The reviewer diff, in the Git tool's stage and the Changes tool's pane alike: every line
/// whole (the pane scrolls sideways as the Files preview does), both line numbers, the
/// changed words tinted, the minimap on the right edge outside the scrolling content. Tracks the top row for the minimap's visible range; a
/// minimap press scrolls it.
@MainActor
struct ReviewerDiff: View {
    let file: FileChange
    let lines: [DiffLine]
    /// The file's line count, for the minimap's scale; nil draws the diff rows only.
    let fileLines: Int?
    /// The diff row at the top of the pane, and how many rows the pane shows. Callers key
    /// the view by the file's path, so both start over with each file.
    @State private var topRow = 0
    @State private var visibleCount = 0
    /// Worked out once per diff, not on every scroll step (the header re-renders with it).
    @State private var words: [Int: [Range<Int>]] = [:]
    @State private var minimap: DiffMinimapModel?

    private struct Inputs: Equatable {
        var lines: [DiffLine]
        var fileLines: Int?
    }

    var body: some View {
        WideLinesScroll(
            texts: lines.map { $0.prefix + $0.text },
            gutter: 2 * (Theme.Size.diffLineNumberWidth + Theme.Size.previewGutterSpacing),
            reserve: Theme.Size.diffMinimapReserve,
            footer: file.patchTruncated ? truncatedNote : nil,
            onScroll: { minY in
                let row = Int(((-minY - Theme.Size.previewVPadding) / Theme.Size.diffLineHeight).rounded())
                let clamped = max(0, min(max(0, lines.count - 1), row))
                if clamped != topRow { topRow = clamped }
            },
            onHeight: { height in
                visibleCount = Int(height / Theme.Size.diffLineHeight)
            }
        ) { contentWidth in
            ForEach(lines.indices, id: \.self) { index in
                CodeLineRow(lines[index], words: words[index] ?? [], minWidth: contentWidth)
                    .id(index)
            }
        } accessory: { proxy in
            if let minimap {
                DiffMinimap(model: minimap, visibleRows: visibleRange) { row in
                    let target = max(0, row - visibleCount / 2)
                    proxy.scrollTo(target, anchor: .topLeading)
                }
                .padding(.vertical, Theme.Size.diffMinimapInset)
                .padding(.trailing, Theme.Size.diffMinimapInset)
            }
        }
        .onChange(of: Inputs(lines: lines, fileLines: fileLines), initial: true) { _, inputs in
            words = WordDiff.marks(inputs.lines)
            minimap = DiffMinimapModel(lines: inputs.lines, fileLines: inputs.fileLines)
        }
    }

    private var visibleRange: ClosedRange<Int> {
        let last = max(0, lines.count - 1)
        let top = min(topRow, last)
        return top...max(top, min(last, top + max(1, visibleCount) - 1))
    }

    /// "… 212 more lines in the editor" when the patch left lines out.
    private var truncatedNote: String {
        let shown = lines.filter { $0.kind == .added || $0.kind == .removed }.count
        let missing = max(0, file.added + file.removed - shown)
        return Format.moreLines(missing) + " in the editor"
    }
}

/// "M", "A" or "D" in a small badge after the file's name.
@MainActor
struct FileKindBadge: View {
    let kind: String

    var body: some View {
        Text(letter)
            .font(Theme.Fonts.badge)
            .foregroundStyle(Theme.Colors.gitKindText)
            .frame(minWidth: Theme.Size.gitKindWidth)
            .padding(.horizontal, Theme.Size.badgeHPadding / 2)
            .frame(height: Theme.Size.badgeHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                    .fill(Theme.Colors.gitKindFill)
            )
            .fixedSize()
            .help(help)
    }

    private var letter: String {
        switch kind {
        case "new": return "A"
        case "renamed": return "R"
        case "deleted": return "D"
        default: return "M"
        }
    }

    private var help: String {
        switch kind {
        case "new": return "added"
        case "renamed": return "renamed"
        case "deleted": return "deleted"
        default: return "modified"
        }
    }
}
