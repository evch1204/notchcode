// DiffView.swift
// A file's diff as Claude Code recorded it: a rounded box, two dim line-number columns
// (old, new), then the line with its +/− prefix, in the mono size the Files preview uses.
// Added rows green on a faint green, removed red on a faint red, context grey, hunk
// headers blue. Lines never wrap. In this box they never scroll sideways either: long ones
// are clipped (the Git tool's rows scroll sideways instead). Scrolls
// vertically inside a capped height, with "… 9 more lines · scroll" at the bottom of the
// box while more is below. Also the expandable file row that owns it, shared by the
// Changes tool and the commit card.
//
// The pieces the Git tool's reviewer diff adds, generic over [DiffLine]: a row that never
// clips (for a pane that scrolls sideways) and the minimap of where the changes sit in the
// whole file. The word highlights inside paired −/+ lines are Core/Diff/WordDiff.swift.

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

/// One line of a file or a diff: one dim number column (a file's lines) or two (a diff's
/// old and new), then the text in the mono size, never wrapped. Without `minWidth` the row
/// fills its box and whatever runs past the edge is cut off (the text sits in an overlay,
/// so it never widens the row); with one the line is whole and the row at least that wide,
/// so its `tint` spans a pane that scrolls sideways.
@MainActor
struct CodeLineRow<Content: View>: View {
    let numbers: [Int?]
    var numberWidth: CGFloat = Theme.Size.diffLineNumberWidth
    var numberColor: Color = Theme.Colors.diffLineNumber
    var height: CGFloat = Theme.Size.diffLineHeight
    var minWidth: CGFloat? = nil
    var tint: Color = .clear
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if let minWidth {
                columns {
                    content
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(minWidth: minWidth, alignment: .leading)
            } else {
                columns {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            content
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .background(tint)
    }

    private func columns(@ViewBuilder text: () -> some View) -> some View {
        HStack(spacing: Theme.Size.previewGutterSpacing) {
            ForEach(Array(numbers.enumerated()), id: \.offset) { item in
                Text(item.element.map(String.init) ?? "")
                    .foregroundStyle(numberColor)
                    .frame(width: numberWidth, alignment: .trailing)
            }
            text()
        }
        .font(Theme.Fonts.monoSmall)
        .lineLimit(1)
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(height: height)
    }
}

extension CodeLineRow where Content == Text {
    /// A diff line: both numbers, the +/− prefix and text in its colour, the line's tint, and
    /// the words in `words` (character offsets into the text) with the stronger word tint.
    init(_ line: DiffLine, words: [Range<Int>] = [], minWidth: CGFloat? = nil) {
        self.init(numbers: [line.oldNumber, line.newNumber], minWidth: minWidth, tint: line.background) {
            Text(line.styledText(words: words)).foregroundStyle(line.textColor)
        }
    }
}

/// Lines in a box that scrolls both ways (the Files preview, the Git diff): a lazy stack
/// only knows its loaded rows, so the content's width is set from the longest of `texts`
/// (tabs counted as four spaces, as the rows show them) to give the scroll view its
/// sideways range, and every row gets that width so its tint spans it. `gutter` is what a
/// row puts before its text (the number columns and their gaps); `reserve` is room kept
/// clear at the right edge (the Git minimap). An optional footer line sits under the rows
/// in the text column. The Git diff tracks the content's top (`onScroll`) and the pane's
/// height (`onHeight`) and lays its minimap over the scroll (`accessory`).
@MainActor
struct WideLinesScroll<Rows: View, Accessory: View>: View {
    let texts: [String]
    let gutter: CGFloat
    var lineHeight: CGFloat = Theme.Size.diffLineHeight
    var reserve: CGFloat = 0
    var footer: String? = nil
    var onAppear: (ScrollViewProxy) -> Void = { _ in }
    var onScroll: ((CGFloat) -> Void)? = nil
    var onHeight: ((CGFloat) -> Void)? = nil
    @ViewBuilder let rows: (_ contentWidth: CGFloat) -> Rows
    @ViewBuilder let accessory: (ScrollViewProxy) -> Accessory

    /// The longest line in characters, tabs expanded as the rows show them.
    @State private var longest = 0

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.width - reserve)
            let textWidth = Theme.Size.previewHPadding * 2 + gutter + CGFloat(longest) * Theme.Fonts.monoSmallAdvance
            let contentWidth = max(available, textWidth.rounded(.up))
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rows(contentWidth)
                        if let footer {
                            Text(footer)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .padding(.leading, gutter + Theme.Size.previewHPadding)
                                .frame(height: lineHeight)
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.vertical, Theme.Size.previewVPadding)
                    .padding(.trailing, reserve)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("wideLinesScroll")).minY
                    } action: { minY in
                        onScroll?(minY)
                    }
                }
                .coordinateSpace(.named("wideLinesScroll"))
                .overlay(alignment: .topTrailing) { accessory(proxy) }
                .onAppear { onAppear(proxy) }
            }
            .onAppear { onHeight?(geo.size.height) }
            .onChange(of: geo.size.height) { _, height in onHeight?(height) }
        }
        .onChange(of: texts, initial: true) { _, texts in
            longest = texts.map { $0.count + 3 * $0.reduce(0) { $1 == "\t" ? $0 + 1 : $0 } }.max() ?? 0
        }
        .snippetBox()
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
        CodeLineRow(numbers: [nil, nil]) {
            Text(text)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
        }
    }
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
