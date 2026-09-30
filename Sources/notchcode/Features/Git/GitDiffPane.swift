// GitDiffPane.swift
// The Git tool's right pane: the selected file's reviewer diff under a header that stays on
// top, the clean note when there is nothing to commit, the commit form (summary, description,
// "Commit 3 files to main"), and the confirm of a publish, push or pull.

import AppKit
import Carbon
import SwiftUI

// MARK: - The reviewer diff

/// The right pane: a header that stays on top (the ⌘B pill, the name, M/A/D, the counts),
/// then the selected file's diff, which scrolls both ways under it with the minimap pinned
/// to its right edge. While a publish, push or pull is asked or running, the confirm takes the
/// diff's (or the clean note's) place under the header; while the owner writes a commit, the
/// form does, and the header reads "Commit to main".
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
        let asking = GitConfirm.shows(phase)
        let composing = !asking && state.gitDraft.composing
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header(file: composing ? nil : file, composing: composing)
                .padding(.horizontal, Theme.Size.previewHPadding)

            // The content, the form and the confirm all stay in the tree; only their parts come
            // and go, so each part's transition fires.
            ZStack(alignment: .top) {
                if !asking && !composing {
                    ZStack(alignment: .top) {
                        content(file)
                            .id(file?.path ?? "")
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(Theme.Motion.paneSwapTransition)
                }
                if composing {
                    GitCommitForm(state: state)
                        .transition(Theme.Motion.paneSwapTransition)
                }
                GitConfirm(state: state, phase: phase)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.previewFade, value: file?.path)
        .animation(Theme.Motion.pushConfirm, value: composing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: file?.path) { _, _ in topRow = 0 }
    }

    @ViewBuilder
    private func content(_ file: FileChange?) -> some View {
        if let file {
            let lines = AppState.diffLines(file)
            if lines.isEmpty {
                EmptyNote(text: file.kind == "new" ? "Empty file" : "No text diff")
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

    private func header(file: FileChange?, composing: Bool) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
            TreeTogglePill(collapsed: state.gitListCollapsed, enabled: state.gitSelectedFile != nil, subject: "file list") {
                state.toggleGitList()
            }
            ZStack(alignment: .leading) {
                if composing {
                    HStack(spacing: Theme.Size.spaceS) {
                        Text("Commit to")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .fixedSize()
                        Text(snap.branch ?? "HEAD")
                            .font(Theme.Fonts.monoCaption)
                            .foregroundStyle(Theme.Colors.gitBranch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .transition(.opacity)
                } else if let file {
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

/// The confirm in the diff pane: "Push 3 commits to origin/seadevil?", "Publish seadevil to
/// origin?" or "Pull 2 commits from origin/main?", then "⏎ or Push again" and Cancel (esc).
/// The pill itself stays in the header, under the pointer. Stays in the tree with nothing in
/// it outside the confirm, so its parts transition: they rise in and drop out. While git runs
/// the question becomes "Pushing to origin/seadevil…" and the hint and Cancel fade out. A
/// fetch, a commit and an undo never show it.
@MainActor
private struct GitConfirm: View {
    @ObservedObject var state: AppState
    let phase: GitPhase

    /// The confirm has the pane: a publish, push or pull is asked or running.
    static func shows(_ phase: GitPhase) -> Bool {
        switch phase {
        case .confirming(let op), .running(let op): return op.confirms
        case .idle, .done, .failed: return false
        }
    }

    var body: some View {
        var confirming = false
        if case .confirming = phase { confirming = true }
        let shown = Self.shows(phase)
        let running = shown && !confirming
        return VStack(spacing: Theme.Size.spaceM) {
            if shown {
                ZStack {
                    Text(running ? state.gitRunningText : state.gitConfirmText)
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.Colors.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: Theme.Size.gitConfirmMaxWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(running)
                        .transition(.opacity)
                }
                .transition(Theme.Motion.paneSwapTransition)
            }
            if confirming, let op = phase.op {
                HStack(spacing: Theme.Size.spaceM) {
                    HStack(spacing: Theme.Size.spaceS) {
                        Keycap(Theme.Keys.enter)
                        Text("or " + op.verb + " again")
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

/// The commit form in the diff pane, GitHub Desktop's: the summary (its length past 50, red
/// past 72; the one-file prefill as its prompt), the description filling the pane, then
/// "Commit 3 files to main ⏎", the hint or git's error, and Cancel (esc). Its fields'
/// focus is the draft's, both ways, as the branch filter's is the picker's.
@MainActor
private struct GitCommitForm: View {
    @ObservedObject var state: AppState
    @FocusState private var focus: GitDraftFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
            summary
            description
            bottom
        }
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: focus) { _, value in
            if state.gitDraft.focus != value { state.setGitDraftFocus(value) }
        }
        .onChange(of: state.gitDraft.focus, initial: true) { _, value in
            if focus != value { focus = value }
        }
    }

    private var summary: some View {
        let count = state.gitDraft.summary.count
        return HStack(spacing: Theme.Size.spaceS) {
            TextField(
                "",
                text: Binding(get: { state.gitDraft.summary }, set: { state.setGitSummary($0) }),
                prompt: Text(state.gitSummaryPlaceholder).foregroundStyle(Theme.Colors.filterPlaceholder)
            )
            .textFieldStyle(.plain)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.ink)
            .focused($focus, equals: .summary)
            .onSubmit {
                // Return itself, not the field losing focus on ⇥.
                guard let event = NSApp.currentEvent, event.type == .keyDown,
                      [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) else { return }
                state.runGitCommit()
            }
            if count > Theme.Limits.gitSummaryIdeal {
                Text("\(count)")
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(count > Theme.Limits.gitSummaryMax ? Theme.Colors.gitError : Theme.Colors.inkTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Size.gitFieldHPadding)
        .frame(height: Theme.Size.gitFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    /// The text view insets its text by `gitDescriptionTextInset`; the box's padding takes
    /// that off so the text lines up with the summary's.
    private var description: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { state.gitDraft.description }, set: { state.setGitDescription($0) }))
                .scrollContentBackground(.hidden)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
                .focused($focus, equals: .description)
            if state.gitDraft.description.isEmpty {
                Text("Description")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.filterPlaceholder)
                    .padding(.leading, Theme.Size.gitDescriptionTextInset)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Theme.Size.gitFieldHPadding - Theme.Size.gitDescriptionTextInset)
        .padding(.vertical, Theme.Size.gitFieldVPadding)
        .frame(minHeight: Theme.Size.gitDescriptionMinHeight, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    private var bottom: some View {
        let phase = state.gitPhase
        let enabled = state.gitCanCommit
        var committing = false
        if case .running(.commit) = phase { committing = true }
        return HStack(spacing: Theme.Size.spaceM) {
            ZStack(alignment: .leading) {
                if committing {
                    GitRunningPill(title: GitOp.commit.runningTitle)
                        .transition(.opacity)
                } else {
                    ActionSegment(title: state.gitCommitButtonTitle, key: Theme.Keys.enter, role: .allow) {
                        state.runGitCommit()
                    }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : Theme.Opacity.disabled)
                    .transition(.opacity)
                }
            }
            hint(phase)
            Spacer(minLength: Theme.Size.spaceM)
            ActionSegment(title: "Cancel", key: Theme.Keys.escape, role: .neutral) {
                state.cancelGitCommitForm()
            }
        }
        .animation(Theme.Motion.pushConfirm, value: committing)
    }

    @ViewBuilder
    private func hint(_ phase: GitPhase) -> some View {
        if case .failed(.commit, let message) = phase {
            Text(message)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.gitError)
                .lineLimit(2)
                .help(message)
        } else {
            Text(focus == .description
                 ? Theme.Keys.commandEnter + " from the description"
                 : Theme.Keys.enter + " commits")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .lineLimit(1)
        }
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

    private struct Inputs: Equatable {
        var lines: [DiffLine]
        var fileLines: Int?
    }

    var body: some View {
        WideLinesScroll(
            texts: lines.map { $0.prefix + $0.text },
            gutter: 2 * (Theme.Size.diffLineNumberWidth + Theme.Size.previewGutterSpacing),
            reserve: Theme.Size.diffMinimapReserve,
            footer: file.patchTruncated ? truncatedNote : nil,
            onScroll: { minY in
                let row = Int(((-minY - Theme.Size.previewVPadding) / Theme.Size.diffLineHeight).rounded())
                let clamped = max(0, min(max(0, lines.count - 1), row))
                if clamped != topRow { topRow = clamped }
            },
            onHeight: { height in
                visibleCount = Int(height / Theme.Size.diffLineHeight)
            }
        ) { contentWidth in
            ForEach(lines.indices, id: \.self) { index in
                CodeLineRow(lines[index], words: words[index] ?? [], minWidth: contentWidth)
                    .id(index)
            }
        } accessory: { proxy in
            if let minimap {
                DiffMinimap(model: minimap, visibleRows: visibleRange) { row in
                    let target = max(0, row - visibleCount / 2)
                    proxy.scrollTo(target, anchor: .topLeading)
                }
                .padding(.vertical, Theme.Size.diffMinimapInset)
                .padding(.trailing, Theme.Size.diffMinimapInset)
            }
        }
        .onChange(of: Inputs(lines: lines, fileLines: fileLines), initial: true) { _, inputs in
            words = WordDiff.marks(inputs.lines)
            minimap = DiffMinimapModel(lines: inputs.lines, fileLines: inputs.fileLines)
        }
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
        return Format.moreLines(missing) + " in the editor"
    }
}
