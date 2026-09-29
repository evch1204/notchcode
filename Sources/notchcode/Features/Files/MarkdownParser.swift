// MarkdownParser.swift
// Turns a Markdown file's lines into MarkdownView's blocks: headings, paragraphs, lists,
// fenced code, quotes, rules, pipe tables and YAML front matter, with inline styling as an
// AttributedString (links, code spans).

import SwiftUI

enum MarkdownParser {

    static func parse(_ source: [String]) -> [MarkdownBlock] {
        let lines = source.map { $0.replacingOccurrences(of: "\t", with: "    ") }
        var kinds: [MarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            kinds.append(.paragraph(inline(paragraph.joined(separator: " "))))
            paragraph = []
        }

        // YAML front matter at the very top reads as a code block.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            kinds.append(.code(Array(lines[0...end])))
            i = end + 1
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code: ``` or ~~~ up to the matching fence (or the end of what was read).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                kinds.append(.code(body))
                continue
            }

            // Setext: a line of = or - under paragraph text makes it a heading.
            if !paragraph.isEmpty, isUnderline(trimmed) {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                kinds.append(.heading(level: level, text: inline(paragraph.joined(separator: " "))))
                paragraph = []
                i += 1
                continue
            }

            if let (level, text) = atxHeading(trimmed) {
                flushParagraph()
                kinds.append(.heading(level: level, text: inline(text)))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                kinds.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                // Blank quote lines break paragraphs; the rest joins like prose.
                let text = quoted
                    .split(separator: "", omittingEmptySubsequences: true)
                    .map { $0.joined(separator: " ") }
                    .joined(separator: "\n")
                kinds.append(.quote(inline(text)))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(cells(t))
                    i += 1
                }
                let columns = max(header.count, rows.map(\.count).max() ?? 0)
                func padded(_ row: [String]) -> [AttributedString] {
                    (row + Array(repeating: "", count: max(0, columns - row.count))).map(inline)
                }
                kinds.append(.table(header: padded(header), rows: rows.map(padded)))
                continue
            }

            if listItem(line) != nil {
                flushParagraph()
                var items: [(marker: String, text: String, depth: Int)] = []
                while i < lines.count {
                    let current = lines[i]
                    let t = current.trimmingCharacters(in: .whitespaces)
                    if let item = listItem(current) {
                        items.append(item)
                        i += 1
                    } else if t.isEmpty {
                        // A blank line inside a list continues it only if another item follows.
                        guard i + 1 < lines.count, listItem(lines[i + 1]) != nil || indent(lines[i + 1]) >= 2 else { break }
                        i += 1
                    } else if indent(current) >= 2, !items.isEmpty, !t.hasPrefix("```"), !t.hasPrefix("~~~") {
                        // An indented continuation line joins the item above.
                        items[items.count - 1].text += " " + t
                        i += 1
                    } else {
                        break
                    }
                }
                kinds.append(.list(items.map { (marker: $0.marker, text: inline($0.text), depth: $0.depth) }))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return kinds.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    // MARK: Line tests

    private static func indent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func atxHeading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration.
        while text.hasSuffix("#") { text.removeLast() }
        return (min(hashes, 4), text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func isUnderline(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") || t.hasPrefix(":") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ trimmed: String) -> [String] {
        var t = Substring(trimmed)
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "- item", "* item", "+ item", "1. item", "2) item", with the depth from its indent.
    private static func listItem(_ line: String) -> (marker: String, text: String, depth: Int)? {
        let depth = min(indent(line) / 2, 3)
        let t = line.trimmingCharacters(in: .whitespaces)
        if let first = t.first, "-*+".contains(first), t.dropFirst().hasPrefix(" ") {
            guard !isRule(t) else { return nil }
            return (Theme.Glyphs.bullet, String(t.dropFirst(2)), depth)
        }
        let digits = t.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")",
              after.dropFirst().hasPrefix(" ") else { return nil }
        return (digits + ".", String(after.dropFirst(2)), depth)
    }

    // MARK: Inline

    /// Bold, italic, code, strikethrough and links. Code runs take the small mono font on
    /// the code fill; links take the link colour.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let runs = result.runs.map { ($0.range, $0.link != nil, $0.inlinePresentationIntent?.contains(.code) ?? false) }
        for (range, isLink, isCode) in runs {
            if isLink {
                result[range].swiftUI.foregroundColor = Theme.Colors.markdownLink
            }
            if isCode {
                result[range].swiftUI.font = Theme.Fonts.monoSmall
                result[range].swiftUI.backgroundColor = Theme.Colors.markdownCodeFill
            }
        }
        return result
    }
}
