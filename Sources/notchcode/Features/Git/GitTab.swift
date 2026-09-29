// GitTab.swift
// The Git tool. A header row: the target pill ("notchcode › seadevil ▾  W", the repository
// dim, the worktree in ink), the branch (mono), where it stands against its upstream
// ("not published yet", "up to date with origin", "2 behind", "no remote"), and the white
// Push (or Publish) pill with the count it would send and its P keycap ("Push 3  P"),
// disabled when there is nothing to send.
// P or the pill asks in the right pane: the diff or the clean note drops away and the
// question rises in with "⏎ or Push again" and Cancel (esc), while the header's Push pill
// stays put, pops once and shows ⏎; the pill or ⏎ pushes, esc cancels. While git pushes the
// header pill pulses and the card says "Pushing to origin…"; the result shows in the
// header's status.
//
// Below, the Files tool's split: on the left "Uncommitted", one row per changed file (name,
// the five ± cells, the counts), then "Recent commits", the last five, the ones not on the
// remote tagged; on the right the reviewer diff of the selected file. A click or ↑↓ selects
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
                    GitSectionHeader(
                        title: snap.checkedOut ? "Uncommitted" : "Changes vs " + base,
                        count: rows.isEmpty ? nil : Format.files(rows.count)
                    )
                    if rows.isEmpty {
                        Text(snap.checkedOut ? "No changed files" : "No changes")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .padding(.horizontal, Theme.Size.rowHPadding)
                    }
                    ForEach(rows) { item in
                        Button { state.setGitRowCursor(key: item.key) } label: {
                            GitFileRow(file: item.file, isSelected: item.key == selected)
                        }
                        .buttonStyle(.plain)
                        .id(item.key)
                    }
                    if !snap.commits.isEmpty {
                        GitSectionHeader(
                            title: snap.checkedOut ? "Recent commits" : base + ".." + (snap.branch ?? ""),
                            count: snap.checkedOut ? nil : AppState.commits(snap.baseAhead)
                        )
                        .padding(.top, Theme.Size.gitSectionTopPadding)
                        ForEach(snap.commits) { commit in
                            GitCommitRow(commit: commit)
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

/// "GitPanel.swift     ▮▮▮▮▮ +12 −3": the file's name (full path on hover), then the five
/// cells that say whether it is mostly additions or removals, then the counts. The selected
/// row carries the Files tool's opened fill.
@MainActor
private struct GitFileRow: View {
    let file: FileChange
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            PathLabel(path: file.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Size.spaceS) {
                DiffCells(added: file.added, removed: file.removed)
                DiffCounts(added: file.added, removed: file.removed)
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Size.treeRowHPadding)
        .frame(height: Theme.Size.treeRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(isSelected ? Theme.Colors.treeOpened : Color.clear)
        )
        .contentShape(Rectangle())
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

/// "a1b2c3d  Fix the toolbar   not pushed      2h ago".
@MainActor
private struct GitCommitRow: View {
    let commit: GitCommit

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
            Text(AppState.gitAgo(commit.date))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.gitTime)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .padding(.vertical, Theme.Size.rowVPadding)
    }
}
