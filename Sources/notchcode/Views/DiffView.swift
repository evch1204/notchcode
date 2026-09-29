// DiffView.swift
// A file's diff as Claude Code recorded it: a rounded box, two dim line-number columns
// (old, new), then the line with its +/− prefix, in the mono size the Files preview uses.
// Added rows green on a faint green, removed red on a faint red, context grey, hunk
// headers blue. Lines never wrap and never scroll sideways: long ones are clipped. Scrolls
// vertically inside a capped height, with "… 9 more lines · scroll" at the bottom of the
// box while more is below. Also the expandable file row that owns it, shared by the
// Changes tool and the commit card.
//
// The pieces the Git tool's reviewer diff adds, generic over [DiffLine]: a row that never
// clips (for a pane that scrolls sideways), word highlights inside paired −/+ lines, and
// the minimap of where the changes sit in the whole file.

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

    var wordBackground: Color {
        kind == .added ? Theme.Colors.diffAddedWord : Theme.Colors.diffRemovedWord
    }
}

/// One diff line for a pane that scrolls both ways: the two numbers, then the whole line,
/// never wrapped and never clipped; at least `minWidth` wide so its tint spans the pane.
/// The words in `words` (character offsets into the text) carry the stronger word tint.
@MainActor
struct WideDiffLineRow: View {
    let line: DiffLine
    var words: [Range<Int>] = []
    let minWidth: CGFloat

    var body: some View {
        HStack(spacing: Theme.Size.previewGutterSpacing) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(text)
                .foregroundStyle(line.textColor)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(Theme.Fonts.monoSmall)
        .lineLimit(1)
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(height: Theme.Size.diffLineHeight)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(line.background)
    }

    private var text: AttributedString {
        var out = AttributedString(line.prefix)
        guard !words.isEmpty else {
            out += AttributedString(line.text)
            return out
        }
        let chars = Array(line.text)
        var cursor = 0
        for range in words where range.lowerBound >= cursor && range.upperBound <= chars.count {
            if range.lowerBound > cursor { out += AttributedString(String(chars[cursor..<range.lowerBound])) }
            var word = AttributedString(String(chars[range]))
            word.backgroundColor = line.wordBackground
            out += word
            cursor = range.upperBound
        }
        if cursor < chars.count { out += AttributedString(String(chars[cursor...])) }
        return out
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Theme.Colors.diffLineNumber)
            .frame(width: Theme.Size.diffLineNumberWidth, alignment: .trailing)
    }
}

// MARK: - Word highlights

/// The words that differ between a removed line and the added line that replaced it.
/// Inside each hunk, a run of removed lines followed by a run of added lines is paired
/// line by line (the first removed with the first added, and so on); a line with no
/// partner stays as it is. Each pair is split into whitespace-separated words, and the
/// words outside their longest common subsequence are marked. A pair with no word in
/// common, or longer than `wordDiffMaxTokens`, is left with the line tint alone.
enum WordDiff {
    /// Line index -> character ranges to tint, merged across the spaces between them.
    static func marks(_ lines: [DiffLine]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            for offset in 0..<pairs {
                let old = index + offset
                let new = removedEnd + offset
                if let (a, b) = compare(lines[old].text, lines[new].text) {
                    if !a.isEmpty { result[old] = a }
                    if !b.isEmpty { result[new] = b }
                }
            }
            index = max(addedEnd, index + 1)
        }
        return result
    }

    /// A word or a run of spaces, with its character offsets.
    private struct Token {
        var text: Substring
        var range: Range<Int>
        var isSpace: Bool
    }

    private static func tokens(_ line: String) -> [Token] {
        var out: [Token] = []
        var start = line.startIndex
        var offset = 0
        while start < line.endIndex {
            let space = line[start].isWhitespace
            var end = start
            var length = 0
            while end < line.endIndex, line[end].isWhitespace == space {
                end = line.index(after: end)
                length += 1
            }
            out.append(Token(text: line[start..<end], range: offset..<(offset + length), isSpace: space))
            start = end
            offset += length
        }
        return out
    }

    /// The differing words of each side, or nil when the pair shares no word (or is too long).
    private static func compare(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>])? {
        let a = tokens(old)
        let b = tokens(new)
        let wa = a.indices.filter { !a[$0].isSpace }
        let wb = b.indices.filter { !b[$0].isSpace }
        guard !wa.isEmpty, !wb.isEmpty,
              wa.count <= Theme.Limits.wordDiffMaxTokens, wb.count <= Theme.Limits.wordDiffMaxTokens else { return nil }
        // Longest common subsequence over the words.
        let n = wa.count, m = wb.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[wa[i]].text == b[wb[j]].text
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        guard table[0][0] > 0 else { return nil }
        var keepA = Set<Int>(), keepB = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if a[wa[i]].text == b[wb[j]].text {
                keepA.insert(wa[i]); keepB.insert(wb[j]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (ranges(a, keep: keepA), ranges(b, keep: keepB))
    }

    /// The changed words' ranges; two changed words with only spaces between them become one.
    private static func ranges(_ tokens: [Token], keep: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var pendingSpace: Range<Int>?
        for (index, token) in tokens.enumerated() {
            if token.isSpace {
                pendingSpace = token.range
                continue
            }
            if keep.contains(index) {
                pendingSpace = nil
                continue
            }
            if let last = out.last, let space = pendingSpace, last.upperBound == space.lowerBound {
                out[out.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                out.append(token.range)
            }
            pendingSpace = nil
        }
        return out
    }
}

// MARK: - Minimap

/// Where a diff's changes sit in the whole file, as fractions of its length, and which rows
/// of the diff sit where. Lines are placed by their new-file number (a removed line where
/// it used to be, just before the next new line); a deleted file by its old numbers.
struct DiffMinimapModel: Equatable {
    struct Mark: Equatable {
        var start: Double
        var length: Double
        var added: Bool
    }

    /// Each diff row's line in the file (1-based).
    var anchors: [Int]
    /// Lines in the whole file.
    var total: Int
    var marks: [Mark]

    init(lines: [DiffLine], fileLines: Int?) {
        let usesOld = !lines.contains { $0.kind == .added || $0.kind == .context }
        var anchors: [Int] = []
        var next = 1
        for line in lines {
            let anchor: Int
            if line.kind == .hunk {
                // "@@ -187,8 +196,37 @@": the hunk starts at its new (or old) start line.
                let start = Self.hunkStart(line.text, old: usesOld) ?? next
                anchor = start
                next = start
            } else if usesOld {
                anchor = line.oldLine ?? next
            } else {
                switch line.kind {
                case .added, .context:
                    anchor = line.newLine ?? next
                    next = anchor + 1
                case .removed, .hunk:
                    anchor = next
                }
            }
            anchors.append(max(1, anchor))
        }
        self.anchors = anchors
        let total = max(1, fileLines ?? 0, anchors.max() ?? 1)
        self.total = total

        var marks: [Mark] = []
        var index = 0
        while index < lines.count {
            let kind = lines[index].kind
            guard kind == .added || kind == .removed else { index += 1; continue }
            var end = index
            while end < lines.count, lines[end].kind == kind { end += 1 }
            let first = anchors[index]
            let span = usesOld || kind == .added ? max(1, anchors[end - 1] - first + 1) : end - index
            marks.append(Mark(start: Double(first - 1) / Double(total),
                              length: Double(span) / Double(total),
                              added: kind == .added))
            index = end
        }
        self.marks = marks
    }

    /// The start line after "-" (old) or "+" (new) in a hunk header.
    private static func hunkStart(_ text: String, old: Bool) -> Int? {
        let marker: Character = old ? "-" : "+"
        guard let range = text.firstIndex(of: marker) else { return nil }
        let digits = text[text.index(after: range)...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// The fraction of the file where a row sits.
    func fraction(row: Int) -> Double {
        guard anchors.indices.contains(row) else { return row <= 0 ? 0 : 1 }
        return Double(anchors[row] - 1) / Double(total)
    }

    /// The first row at or after a point in the file (the last row past the end).
    func row(at fraction: Double) -> Int {
        let line = Int((fraction * Double(total)).rounded(.down)) + 1
        return anchors.firstIndex { $0 >= line } ?? max(0, anchors.count - 1)
    }
}

/// The minimap: a slim track, green and red marks where lines were added and removed,
/// and a ringed box over what the pane shows. A click jumps there; a drag scrubs.
@MainActor
struct DiffMinimap: View {
    let model: DiffMinimapModel
    /// The rows at the top and bottom of the pane.
    let visibleRows: ClosedRange<Int>
    let onJump: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.diffMinimap, style: .continuous)
                    .fill(Theme.Colors.diffMinimapTrack)
                ForEach(Array(model.marks.enumerated()), id: \.offset) { item in
                    let mark = item.element
                    RoundedRectangle(cornerRadius: Theme.Radius.diffMinimap / 2, style: .continuous)
                        .fill(mark.added ? Theme.Colors.green : Theme.Colors.red)
                        .frame(height: max(Theme.Size.diffMinimapMinMark, mark.length * height))
                        .offset(y: min(height - Theme.Size.diffMinimapMinMark, mark.start * height))
                }
                viewport(height: height)
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.y / max(1, height)))
                        onJump(model.row(at: fraction))
                    }
            )
        }
        .frame(width: Theme.Size.diffMinimapWidth)
        .help("Where the changes are in the file")
    }

    private func viewport(height: CGFloat) -> some View {
        let top = model.fraction(row: visibleRows.lowerBound) * height
        let bottom = (model.fraction(row: visibleRows.upperBound) + 1 / Double(model.total)) * height
        let boxHeight = max(Theme.Size.diffMinimapMinViewport, bottom - top)
        let y = min(max(0, height - boxHeight), top)
        return RoundedRectangle(cornerRadius: Theme.Radius.diffMinimapViewport, style: .continuous)
            .fill(Theme.Colors.diffMinimapViewport)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.diffMinimapViewport, style: .continuous)
                    .strokeBorder(Theme.Colors.diffMinimapRing, lineWidth: Theme.Size.diffMinimapRingLine)
            )
            .frame(height: boxHeight)
            .padding(.horizontal, -Theme.Size.diffMinimapViewportOutset)
            .offset(y: y)
            .allowsHitTesting(false)
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
