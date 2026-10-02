// FileRows.swift
// The expandable file row that owns a diff, shared by the Changes tool and the commit
// card: its label (name, cells, counts), the disclosure chevron, the cursor fill a list
// row carries, and the file's name label. And DiffRowItem, one file row in the Git rail.

import SwiftUI

/// One expandable file row in the Git tool's rail. `key` is stable across reloads.
struct DiffRowItem: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var file: FileChange
}

/// A changed-file row that opens to its diff under it: the commit card lists its files with
/// it. The caller
/// says what a click does, whether the row is open and under the cursor, and draws the diff.
@MainActor
struct FileDiffRow<Diff: View>: View {
    let file: FileChange
    let open: Bool
    let isCursor: Bool
    var spacing: CGFloat = Theme.Size.spaceXS
    /// The commit card's rows without a diff take no clicks; the Changes rows still move the cursor.
    var disabledWithoutDiff = false
    let action: () -> Void
    @ViewBuilder let diff: () -> Diff

    var body: some View {
        let hasDiff = !AppState.diffLines(file).isEmpty
        VStack(alignment: .leading, spacing: spacing) {
            Button(action: action) {
                FileRowLabel(file: file, open: open, hasDiff: hasDiff, isCursor: isCursor)
            }
            .buttonStyle(.plain)
            .disabled(disabledWithoutDiff && !hasDiff)

            if open {
                diff()
            }
        }
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
                if file.kind == "shell" {
                    // Changed by a Bash command: its diff is against HEAD, not the edit alone.
                    Text(Theme.Glyphs.shellTag)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .fixedSize()
                        .help("changed by a shell command" + Theme.Glyphs.separator + "diff against HEAD")
                }
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
/// The Files tree, the "Show changes" and "3 done" chevrons and a session row's teleport
/// chevron pass their own font, colour and width; `animated: false` leaves the turn to
/// whatever transaction toggles it.
@MainActor
struct RowChevron: View {
    let open: Bool
    var font: Font = Theme.Fonts.chevron
    var color: Color = Theme.Colors.inkTertiary
    var width: CGFloat? = Theme.Size.chevronColumn - Theme.Size.spaceM
    var animated = true

    var body: some View {
        let chevron = Image(systemName: Theme.Symbols.chevron)
            .font(font)
            .foregroundStyle(color)
            .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
        Group {
            if animated {
                chevron.animation(Theme.Motion.disclosure, value: open)
            } else {
                chevron
            }
        }
        .frame(width: width)
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
    var color: Color = Theme.Colors.ink

    var body: some View {
        Text(Format.fileName(path))
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}
