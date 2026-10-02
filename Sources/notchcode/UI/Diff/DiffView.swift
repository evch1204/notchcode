// DiffView.swift
// A file's diff as Claude Code recorded it: a rounded box, two dim line-number columns
// (old, new), then the line with its +/− prefix, in the mono size the Files preview uses.
// Added rows green on a faint green, removed red on a faint red, context grey, hunk
// headers blue. Lines never wrap. In this box they never scroll sideways either: long ones
// are clipped (the Git tool's rows scroll sideways instead). Scrolls
// vertically inside a capped height, with "… 9 more lines · scroll" at the bottom of the
// box while more is below. The word highlights inside paired −/+ lines are
// Core/Diff/WordDiff.swift.

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
                        CodeLineRow(item.element)
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
        .snippetBox()
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
            return Format.moreLines(below) + Theme.Glyphs.separator + "scroll"
        }
        if file.patchTruncated {
            let shown = lines.filter { $0.kind == .added || $0.kind == .removed }.count
            let missing = max(0, file.added + file.removed - shown)
            return Format.moreLines(missing) + " in the editor"
        }
        return "end of diff"
    }
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

    var wordBackground: Color {
        kind == .added ? Theme.Colors.diffAddedWord : Theme.Colors.diffRemovedWord
    }

    /// The prefix and the text, the words in `words` on the word tint.
    func styledText(words: [Range<Int>]) -> AttributedString {
        var out = AttributedString(prefix)
        guard !words.isEmpty else {
            out += AttributedString(text)
            return out
        }
        let chars = Array(text)
        var cursor = 0
        for range in words where range.lowerBound >= cursor && range.upperBound <= chars.count {
            if range.lowerBound > cursor { out += AttributedString(String(chars[cursor..<range.lowerBound])) }
            var word = AttributedString(String(chars[range]))
            word.backgroundColor = wordBackground
            out += word
            cursor = range.upperBound
        }
        if cursor < chars.count { out += AttributedString(String(chars[cursor...])) }
        return out
    }
}

/// The line at the bottom of a diff's box ("… 9 more lines · scroll"), in the caption
/// size, lined up with the diff's text column.
@MainActor
private struct DiffNoteRow: View {
    let text: String

    var body: some View {
        CodeLineRow(numbers: [nil, nil]) {
            Text(text)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        }
    }
}
