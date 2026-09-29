// MarkdownView.swift
// The Files tool's Preview for .md, .markdown and .mdx files: a small block renderer in
// SwiftUI. Blocks: ATX (# to ####) and setext headings, paragraphs, bullet and numbered
// lists (nested by indent), fenced code, block quotes, horizontal rules, pipe tables, and
// YAML front matter as a code block. Inline bold, italic, code, strikethrough and links come
// from AttributedString's inline-only Markdown. No HTML, images, footnotes or indented code
// blocks: those show as plain text.
//
// It fills the same box PreviewLines does (inset fill, snippet radius) and scrolls
// vertically; wide code blocks and tables scroll sideways on their own.

import SwiftUI

@MainActor
struct MarkdownView: View {
    let lines: [String]
    /// "… 212 more lines" when the file was capped.
    let footer: String?

    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Size.markdownBlockSpacing) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block)
                }
                if let footer {
                    Text(footer)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
            }
            .padding(Theme.Size.markdownPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(Theme.Colors.markdownLink)
        .environment(\.openURL, OpenURLAction { url in
            // Web links open in the browser; relative links in a repo lead nowhere from here.
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                .fill(Theme.Colors.inset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous))
        .onChange(of: lines, initial: true) { _, lines in
            blocks = MarkdownParser.parse(lines)
        }
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
