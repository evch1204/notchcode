// MarkdownView.swift
// The Files tool's Preview for .md, .markdown and .mdx files: a small block renderer in
// SwiftUI. Blocks: ATX (# to ####) and setext headings, paragraphs, bullet and numbered
// lists (nested by indent), fenced code, block quotes, horizontal rules, pipe tables, and
// YAML front matter as a code block. Inline bold, italic, code, strikethrough and links come
// from AttributedString's inline-only Markdown. No HTML, images, footnotes or indented code
// blocks: those show as plain text.
//
// It fills the same box PreviewLines does (inset fill, snippet radius) and scrolls
// vertically; wide code blocks and tables scroll sideways on their own. A plan request's
// card renders its plan with it too, where ↑↓ move it by blocks.

import SwiftUI

private let markdownScrollSpace = "markdownScroll"

@MainActor
struct MarkdownView: View {
    let lines: [String]
    /// "… 212 more lines" when the file was capped.
    let footer: String?
    /// Inside a plan card: ↑↓ arrive here as block steps. The Files tool passes nil.
    var scroll: RequestDiffScroll? = nil

    @State private var blocks: [MarkdownBlock] = []
    /// While `scroll` drives it: each laid-out block's top (a block the lazy stack dropped keeps
    /// its last one, far off screen), the content's frame and the viewport's height, in the
    /// scroll view's space. ↑↓ pick their target from these.
    @State private var blockTops: [Int: CGFloat] = [:]
    @State private var contentFrame: CGRect = .zero
    @State private var viewportHeight: CGFloat = 0

    /// Where a scrolled-to block's top sits: one content margin below the box's edge.
    private let edge = Theme.Size.markdownPadding

    var body: some View {
        scrollable
        .tint(Theme.Colors.markdownLink)
        .environment(\.openURL, OpenURLAction { url in
            // Web links open in the browser; relative links in a repo lead nowhere from here.
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .snippetBox()
        .onChange(of: lines, initial: true) { _, lines in
            blocks = MarkdownParser.parse(lines)
        }
    }

    /// The scroll view; it tracks its blocks only when `scroll` drives it.
    @ViewBuilder
    private var scrollable: some View {
        if scroll == nil {
            ScrollView(.vertical, showsIndicators: false) { content(tracked: false) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        content(tracked: true)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(markdownScrollSpace)) } action: { contentFrame = $0 }
                    }
                    .coordinateSpace(name: markdownScrollSpace)
                    // The margin lives outside the content, so a block scrolled to the top keeps it.
                    .contentMargins(.vertical, edge, for: .scrollContent)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                    .onChange(of: scroll) { _, command in
                        // scrollTo, not a scrollPosition binding: at the end the last target cannot
                        // reach the top, and setting the same id again would not move anything.
                        guard let command, let next = target(for: command.delta) else { return }
                        withAnimation(Theme.Motion.tap) { proxy.scrollTo(next, anchor: .top) }
                    }
                }
                if let note {
                    Text(note)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .lineLimit(1)
                        .frame(height: Theme.Size.diffLineHeight)
                        .padding(.horizontal, edge)
                        .padding(.bottom, Theme.Size.previewVPadding)
                }
            }
        }
    }

    /// ↓: the `delta`-th block whose top is below the edge (the last block when fewer), nothing
    /// once the content's bottom is in view. ↑: the `|delta|`-th block above the edge (the first
    /// when fewer). Block ids run in document order, so only the block at the edge is measured:
    /// a lazy stack has not laid out the blocks further up.
    private func target(for delta: Int) -> Int? {
        // The first block whose top is at or below the edge; every block before it is above.
        let first = blockTops.filter { $0.value > edge - 1 }.map(\.key).min()
            ?? (blockTops.keys.max() ?? -1) + 1
        if delta > 0 {
            guard contentFrame.maxY > viewportHeight + 1 else { return nil }
            let atEdge = (blockTops[first] ?? .infinity) <= edge + 1
            return min(blocks.count - 1, first + delta - (atEdge ? 0 : 1))
        }
        return first > 0 ? max(0, first + delta) : nil
    }

    /// "more below · scroll" while the content runs past the box, "end of plan" once scrolled
    /// to the bottom of a plan that did not fit, nil when it all fits.
    private var note: String? {
        guard viewportHeight > 0, contentFrame.height + 2 * edge > viewportHeight + 1 else { return nil }
        return contentFrame.maxY > viewportHeight + 1 ? "more below" + Theme.Glyphs.separator + "scroll" : "end of plan"
    }

    private func content(tracked: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Size.markdownBlockSpacing) {
            ForEach(blocks) { block in
                if tracked {
                    MarkdownBlockView(block: block)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(markdownScrollSpace)).minY } action: {
                            blockTops[block.id] = $0
                        }
                } else {
                    MarkdownBlockView(block: block)
                }
            }
            if let footer {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Size.markdownPadding)
        .padding(.vertical, tracked ? 0 : Theme.Size.markdownPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Blocks

struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case list([(marker: String, text: AttributedString, depth: Int)])
        case code([String])
        case quote(AttributedString)
        case rule
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    let id: Int
    let kind: Kind
}

@MainActor
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(level <= 2 ? Theme.Colors.markdownHeading : Theme.Colors.markdownText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, block.id == 0 ? 0 : Theme.Size.markdownHeadingTopSpacing)

        case .paragraph(let text):
            prose(text)

        case .list(let items):
            VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Size.markdownMarkerGap) {
                        Text(item.marker)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.markdownMarker)
                        prose(item.text)
                    }
                    .padding(.leading, CGFloat(item.depth) * Theme.Size.markdownListIndent)
                }
            }

        case .code(let lines):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index].isEmpty ? " " : lines[index])
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Colors.previewText)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: Theme.Size.previewLineHeight, alignment: .leading)
                    }
                }
                .padding(Theme.Size.markdownCodePadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                    .fill(Theme.Colors.markdownCodeFill)
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: Theme.Size.markdownQuoteGap) {
                Rectangle()
                    .fill(Theme.Colors.markdownQuoteRule)
                    .frame(width: Theme.Size.markdownQuoteRule)
                prose(text)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(Theme.Colors.markdownRule)
                .frame(height: Theme.Size.hairline)
                .frame(maxWidth: .infinity)

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(header[column], font: Theme.Fonts.captionSemibold, color: Theme.Colors.markdownHeading)
                        }
                    }
                    .background(Theme.Colors.markdownTableHeader)
                    ForEach(rows.indices, id: \.self) { row in
                        Rectangle()
                            .fill(Theme.Colors.markdownRule)
                            .frame(height: Theme.Size.hairline)
                            .gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                cell(rows[row][column], font: Theme.Fonts.caption, color: Theme.Colors.markdownText)
                            }
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(Theme.Colors.markdownRule, lineWidth: Theme.Size.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            }
        }
    }

    private func prose(_ text: AttributedString) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.markdownText)
            .lineSpacing(Theme.Size.markdownLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ text: AttributedString, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Size.markdownCellHPadding)
            .padding(.vertical, Theme.Size.markdownCellVPadding)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Theme.Fonts.title
        case 2, 3: return Theme.Fonts.bodySemibold
        default: return Theme.Fonts.captionSemibold
        }
    }
}
