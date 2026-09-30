// GitTab.swift
// The Git tool, Direction F (Dock and Stage): three fixed regions, header, rail and stage,
// where nothing appears from nowhere; the thing pressed travels to where the next step is.
//
// The header row: the target pill ("notchcode › seadevil ▾  W", the repository dim, the
// worktree in ink), the branch (mono), the status ("not published yet", "up to date with
// origin", "2 behind", "no remote"), which is also the one place every result lands
// ("Committed 3 files", "Pushed 3 commits", git's error in red), and the sync pill with its P
// keycap, GitHub Desktop's order: "Publish 4", "Pull 2", "Push 3", else a dark "Fetch" (the
// tool also fetches quietly when it opens, at most every five minutes).
//
// The rail (left, the Files tree's share): "Uncommitted · 4" (or "3 of 4") with a tri-state
// box and the checked files' totals, one row per changed file (a checkbox, all in by
// default, space toggles the cursor's; name, the five ± cells, the counts), the cursor's fill
// gliding between rows, and at its foot the dock: the commit's summary field, always there.
// No commit list: the sync pill's count is the unpushed count. ⌘B folds the rail to its
// checkbox column. A branch checked out nowhere shows "Changes vs main · 6": no boxes, no dock.
//
// The stage (right): a header (the ⌘B pill, then the file, "Commit to main", or nothing for a
// confirm) over one of the reviewer diff, the commit form, the confirm, or the clean note,
// which trade places with a drop and a rise. C or a click on the dock sends the dock's field
// up into the stage, where it becomes the form's summary, the description and the
// co-authors rise under it, and the dock's slot stays empty; esc sends it back with
// the text kept. A commit sends it back as a receipt, "Committed · <subject>" with Undo (U),
// which stays until the commit is pushed; the committed rows fold away. P arms the sync pill
// where it is (it pops, its keycap turns ⏎) and the stage asks the question with "⏎ or Push
// again" and Cancel; ⏎ or the pill runs it and the pill pulses. A fetch runs in place.
//
// W (or the pill) replaces the content with the branch picker: the repository pill
// ("notchcode ▾", R opens the dropdown of repositories), its folder, then one row per local
// branch, newest commit first: the branch in mono, where it lives under it, "session" and
// "current" tags, the counts on the right. Past eight branches a filter field shows (/).
// The target pill stays put and morphs into the repository pill, the branch, status and
// sync pill slide right and fade, the panes drop away, and the rows unfold top down; closing
// is a plain fade and the reverse.

import SwiftUI

@MainActor
struct GitTab: View {
    @ObservedObject var state: AppState
    /// The target pill and the repository pill share one frame across the swap.
    @Namespace private var pillSpace
    /// The rail's cursor fill glides from row to row.
    @Namespace private var railSpace
    /// What travels between regions: the dock's summary box.
    @Namespace private var stageSpace
    static let pillID = "gitPill"
    static let cursorID = "gitRowCursor"
    static let summaryID = "gitSummary"
    /// The header's box ticked every row: for a moment the rows tick one after another.
    @State private var bulkTick = false

    /// The content and the picker both stay in the tree; only their parts come and go, so
    /// each part's transition fires (a child's transition does not when its parent is inserted).
    var body: some View {
        if !state.readsLocalFiles {
            EmptyNote(text: "Git reads the real worktree" + Theme.Glyphs.separator + "off in the demo")
        } else {
            let open = state.gitPanel.pickerOpen
            ZStack(alignment: .topLeading) {
                closedSide(open: open)
                GitBranchPicker(state: state, open: open, pillSpace: pillSpace)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(Theme.Motion.pickerSwap, value: open)
            .animation(Theme.Motion.stageSwap, value: state.gitPhase)
            .animation(Theme.Motion.dockTravel, value: state.gitDraft.composing)
            .animation(Theme.Motion.dockTravel, value: state.gitReceipt)
        }
    }

    @ViewBuilder
    private func closedSide(open: Bool) -> some View {
        if state.gitCwd == nil {
            if !open {
                EmptyNote(text: "No session")
                    .transition(Theme.Motion.pickerHeadTransition)
            }
        } else if let snap = state.focusedGit, snap.isRepo {
            content(snap, open: open)
        } else if !open {
            EmptyNote(text: state.focusedGit == nil ? "Reading git" + Theme.Glyphs.ellipsis : "Not a git repository")
                .transition(Theme.Motion.pickerHeadTransition)
        }
    }

    private func content(_ snap: GitSnapshot, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            GitHeader(state: state, snap: snap, open: open, pillSpace: pillSpace)
            if !open {
                panes(snap)
                    .transition(Theme.Motion.pickerPanesTransition)
            }
        }
    }

    /// The stage's line when there is no file to show, after the green check.
    static func emptyText(_ snap: GitSnapshot) -> String {
        if !snap.checkedOut {
            return snap.base.map { "Nothing ahead of " + $0 } ?? "Nothing to compare"
        }
        let upToDate = snap.upstream != nil && snap.behind == 0
        return upToDate ? "Nothing to commit" + Theme.Glyphs.separator + "up to date" : "Nothing to commit"
    }

    /// Rail, hairline, stage. The rail takes `fileTreeShare` of the width, or folded (⌘B, the
    /// Files tree's switch) its checkbox column: its content keeps its width and is clipped,
    /// so the boxes stay put while the width springs and everything else fades. The stage
    /// draws over the rail, so the dock's box travelling in lands on top.
    private func panes(_ snap: GitSnapshot) -> some View {
        GeometryReader { geo in
            let railWidth = (geo.size.width * Theme.Size.fileTreeShare).rounded(.down)
            let folded = state.gitListCollapsed
            HStack(alignment: .top, spacing: 0) {
                // The box draws over the region it is travelling to: the stage while the form
                // is up, the rail on the way back.
                rail(snap, folded: folded, railWidth: railWidth)
                    .padding(.trailing, Theme.Size.filesColumnGap)
                    .zIndex(state.gitDraft.composing ? 0 : 2)

                Rectangle()
                    .fill(Theme.Colors.paneDivider)
                    .frame(width: Theme.Size.hairline)
                    .padding(.trailing, Theme.Size.filesColumnGap)

                GitDiffPane(state: state, snap: snap, stageSpace: stageSpace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .parallaxGroup()
                    .zIndex(1)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Theme.Motion.railFold, value: folded)
        }
    }

    /// The rail header and the rows (they scroll), clipped to the rail's width, then the dock
    /// pinned to the foot (checkouts only), outside the clip so its box can leave whole.
    private func rail(_ snap: GitSnapshot, folded: Bool, railWidth: CGFloat) -> some View {
        let width = folded ? Theme.Size.gitRailFolded : railWidth
        return VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
            VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                GitRailHeader(state: state, snap: snap, folded: folded) { toggleAll() }
                rows(snap, folded: folded)
            }
            .frame(width: railWidth)
            .frame(width: width, alignment: .leading)
            .clipped()
            if snap.checkedOut {
                GitDock(state: state, snap: snap, stageSpace: stageSpace)
                    .frame(width: railWidth)
                    .frame(width: width, alignment: .leading)
                    .padding(.top, Theme.Size.spaceS)
                    .opacity(folded ? 0 : 1)
                    .allowsHitTesting(!folded)
                    .animation(Theme.Motion.railFade, value: folded)
                    .zIndex(2)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The header's box: every row ticks, 20 ms apart top down, for a moment.
    private func toggleAll() {
        bulkTick = true
        state.toggleAllGitFiles()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.checkStaggerWindow) { bulkTick = false }
    }

    /// One row per file. A plain VStack, not a lazy one: rows leave (a commit) and come back
    /// (an undo) with staggered height transitions, which a lazy stack does not run reliably.
    private func rows(_ snap: GitSnapshot, folded: Bool) -> some View {
        let rows = state.gitRows
        let selected = state.gitCursorRowKey
        let unchecked = state.gitDraft.unchecked
        // A commit folds the checked rows away top down: each one's place among them.
        var checkedIndex: [String: Int] = [:]
        for item in rows where !unchecked.contains(item.file.path) { checkedIndex[item.key] = checkedIndex.count }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                    if rows.isEmpty {
                        Text(snap.checkedOut ? "No changed files" : "No changes")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .padding(.horizontal, Theme.Size.treeRowHPadding)
                            .opacity(folded ? 0 : 1)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.key) { index, item in
                        GitFileRow(
                            file: item.file,
                            isSelected: item.key == selected,
                            checked: snap.checkedOut ? !unchecked.contains(item.file.path) : nil,
                            folded: folded,
                            tickDelay: bulkTick ? Theme.Motion.checkStagger * Double(min(index, Theme.Motion.rowStaggerCap)) : 0,
                            railSpace: railSpace,
                            onToggle: { state.toggleGitFile(path: item.file.path) },
                            onSelect: { state.selectGitRow(key: item.key) }
                        )
                        .id(item.key)
                        .zIndex(item.key == selected ? 1 : 0)
                        .transition(Theme.Motion.railRowCollapse(outIndex: checkedIndex[item.key] ?? 0, inIndex: rows.count - 1 - index))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Theme.Motion.railRows, value: rows.map(\.key))
                .animation(Theme.Motion.pickerPill, value: selected)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: state.rowCursor) { _, _ in
                guard let key = state.gitCursorRowKey else { return }
                withAnimation(Theme.Motion.tap) { proxy.scrollTo(key) }
            }
        }
    }
}

/// "☑ Uncommitted · 4 ········ +38 −6": the box puts every file in or takes every one out (a
/// dash when some are in), the count reads "3 of 4" when some are left out and rolls as it
/// changes, the totals are the checked files'. A branch page: "Changes vs main · 6", no box,
/// no totals. Folded, only the box stays.
@MainActor
private struct GitRailHeader: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    let folded: Bool
    let onToggleAll: () -> Void

    var body: some View {
        let total = state.gitRows.count
        let checkedFiles = state.gitCheckedFiles
        let checked = checkedFiles.count
        let boxed = snap.checkedOut && total > 0
        let value: GitCheckbox.Value = checked == total ? .all : checked == 0 ? .none : .mixed
        let title = snap.checkedOut ? "Uncommitted" : "Changes vs " + (snap.base ?? "base")
        let count = total == 0 ? nil : !snap.checkedOut || checked == total ? "\(total)" : "\(checked) of \(total)"
        HStack(spacing: Theme.Size.gitCheckboxGap) {
            if boxed {
                GitCheckbox(value: value, action: onToggleAll)
                    .help(value == .all ? "Leave every file out" : "Put every file in")
            }
            HStack(spacing: Theme.Size.spaceM) {
                HStack(spacing: 0) {
                    Text(title + (count == nil ? "" : Theme.Glyphs.separator))
                    if let count {
                        Text(count)
                            .contentTransition(.numericText())
                            .countPop(count)
                    }
                }
                .font(Theme.Fonts.groupHeader)
                .foregroundStyle(Theme.Colors.gitSection)
                .lineLimit(1)
                .animation(Theme.Motion.countPop, value: count)
                Spacer(minLength: Theme.Size.spaceS)
                if boxed && checked > 0 {
                    Text("+\(checkedFiles.reduce(0) { $0 + $1.added }) " + Theme.Glyphs.minus + "\(checkedFiles.reduce(0) { $0 + $1.removed })")
                        .font(Theme.Fonts.tiny)
                        .foregroundStyle(Theme.Colors.gitRailTotals)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                        .animation(Theme.Motion.countPop, value: checked)
                }
            }
            .opacity(folded ? 0 : 1)
            .animation(Theme.Motion.railFade, value: folded)
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .frame(height: Theme.Size.gitRailHeaderHeight)
    }
}

/// "☑ GitPanel.swift     ▮▮▮▮▮ +12 −3": the box that puts the file in the commit (a
/// checkout only), the file's name (full path on hover; dim when left out, its cells too),
/// the five cells, then the counts. A click on the box toggles it without moving the cursor;
/// anywhere else selects the row. The cursor's fill is one shape that glides between rows.
/// Folded, only the box (and the fill under it) shows.
@MainActor
private struct GitFileRow: View {
    let file: FileChange
    let isSelected: Bool
    /// Nil on a branch page: nothing is committed there.
    let checked: Bool?
    let folded: Bool
    /// The header's box ticks the rows one after another.
    let tickDelay: Double
    let railSpace: Namespace.ID
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: Theme.Size.gitCheckboxGap) {
            if let checked {
                GitCheckbox(value: checked ? .all : .none, delay: tickDelay, action: onToggle)
                    .help(checked ? "In the commit (\(Theme.Keys.toggle) leaves it out)" : "Left out of the commit (\(Theme.Keys.toggle) puts it in)")
            }
            Button(action: onSelect) {
                HStack(spacing: Theme.Size.spaceM) {
                    PathLabel(path: file.path, color: checked == false ? Theme.Colors.gitUnchecked : Theme.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Size.spaceS) {
                        DiffCells(added: file.added, removed: file.removed)
                        DiffCounts(added: file.added, removed: file.removed)
                    }
                    .fixedSize()
                    .opacity(checked == false ? Theme.Opacity.gitUncheckedCells : 1)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(Theme.Motion.checkDim, value: checked)
            }
            .buttonStyle(.plain)
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(!folded)
            .animation(Theme.Motion.railFade, value: folded)
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .frame(height: Theme.Size.treeRowHeight)
        .background(alignment: .leading) {
            // Folded, the fill is the checkbox column's width, not the row's.
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.Colors.treeOpened)
                    .frame(width: folded ? Theme.Size.gitRailFolded : nil)
                    .matchedGeometryEffect(id: GitTab.cursorID, in: railSpace)
            }
        }
    }
}

/// A commit checkbox: empty with a tertiary edge, or white with a dark check drawn as a
/// stroke (all in) or a dash (some in, the header's). Unticking shrinks the fill as it fades.
@MainActor
struct GitCheckbox: View {
    enum Value { case all, none, mixed }
    let value: Value
    /// Waits this long before ticking (the header's staggered tick).
    var delay: Double = 0
    let action: () -> Void

    var body: some View {
        let on = value != .none
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.gitCheckbox, style: .continuous)
        Button(action: action) {
            ZStack {
                shape
                    .strokeBorder(Theme.Colors.gitCheckStroke, lineWidth: Theme.Size.gitCheckboxStroke)
                    .opacity(on ? 0 : 1)
                shape
                    .fill(Theme.Colors.gitCheckFill)
                    .scaleEffect(on ? 1 : Theme.Size.gitUntickScale)
                    .opacity(on ? 1 : 0)
                    .animation((on ? Theme.Motion.checkStroke : Theme.Motion.checkUntick).delay(delay), value: on)
                CheckShape()
                    .trim(from: 0, to: value == .all ? 1 : 0)
                    .stroke(Theme.Colors.gitCheckMark, style: StrokeStyle(lineWidth: Theme.Size.gitCheckLine, lineCap: .round, lineJoin: .round))
                    .frame(width: Theme.Size.gitCheckMark, height: Theme.Size.gitCheckMark)
                    .opacity(value == .mixed ? 0 : 1)
                    .animation(Theme.Motion.checkStroke.delay(delay), value: value)
                Capsule(style: .continuous)
                    .fill(Theme.Colors.gitCheckMark)
                    .frame(width: Theme.Size.gitCheckDash, height: Theme.Size.gitCheckLine)
                    .opacity(value == .mixed ? 1 : 0)
            }
            .frame(width: Theme.Size.gitCheckbox, height: Theme.Size.gitCheckbox)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The dock at the rail's foot, one 26 pt box in three looks. The field: a pen, the draft's
/// summary (or its prompt), C; a press sends it up into the stage as the form's summary.
/// Nothing while the form is up (the slot keeps its height). The receipt after a card commit, while that commit
/// is the newest and unpushed: a check, "Committed · <subject>", Undo (U). The field and the
/// receipt share the summary box's travel id, so whichever is here is what travels.
@MainActor
private struct GitDock: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    let stageSpace: Namespace.ID
    @State private var hovering = false

    /// The box leaves the rail the moment the form's summary arrives (the same update) and
    /// fades out in the first 50 ms of the travel (`travelTransition`), so one box glides;
    /// its text fades in wherever it lands.
    var body: some View {
        let draft = state.gitDraft
        let receipt = state.gitReceipt
        ZStack {
            if draft.composing {
                // The box is away in the stage: the slot stays empty.
                Color.clear
            } else if let receipt {
                receiptBox(receipt)
                    .matchedGeometryEffect(id: GitTab.summaryID, in: stageSpace)
                    .transition(Theme.Motion.travelTransition)
            } else {
                field(draft)
                    .matchedGeometryEffect(id: GitTab.summaryID, in: stageSpace)
                    .transition(Theme.Motion.travelTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Size.gitDockHeight)
    }

    private func field(_ draft: GitDraft) -> some View {
        let enabled = !snap.files.isEmpty
        let typed = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = !enabled ? "Nothing to commit" : typed.isEmpty ? state.gitSummaryPlaceholder : typed
        return Button { state.openGitCommitForm() } label: {
            HStack(spacing: Theme.Size.spaceS) {
                Image(systemName: Theme.Symbols.gitPen)
                    .font(Theme.Fonts.symbol(Theme.Fonts.captionSize))
                    .foregroundStyle(Theme.Colors.gitRailTotals)
                Text(text)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(enabled && !typed.isEmpty ? Theme.Colors.ink : Theme.Colors.filterPlaceholder)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Size.spaceS)
                if enabled { InlineKeycap(Theme.Keys.commit) }
            }
            .fadeIn()
            .padding(.horizontal, Theme.Size.gitFieldHPadding)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.gitDockHeight)
            .background(
                // A hover darkens it: it is pressable.
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(enabled && hovering ? Theme.Colors.quietFill : Theme.Colors.filterFill)
                    .animation(Theme.Motion.railFade, value: hovering)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.disabled)
        .help(enabled ? "Write the commit message (\(Theme.Keys.commit))" : "Nothing to commit")
    }

    private func receiptBox(_ receipt: GitReceipt) -> some View {
        let canUndo = state.gitCanUndo
        return HStack(spacing: Theme.Size.spaceS) {
            DoneCheckGlyph(size: Theme.Size.gitPushingGlyph)
            Text("Committed" + Theme.Glyphs.separator + receipt.subject)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(receipt.sha + "  " + receipt.subject)
            Spacer(minLength: Theme.Size.spaceS)
            ActionSegment(title: "Undo", key: Theme.Keys.undo, role: .neutral) { state.runGitUndo() }
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : Theme.Opacity.disabled)
                .help("Undo this commit: its changes come back to the rail and its message to the form")
        }
        .fadeIn()
        .padding(.leading, Theme.Size.gitFieldHPadding)
        .padding(.trailing, Theme.Size.gitDockPillInset)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Size.gitDockHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.gitReceiptFill)
        )
    }
}
