// GitDiffPane.swift
// The Git tool's stage, the right of the well: a header that stays on top (the ⌘B pill, then
// the file, "Commit to main", or nothing for a confirm) over one of four things in one
// rectangle: the selected file's reviewer diff, the clean note, the commit form (the dock's
// summary box arrives from the rail and the description, co-authors and bottom row rise under
// it), or the confirm of a publish, push or pull (the header's sync pill arrives as its
// button). They trade places with a drop and a rise, never a slide.

import AppKit
import Carbon
import SwiftUI

// MARK: - The stage

/// The stage. While a publish, push or pull is asked or running, the confirm takes the
/// diff's (or the clean note's) place; while the owner writes a commit, the form does.
@MainActor
struct GitDiffPane: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The dock's summary box and the sync pill travel here.
    let stageSpace: Namespace.ID
    /// The diff row at the top of the pane, and how many rows the pane shows.
    @State private var topRow = 0
    @State private var visibleCount = 0

    var body: some View {
        let file = state.gitSelectedFile
        let phase = state.gitPhase
        let asking = GitConfirm.shows(phase)
        let composing = !asking && state.gitDraft.composing
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header(file: asking || composing ? nil : file, composing: composing)
                .padding(.horizontal, Theme.Size.previewHPadding)
                .frame(height: Theme.Size.gitStageHeaderHeight)

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
                GitCommitForm(state: state, shown: composing, stageSpace: stageSpace)
                GitConfirm(state: state, phase: phase, stageSpace: stageSpace)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.previewFade, value: file?.path)
        .animation(Theme.Motion.stageSwap, value: composing)
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

    /// The ⌘B pill, then the file (name, M/A/D, counts), or "Commit to main", or nothing.
    private func header(file: FileChange?, composing: Bool) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
            TreeTogglePill(collapsed: state.gitListCollapsed, enabled: state.gitSelectedFile != nil, subject: "rail") {
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

/// The stage with nothing to show: a green check, then "Nothing to commit · up to date".
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

// MARK: - The confirm

/// The confirm in the stage, its centre at 40 % of the height: "Push 3 commits to
/// origin/seadevil?", "Publish seadevil to origin?" or "Pull 2 commits from origin/main?",
/// then the sync pill itself, arrived from the header and armed ("Push 3 ⏎"), then Cancel
/// (esc). Stays in the tree with nothing in it outside the confirm, so its parts transition.
/// While git runs the question becomes "Pushing to origin/seadevil…" and the pill has gone
/// home pulsing. A fetch, a commit and an undo never show it.
@MainActor
private struct GitConfirm: View {
    @ObservedObject var state: AppState
    let phase: GitPhase
    let stageSpace: Namespace.ID

    /// The confirm has the stage: a publish, push or pull is asked or running.
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
        return GeometryReader { geo in
            VStack(spacing: Theme.Size.spaceM) {
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
                    ActionSegment(title: op.verb, key: Theme.Keys.enter, role: .allow, count: state.gitSyncCount) {
                        state.pressGitPill()
                    }
                    .help(state.gitConfirmText)
                    .matchedGeometryEffect(id: GitTab.syncPillID, in: stageSpace)
                    .popIn()
                    .transition(.opacity)
                    ActionSegment(title: "Cancel", key: Theme.Keys.escape, role: .neutral) {
                        state.cancelGitConfirm()
                    }
                    .transition(Theme.Motion.stageRise(1))
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height * Theme.Size.gitConfirmCentre)
        }
        .allowsHitTesting(confirming)
    }
}

// MARK: - The commit form

/// The commit form, GitHub Desktop's: the summary (its length past 50, red past 72; the
/// one-file prefill as its prompt), whose box is the dock's field arrived from the rail; the
/// description filling the stage; the co-authors when shown (chips, a field, the "recent"
/// suggestions); git's error when the commit failed; then "Commit 3 files to main ⏎", the
/// hint, "@ Co-author" and Cancel (esc). Always in the tree, its parts come and go with
/// `shown`, so each rises in on its own beat. Its fields' focus is the draft's, both ways.
@MainActor
private struct GitCommitForm: View {
    @ObservedObject var state: AppState
    let shown: Bool
    let stageSpace: Namespace.ID
    @FocusState private var focus: GitDraftFocus?

    var body: some View {
        let draft = state.gitDraft
        var failure: String?
        if case .failed(.commit, let message) = state.gitPhase { failure = message }
        return VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
            if shown {
                summary
                    .matchedGeometryEffect(id: GitTab.summaryID, in: stageSpace)
                    .transition(.opacity)
                description
                    .transition(Theme.Motion.stageRise(0))
                if draft.coauthorsShown {
                    coauthors
                        .transition(Theme.Motion.stageRise(1))
                }
                if let failure {
                    Text(failure)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.gitError)
                        .lineLimit(2)
                        .help(failure)
                        .transition(Theme.Motion.paneSwapTransition)
                }
                bottom
                    .transition(Theme.Motion.stageRise(1))
            }
        }
        .padding(.horizontal, Theme.Size.previewHPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(shown)
        .animation(Theme.Motion.stageSwap, value: draft.coauthorsShown)
        .onChange(of: focus) { _, value in
            if shown, state.gitDraft.focus != value { state.setGitDraftFocus(value) }
        }
        .onChange(of: state.gitDraft.focus, initial: true) { _, value in
            if focus != value { focus = value }
        }
        .onChange(of: shown) { _, now in
            // The box arrives in the same update as the draft's focus: the summary takes the
            // keys once it is in.
            guard now else { return }
            DispatchQueue.main.async { focus = .summary }
        }
        .onChange(of: draft.coauthorsShown) { _, now in
            // The same for the co-author field when the pill shows it.
            guard now, shown else { return }
            DispatchQueue.main.async { focus = .coauthor }
        }
    }

    private var committing: Bool {
        if case .running(.commit) = state.gitPhase { return true }
        return false
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
                guard Self.returnPressed else { return }
                state.runGitCommit()
            }
            if count > Theme.Limits.gitSummaryIdeal {
                Text("\(count)")
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(count > Theme.Limits.gitSummaryMax ? Theme.Colors.gitError : Theme.Colors.inkTertiary)
                    .fixedSize()
            }
        }
        .disabled(committing)
        .opacity(committing ? Theme.Opacity.gitLocked : 1)
        .padding(.horizontal, Theme.Size.gitFieldHPadding)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Size.gitFieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    /// Return itself, not the field losing focus on ⇥.
    private static var returnPressed: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
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
        .disabled(committing)
        .opacity(committing ? Theme.Opacity.gitLocked : 1)
        .padding(.horizontal, Theme.Size.gitFieldHPadding - Theme.Size.gitDescriptionTextInset)
        .padding(.vertical, Theme.Size.gitFieldVPadding)
        .frame(minHeight: Theme.Size.gitDescriptionMinHeight, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    /// "@ [Ada <ada@x.dev> ×] [Co-author · name <email>]  ⏎ adds", then "recent" and up to six
    /// suggestions, the first ringed (⏎ with nothing typed adds it). A refused entry shakes the box.
    private var coauthors: some View {
        let draft = state.gitDraft
        let suggestions = state.gitCoauthorSuggestions
        return VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            HStack(spacing: Theme.Size.gitChipGap) {
                Text(Theme.Keys.coauthor)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                ForEach(draft.coauthors, id: \.self) { entry in
                    GitCoauthorChip(entry: entry) { state.removeGitCoauthor(entry) }
                        .transition(.opacity)
                }
                TextField(
                    "",
                    text: Binding(get: { state.gitDraft.coauthorText }, set: { state.setGitCoauthorText($0) }),
                    prompt: Text("Co-author" + Theme.Glyphs.separator + "name <email>").foregroundStyle(Theme.Colors.filterPlaceholder)
                )
                .textFieldStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.ink)
                .focused($focus, equals: .coauthor)
                .onSubmit {
                    guard Self.returnPressed else { return }
                    state.addGitCoauthor()
                }
                Text(Theme.Keys.enter + " adds")
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.gitFieldHPadding)
            .frame(height: Theme.Size.gitFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.Colors.filterFill)
            )
            .shake(trigger: draft.coauthorRejects == 0 ? nil : draft.coauthorRejects)
            .disabled(committing)
            .opacity(committing ? Theme.Opacity.gitLocked : 1)
            if !suggestions.isEmpty {
                HStack(spacing: Theme.Size.gitChipGap) {
                    Text("recent")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .fixedSize()
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, entry in
                        Button { state.addGitCoauthor(entry) } label: {
                            GitCoauthorChip(entry: entry, ringed: index == 0)
                        }
                        .buttonStyle(.plain)
                        .help("Add " + entry)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Theme.Size.gitSuggestionRowHeight)
                .clipped()
            }
        }
        .animation(Theme.Motion.stageSwap, value: draft.coauthors)
    }

    private var bottom: some View {
        let enabled = state.gitCanCommit
        let coauthorCount = state.gitDraft.coauthors.count
        let coauthorTitle = Theme.Keys.coauthor + " " + (coauthorCount == 0 ? "Co-author" : "\(coauthorCount)")
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
            // Only while it fits: the pills come first.
            ViewThatFits(in: .horizontal) {
                Text(focus == .description
                     ? Theme.Keys.commandEnter + " from the description"
                     : Theme.Keys.enter + " commits")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: Theme.Size.spaceM)
            ActionSegment(title: coauthorTitle, role: .neutral) {
                state.toggleGitCoauthors()
            }
            .help(state.gitDraft.coauthorsShown ? "Hide the co-authors" : "Add a co-author (a Co-authored-by trailer)")
            ActionSegment(title: "Cancel", key: Theme.Keys.escape, role: .neutral) {
                state.cancelGitCommitForm()
            }
        }
        .animation(Theme.Motion.stageSwap, value: committing)
    }
}

/// "Ada Lovelace <ada@x.dev> ×": one co-author, mono on a quiet chip; × removes it. A
/// suggestion has no × and the first carries a ring.
@MainActor
private struct GitCoauthorChip: View {
    let entry: String
    var ringed = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
        HStack(spacing: Theme.Size.spaceXS) {
            Text(entry)
                .font(Theme.Fonts.monoCaption)
                .foregroundStyle(Theme.Colors.gitCoauthorChipText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Text(Theme.Glyphs.remove)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.vertical, Theme.Size.gitChipVPadding)
        .padding(.horizontal, Theme.Size.gitChipHPadding)
        .background(shape.fill(Theme.Colors.gitCoauthorChipFill))
        .overlay(shape.strokeBorder(ringed ? Theme.Colors.gitSuggestionRing : Color.clear, lineWidth: Theme.Size.gitSuggestionRing))
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
