// CodeLines.swift
// One line of a file or a diff with its dim number columns, generic over its content:
// clipped to its box (the diff box), or whole for a pane that scrolls sideways. And the
// box that scrolls both ways around such lines (the Files preview, the Git tool's
// reviewer diff).

import SwiftUI

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
