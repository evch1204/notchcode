// DiffMinimap.swift
// The minimap of where a diff's changes sit in the whole file: its model (the marks, and
// which rows of the diff sit where) and the slim track the reviewer diff lays down its
// right edge.

import SwiftUI

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
