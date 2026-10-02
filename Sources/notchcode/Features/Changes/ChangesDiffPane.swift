// ChangesDiffPane.swift
// The Changes tool's diff pane, right of the timeline: the Git tool's stage for one chip. A
// 20 pt header (the ⌘B pill that hides the timeline, the file's name, its M / A badge, the
// counts, then "turn 3 · 2:32 PM" so a file edited in two turns is never confused), then the
// shared reviewer diff with its minimap. The minimap's scale is the file's length on disk
// when it is there; otherwise it draws the diff rows only. The header rises first and the
// diff one beat later; moving to another chip crossfades the diff.

import SwiftUI

@MainActor
struct ChangesDiffPane: View {
    @ObservedObject var state: AppState
    let turn: TranscriptTurn
    let file: FileChange
    /// The turn's number, counted from the session's first.
    let number: Int
    @State private var lineCount: Int?

    var body: some View {
        let key = AppState.changesChipID(ChangesChipKey(turnId: turn.id, path: file.path))
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header
                .padding(.horizontal, Theme.Size.previewHPadding)
                .frame(height: Theme.Size.changesRowHeight)
                .riseIn(0)
            ZStack(alignment: .top) {
                content
                    .id(key)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .riseIn(1)
        }
        .animation(Theme.Motion.previewFade, value: key)
        .task(id: absolutePath) { lineCount = await Self.countLines(absolutePath) }
    }

    @ViewBuilder
    private var content: some View {
        let lines = AppState.diffLines(file)
        if lines.isEmpty {
            EmptyNote(text: file.kind == "new" ? "Empty file" : "No text diff")
        } else {
            ReviewerDiff(file: file, lines: lines, fileLines: lineCount)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Size.spaceM) {
            TreeTogglePill(collapsed: state.changesTool.columnHidden, enabled: true, subject: "timeline") {
                state.toggleChangesColumn()
            }
            HStack(spacing: Theme.Size.spaceM) {
                PathLabel(path: file.path)
                    .layoutPriority(1)
                FileKindBadge(kind: file.kind)
                DiffCounts(added: file.added, removed: file.removed)
                    .fixedSize()
                Text("turn \(number)" + Theme.Glyphs.separator + Format.timeOfDay(turn.startedAt))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
            .id(file.path + turn.id)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The file on disk, from the session's folder.
    private var absolutePath: String {
        Paths.absolute(file.path, cwd: state.focusedSession?.cwd ?? "")
    }

    /// Lines in the file on disk, read off the main thread; nil when it is not there (or huge).
    private static func countLines(_ path: String) async -> Int? {
        await Task.detached(priority: .utility) {
            let limit = Theme.Limits.changesLineCountBytes
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  size <= limit,
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            return text.fileLines.count
        }.value
    }
}
