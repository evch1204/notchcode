// GitTab.swift
// The Git tool. A header row: the target pill ("notchcode › seadevil ▾  W", the repository
// dim, the worktree in ink), the branch (mono), where it stands against its upstream
// ("not published yet", "up to date with origin", "2 behind", "no remote"), and the sync
// pill with its P keycap, GitHub Desktop's order: "Publish 4" without an upstream, "Pull 2"
// when behind, "Push 3" when ahead, else a dark "Fetch" (the tool also fetches quietly when
// it opens, at most every five minutes).
// P or the pill asks in the right pane for a publish, push or pull: the diff or the clean
// note drops away and the question rises in with "⏎ or Push again" and Cancel (esc), while
// the header's pill stays put, pops once and shows ⏎; the pill or ⏎ runs it, esc cancels.
// A fetch runs at once. While git runs the header pill pulses; the result shows in the
// header's status.
//
// Below, the Files tool's split: on the left "Uncommitted · 4", its tri-state box and the
// Commit pill (C), one row per changed file (a checkbox, all in by default, space toggles
// the cursor's; name, the five ± cells, the counts), then "Recent commits", the last five,
// the ones not on the remote tagged, the newest with Undo (U) when it is not pushed; on the
// right the reviewer diff of the selected file, or the commit form (summary, description,
// "Commit 3 files to main"; ⏎ or ⌘⏎ commits the checked files, esc backs out with the draft
// kept until the card closes). A click or ↑↓ selects
// and shows the diff at once, the first file by default; ⌘B hides the list (the Files
// tree's switch). The diff keeps both line-number columns, scrolls both ways (lines never
// wrap), tints the words that changed inside paired −/+ lines, and has a 6 pt minimap of
// the whole file pinned to its right edge. Its header stays on top: name, M/A/D, counts.
// With nothing to commit the split stays: the list keeps its headers and recent commits,
// and the right pane shows a green check with "Nothing to commit · up to date".
//
// W (or the pill) replaces the content with the branch picker: the repository pill
// ("notchcode ▾", R opens the dropdown of repositories), its folder, then one row per local
// branch, newest commit first: the branch in mono, where it lives under it, "session" and
// "current" tags, the counts on the right. Past eight branches a filter field shows (/).
// A branch checked out nowhere opens a read-only page: "not checked out · 4 commits ahead
// of main", "Changes vs main", the commits main..branch, and Push. The target pill stays put
// and morphs into the repository pill, the branch, status and Push slide right and fade, the
// panes drop away, and the rows unfold top down; closing is a plain fade and the reverse.

import SwiftUI

@MainActor
struct GitTab: View {
    @ObservedObject var state: AppState
    /// The target pill and the repository pill share one frame across the swap.
    @Namespace private var pillSpace
    static let pillID = "gitPill"

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
            .animation(Theme.Motion.pushConfirm, value: state.gitPhase)
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

    /// The right pane's line when there is no file to show, after the green check.
    static func emptyText(_ snap: GitSnapshot) -> String {
        if !snap.checkedOut {
            return snap.base.map { "Nothing ahead of " + $0 } ?? "Nothing to compare"
        }
        let upToDate = snap.upstream != nil && snap.behind == 0
        return upToDate ? "Nothing to commit" + Theme.Glyphs.separator + "up to date" : "Nothing to commit"
    }

    /// The Files tool's split: the list at `fileTreeShare` of the width (hidden with ⌘B, the
    /// same switch as the Files tree), a hairline, the selected file's diff.
    private func panes(_ snap: GitSnapshot) -> some View {
        GeometryReader { geo in
            let listWidth = (geo.size.width * Theme.Size.fileTreeShare).rounded(.down)
            let collapsed = state.gitListCollapsed
            HStack(alignment: .top, spacing: 0) {
                list(snap)
                    .frame(width: listWidth)
                    .padding(.trailing, Theme.Size.filesColumnGap)
                    .frame(width: collapsed ? 0 : listWidth + Theme.Size.filesColumnGap, alignment: .trailing)
                    .clipped()
                    .opacity(collapsed ? 0 : 1)
                    .allowsHitTesting(!collapsed)

                Rectangle()
                    .fill(Theme.Colors.paneDivider)
                    .frame(width: collapsed ? 0 : Theme.Size.hairline)
                    .padding(.trailing, collapsed ? 0 : Theme.Size.filesColumnGap)

                GitDiffPane(state: state, snap: snap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .parallaxGroup()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// "Uncommitted" (a branch page: "Changes vs main"): one row per file, a click or ↑↓
    /// selects it; then "Recent commits" (a branch page: "main..design/toolbar").
    private func list(_ snap: GitSnapshot) -> some View {
        let rows = state.gitRows
        let selected = state.gitCursorRowKey
        let base = snap.base ?? ""
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                    if snap.checkedOut && !rows.isEmpty {
                        GitUncommittedHeader(state: state, total: rows.count)
                    } else {
                        GitSectionHeader(
                            title: snap.checkedOut ? "Uncommitted" : "Changes vs " + base,
                            count: rows.isEmpty ? nil : Format.files(rows.count)
                        )
                    }
                    if rows.isEmpty {
                        Text(snap.checkedOut ? "No changed files" : "No changes")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .padding(.horizontal, Theme.Size.rowHPadding)
                    }
                    let unchecked = state.gitDraft.unchecked
                    ForEach(rows) { item in
                        GitFileRow(
                            file: item.file,
                            isSelected: item.key == selected,
                            checked: snap.checkedOut ? !unchecked.contains(item.file.path) : nil,
                            onToggle: { state.toggleGitFile(path: item.file.path) },
                            onSelect: { state.selectGitRow(key: item.key) }
                        )
                        .id(item.key)
                    }
                    if !snap.commits.isEmpty {
                        GitSectionHeader(
                            title: snap.checkedOut ? "Recent commits" : base + ".." + (snap.branch ?? ""),
                            count: snap.checkedOut ? nil : AppState.commits(snap.baseAhead)
                        )
                        .padding(.top, Theme.Size.gitSectionTopPadding)
                        let canUndo = state.gitCanUndo
                        ForEach(snap.commits) { commit in
                            GitCommitRow(
                                commit: commit,
                                undo: canUndo && commit.id == snap.commits.first?.id ? { state.runGitUndo() } : nil
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.rowCursor) { _, _ in
                guard let key = state.gitCursorRowKey else { return }
                withAnimation(Theme.Motion.tap) { proxy.scrollTo(key) }
            }
        }
    }
}

/// "☑ GitPanel.swift     ▮▮▮▮▮ +12 −3": the box that puts the file in the commit (a
/// checkout only), the file's name (full path on hover; dim when left out), the five cells
/// that say whether it is mostly additions or removals, then the counts. A click on the box
/// toggles it without moving the cursor; anywhere else selects the row. The selected row
/// carries the Files tool's opened fill.
@MainActor
private struct GitFileRow: View {
    let file: FileChange
    let isSelected: Bool
    /// Nil on a branch page: nothing is committed there.
    let checked: Bool?
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: Theme.Size.gitCheckboxGap) {
            if let checked {
                GitCheckbox(state: checked ? .all : .none, action: onToggle)
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
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .frame(height: Theme.Size.treeRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(isSelected ? Theme.Colors.treeOpened : Color.clear)
        )
    }
}

/// A commit checkbox: empty with a tertiary edge, or white with a dark check (all in) or a
/// dash (some in, the section header's).
@MainActor
struct GitCheckbox: View {
    enum Value { case all, none, mixed }
    let state: Value
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.gitCheckbox, style: .continuous)
                    .fill(state == .none ? Color.clear : Theme.Colors.gitCheckFill)
                RoundedRectangle(cornerRadius: Theme.Radius.gitCheckbox, style: .continuous)
                    .strokeBorder(state == .none ? Theme.Colors.gitCheckStroke : Color.clear, lineWidth: Theme.Size.gitCheckboxStroke)
                if state != .none {
                    Image(systemName: state == .all ? Theme.Symbols.gitCheck : Theme.Symbols.gitMixed)
                        .font(Theme.Fonts.symbol(Theme.Size.gitCheckMark))
                        .foregroundStyle(Theme.Colors.gitCheckMark)
                }
            }
            .frame(width: Theme.Size.gitCheckbox, height: Theme.Size.gitCheckbox)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "☑ UNCOMMITTED · 4                [Commit  C]": the box puts every file in or takes every
/// one out (a dash when some are in), the title counts "3 of 4" when some are left out, and
/// the pill opens the commit form, white while anything is checked.
@MainActor
private struct GitUncommittedHeader: View {
    @ObservedObject var state: AppState
    let total: Int

    var body: some View {
        let checked = state.gitCheckedFiles.count
        let value: GitCheckbox.Value = checked == total ? .all : checked == 0 ? .none : .mixed
        let count = checked == total ? "\(total)" : "\(checked) of \(total)"
        HStack(spacing: Theme.Size.gitCheckboxGap) {
            GitCheckbox(state: value) { state.toggleAllGitFiles() }
                .help(value == .all ? "Leave every file out" : "Put every file in")
            Text("Uncommitted" + Theme.Glyphs.separator + count)
                .font(Theme.Fonts.groupHeader)
                .foregroundStyle(Theme.Colors.gitSection)
                .lineLimit(1)
            Spacer(minLength: Theme.Size.spaceM)
            ActionSegment(title: "Commit", key: Theme.Keys.commit, role: checked == 0 ? .neutral : .allow) {
                state.openGitCommitForm()
            }
            .help("Write the commit message (\(Theme.Keys.commit))")
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .padding(.top, Theme.Size.groupHeaderTopPadding)
    }
}

/// "UNCOMMITTED  4 files", a list section's caption.
@MainActor
private struct GitSectionHeader: View {
    let title: String
    let count: String?

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Text(title)
                .font(Theme.Fonts.groupHeader)
                .foregroundStyle(Theme.Colors.gitSection)
                .lineLimit(1)
                .truncationMode(.middle)
            if let count {
                Text(count)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.groupHeaderCount)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .padding(.top, Theme.Size.groupHeaderTopPadding)
    }
}

/// "a1b2c3d  Fix the toolbar   not pushed   [Undo  U]   2h ago"; Undo only on the newest
/// commit, when it is not pushed and has a parent.
@MainActor
private struct GitCommitRow: View {
    let commit: GitCommit
    var undo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Text(commit.sha)
                .font(Theme.Fonts.monoCaption)
                .foregroundStyle(Theme.Colors.gitSha)
                .frame(width: Theme.Size.gitShaWidth, alignment: .leading)
            Text(commit.subject)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.gitSubject)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(commit.subject)
            if !commit.pushed {
                Text("not pushed")
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(Theme.Colors.gitTagText)
                    .padding(.horizontal, Theme.Size.badgeHPadding)
                    .frame(height: Theme.Size.badgeHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                            .fill(Theme.Colors.gitTagFill)
                    )
                    .fixedSize()
            }
            Spacer(minLength: Theme.Size.spaceM)
            if let undo {
                ActionSegment(title: "Undo", key: Theme.Keys.undo, role: .neutral, action: undo)
                    .help("Undo this commit: its changes come back to the list and its message to the form")
            }
            Text(AppState.gitAgo(commit.date))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.gitTime)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .padding(.vertical, Theme.Size.rowVPadding)
    }
}
