// GitDiffPane.swift
// The Git tool's right pane: the selected file's reviewer diff under a header that stays on
// top, the clean note when there is nothing to commit, and the push confirm.

import SwiftUI

// MARK: - The reviewer diff

/// The right pane: a header that stays on top (the ⌘B pill, the name, M/A/D, the counts),
/// then the selected file's diff, which scrolls both ways under it with the minimap pinned
/// to its right edge. While a push is asked or running, the push confirm takes the diff's
/// (or the clean note's) place under the header.
@MainActor
struct GitDiffPane: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The diff row at the top of the pane, and how many rows the pane shows.
    @State private var topRow = 0
    @State private var visibleCount = 0

    var body: some View {
        let file = state.gitSelectedFile
        let phase = state.gitPhase
        let asking = phase == .confirming || phase == .pushing
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header(file: file)
                .padding(.horizontal, Theme.Size.previewHPadding)

            // The content and the confirm both stay in the tree; only their parts come and go,
            // so each part's transition fires.
            ZStack(alignment: .top) {
                if !asking {
                    ZStack(alignment: .top) {
                        content(file)
                            .id(file?.path ?? "")
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(Theme.Motion.paneSwapTransition)
                }
                GitPushConfirm(state: state, phase: phase)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.previewFade, value: file?.path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: file?.path) { _, _ in topRow = 0 }
    }

    @ViewBuilder
    private func content(_ file: FileChange?) -> some View {
        if let file {
            let lines = AppState.diffLines(file)
            if lines.isEmpty {
                centred(file.kind == "new" ? "Empty file" : "No text diff")
            } else {
                GitDiffBody(
                    file: file,
                    lines: lines,
                    fileLines: snap.lineCounts[file.path],
                    topRow: $topRow,
                    visibleCount: $visibleCount
                )
            }
        } else {
            GitCleanNote(text: GitTab.emptyText(snap))
        }
    }

    private func header(file: FileChange?) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
            TreeTogglePill(collapsed: state.gitListCollapsed, enabled: file != nil, subject: "file list") {
                state.toggleGitList()
            }
            ZStack(alignment: .leading) {
                if let file {
                    HStack(spacing: Theme.Size.spaceM) {
                        PathLabel(path: file.path)
                            .layoutPriority(1)
                        GitKindBadge(kind: file.kind)
                        DiffCounts(added: file.added, removed: file.removed)
                            .fixedSize()
                    }
                    .id(file.path)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func centred(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The diff pane with nothing to show: a green check, then "Nothing to commit · up to date".
@MainActor
private struct GitCleanNote: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            DoneCheckGlyph(size: Theme.Size.gitCleanCircle)
            Text(text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The push confirm in the diff pane: "Push 3 commits to origin/seadevil?", then "⏎ or
/// Push again" and Cancel (esc). The Push pill itself stays in the header, under the pointer.
/// Stays in the tree with nothing in it outside the confirm, so its parts transition: they
/// rise in and drop out. While git pushes the question becomes "Pushing to origin/seadevil…"
/// and the hint and Cancel fade out.
@MainActor
private struct GitPushConfirm: View {
    @ObservedObject var state: AppState
    let phase: GitPushPhase

    var body: some View {
        let confirming = phase == .confirming
        let pushing = phase == .pushing
        VStack(spacing: Theme.Size.spaceM) {
            if confirming || pushing {
                ZStack {
                    Text(pushing ? "Pushing to " + state.gitPushTarget + Theme.Glyphs.ellipsis : state.gitConfirmText)
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.Colors.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: Theme.Size.gitConfirmMaxWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(pushing)
                        .transition(.opacity)
                }
                .transition(Theme.Motion.paneSwapTransition)
            }
            if confirming {
                HStack(spacing: Theme.Size.spaceM) {
                    HStack(spacing: Theme.Size.spaceS) {
                        Keycap(Theme.Keys.enter)
                        Text("or Push again")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                    }
                    .fixedSize()
                    ActionSegment(title: "Cancel", key: Theme.Keys.escape, role: .neutral) {
                        state.cancelGitConfirm()
                    }
                }
                .transition(Theme.Motion.paneSwapTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(confirming)
    }
}

/// "M", "A" or "D" in a small badge after the file's name.
@MainActor
private struct GitKindBadge: View {
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
        case "deleted": return "D"
        default: return "M"
        }
    }

    private var help: String {
        switch kind {
        case "new": return "added"
        case "deleted": return "deleted"
        default: return "modified"
        }
    }
}

/// The diff itself: every line whole (the pane scrolls sideways as the Files preview
/// does), both line numbers, the changed words tinted, the minimap on the right edge
/// outside the scrolling content. Tracks the top row for the minimap's visible range; a
/// minimap press scrolls it.
@MainActor
private struct GitDiffBody: View {
    let file: FileChange
    let lines: [DiffLine]
    let fileLines: Int?
    @Binding var topRow: Int
    @Binding var visibleCount: Int
    /// Worked out once per diff, not on every scroll step (the header re-renders with it).
    @State private var words: [Int: [Range<Int>]] = [:]
    @State private var minimap: DiffMinimapModel?
    /// The longest line in characters (prefix and text), for the content's width.
    @State private var longest = 0

    private nonisolated static let space = "gitDiffScroll"

    private struct Inputs: Equatable {
        var lines: [DiffLine]
        var fileLines: Int?
    }

    var body: some View {
        GeometryReader { geo in
            let rowWidth = max(0, geo.size.width - Theme.Size.diffMinimapReserve)
            // A lazy stack only knows its loaded rows, so its width is set from the longest
            // line to give the scroll view its sideways range.
            let textWidth = Theme.Size.previewHPadding * 2 + 2 * Theme.Size.diffLineNumberWidth
                + 2 * Theme.Size.previewGutterSpacing + CGFloat(longest) * Theme.Fonts.monoSmallAdvance
            let contentWidth = max(rowWidth, textWidth.rounded(.up))
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            WideDiffLineRow(line: lines[index], words: words[index] ?? [], minWidth: contentWidth)
                                .id(index)
                        }
                        if file.patchTruncated {
                            Text(truncatedNote)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .padding(.leading, 2 * (Theme.Size.diffLineNumberWidth + Theme.Size.previewGutterSpacing) + Theme.Size.previewHPadding)
                                .frame(height: Theme.Size.diffLineHeight)
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.vertical, Theme.Size.previewVPadding)
                    .padding(.trailing, Theme.Size.diffMinimapReserve)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.space)).minY
                    } action: { minY in
                        let row = Int(((-minY - Theme.Size.previewVPadding) / Theme.Size.diffLineHeight).rounded())
                        let clamped = max(0, min(max(0, lines.count - 1), row))
                        if clamped != topRow { topRow = clamped }
                    }
                }
                .coordinateSpace(.named(Self.space))
                .overlay(alignment: .topTrailing) {
                    if let minimap {
                        DiffMinimap(model: minimap, visibleRows: visibleRange) { row in
                            let target = max(0, row - visibleCount / 2)
                            proxy.scrollTo(target, anchor: .topLeading)
                        }
                        .padding(.vertical, Theme.Size.diffMinimapInset)
                        .padding(.trailing, Theme.Size.diffMinimapInset)
                    }
                }
            }
            .onAppear { visibleCount = Int(geo.size.height / Theme.Size.diffLineHeight) }
            .onChange(of: Inputs(lines: lines, fileLines: fileLines), initial: true) { _, inputs in
                words = WordDiff.marks(inputs.lines)
                minimap = DiffMinimapModel(lines: inputs.lines, fileLines: inputs.fileLines)
                longest = inputs.lines.map { $0.prefix.count + $0.text.count }.max() ?? 0
            }
            .onChange(of: geo.size.height) { _, height in
                visibleCount = Int(height / Theme.Size.diffLineHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                .fill(Theme.Colors.inset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous))
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
        let count = missing > 0 ? "\(missing) more lines" : "more lines"
        return Theme.Glyphs.ellipsis + " " + count + " in the editor"
    }
}
