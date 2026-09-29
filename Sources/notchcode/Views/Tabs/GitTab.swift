// GitTab.swift
// The Git tool. A header row: the target pill ("notchcode › seadevil ▾  W", the repository
// dim, the worktree in ink), the branch (mono), where it stands against its upstream
// ("3 commits to push", "not published yet", "up to date with origin", "no remote"), and the
// white Push (or Publish) pill with its P keycap, disabled when there is nothing to send.
// P or the pill turns the status into a confirm line ("Push 3 commits to origin/seadevil?");
// ⏎ or the pill again pushes, esc cancels. While git pushes the pill pulses; the result
// ("Pushed 3 commits", or git's error in red) takes the status's place.
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
// of main", "Changes vs main", the commits main..branch, and Push.

import SwiftUI

@MainActor
struct GitTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !state.readsLocalFiles {
            EmptyNote(text: "Git reads the real worktree" + Theme.Glyphs.separator + "off in the demo")
        } else if state.gitPanel.pickerOpen {
            GitBranchPicker(state: state)
        } else if state.gitCwd == nil {
            EmptyNote(text: "No session")
        } else if let snap = state.focusedGit {
            if snap.isRepo {
                content(snap)
            } else {
                EmptyNote(text: "Not a git repository")
            }
        } else {
            EmptyNote(text: "Reading git" + Theme.Glyphs.ellipsis)
        }
    }

    private func content(_ snap: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            GitHeader(state: state, snap: snap)
            panes(snap)
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

// MARK: - The reviewer diff

/// The right pane: a header that stays on top (the ⌘B pill, the name, M/A/D, the counts),
/// then the selected file's diff, which scrolls both ways under it with the minimap pinned
/// to its right edge.
@MainActor
private struct GitDiffPane: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The diff row at the top of the pane, and how many rows the pane shows.
    @State private var topRow = 0
    @State private var visibleCount = 0

    var body: some View {
        let file = state.gitSelectedFile
        let lines = file.map(AppState.diffLines) ?? []
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            header(file: file)
                .padding(.horizontal, Theme.Size.previewHPadding)

            ZStack(alignment: .top) {
                if let file {
                    if lines.isEmpty {
                        centred(file.kind == "new" ? "Empty file" : "No text diff")
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
            .id(file?.path ?? "")
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.previewFade, value: file?.path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: file?.path) { _, _ in topRow = 0 }
    }

    private func header(file: FileChange?) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
            TreeTogglePill(collapsed: state.gitListCollapsed, enabled: file != nil, subject: "file list") {
                state.toggleGitList()
            }
            ZStack(alignment: .leading) {
                if let file {
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

    private func centred(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// The longest line in characters (prefix and text), for the content's width.
    @State private var longest = 0

    private static let space = "gitDiffScroll"

    private struct Inputs: Equatable {
        var lines: [DiffLine]
        var fileLines: Int?
    }

    var body: some View {
        GeometryReader { geo in
            let rowWidth = max(0, geo.size.width - Theme.Size.diffMinimapReserve)
            // A lazy stack only knows its loaded rows, so its width is set from the longest
            // line to give the scroll view its sideways range.
            let textWidth = Theme.Size.previewHPadding * 2 + 2 * Theme.Size.diffLineNumberWidth
                + 2 * Theme.Size.previewGutterSpacing + CGFloat(longest) * Theme.Fonts.monoSmallAdvance
            let contentWidth = max(rowWidth, textWidth.rounded(.up))
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            WideDiffLineRow(line: lines[index], words: words[index] ?? [], minWidth: rowWidth)
                                .id(index)
                        }
                        if file.patchTruncated {
                            Text(truncatedNote)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .padding(.leading, 2 * (Theme.Size.diffLineNumberWidth + Theme.Size.previewGutterSpacing) + Theme.Size.previewHPadding)
                                .frame(height: Theme.Size.diffLineHeight)
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.vertical, Theme.Size.previewVPadding)
                    .padding(.trailing, Theme.Size.diffMinimapReserve)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.space)).minY
                    } action: { minY in
                        let row = Int(((-minY - Theme.Size.previewVPadding) / Theme.Size.diffLineHeight).rounded())
                        let clamped = max(0, min(max(0, lines.count - 1), row))
                        if clamped != topRow { topRow = clamped }
                    }
                }
                .coordinateSpace(.named(Self.space))
                .overlay(alignment: .topTrailing) {
                    if let minimap {
                        DiffMinimap(model: minimap, visibleRows: visibleRange) { row in
                            let target = max(0, row - visibleCount / 2)
                            proxy.scrollTo(target, anchor: .topLeading)
                        }
                        .padding(.vertical, Theme.Size.diffMinimapInset)
                        .padding(.trailing, Theme.Size.diffMinimapInset)
                    }
                }
            }
            .onAppear { visibleCount = Int(geo.size.height / Theme.Size.diffLineHeight) }
            .onChange(of: Inputs(lines: lines, fileLines: fileLines), initial: true) { _, inputs in
                words = WordDiff.marks(inputs.lines)
                minimap = DiffMinimapModel(lines: inputs.lines, fileLines: inputs.fileLines)
                longest = inputs.lines.map { $0.prefix.count + $0.text.count }.max() ?? 0
            }
            .onChange(of: geo.size.height) { _, height in
                visibleCount = Int(height / Theme.Size.diffLineHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
                .fill(Theme.Colors.inset)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous))
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
        let count = missing > 0 ? "\(missing) more lines" : "more lines"
        return Theme.Glyphs.ellipsis + " " + count + " in the editor"
    }
}

// MARK: - Header

/// "notchcode › seadevil ▾ W   user-friendly-distribution-plan   3 commits to push   [Push P]",
/// or the confirm, progress or result in the status's place. A branch checked out nowhere:
/// "notchcode › design/toolbar ▾ W   not checked out · 4 commits ahead of main".
@MainActor
private struct GitHeader: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot

    var body: some View {
        let phase = state.gitPhase
        HStack(spacing: Theme.Size.spaceM) {
            GitTargetPill(parts: state.gitTargetParts) { state.toggleGitPicker() }
            if snap.checkedOut {
                Text(snap.branch ?? "detached HEAD")
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.gitBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            HStack(spacing: Theme.Size.spaceM) {
                status(phase)
                if snap.checkedOut && !state.gitTargetIsFocused {
                    Text("not the focused session")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.gitTargetNote)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pill(phase)
            if phase == .confirming {
                Button { state.cancelGitConfirm() } label: { InlineKeycap(Theme.Keys.escape) }
                    .buttonStyle(.plain)
                    .help("Cancel")
            }
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.gitHeaderHeight)
    }

    @ViewBuilder
    private func status(_ phase: GitPushPhase) -> some View {
        switch phase {
        case .idle:
            line(state.gitStatusText, font: Theme.Fonts.caption, color: Theme.Colors.gitStatus)
        case .confirming:
            line(state.gitConfirmText, font: Theme.Fonts.captionMedium, color: Theme.Colors.ink)
        case .pushing:
            line("Pushing to " + state.gitPushTarget + Theme.Glyphs.ellipsis, font: Theme.Fonts.caption, color: Theme.Colors.gitStatus)
        case .pushed(let message):
            line(message, font: Theme.Fonts.captionMedium, color: Theme.Colors.gitPushed)
        case .failed(let message):
            line(message, font: Theme.Fonts.caption, color: Theme.Colors.gitError)
                .help(message)
        }
    }

    private func line(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func pill(_ phase: GitPushPhase) -> some View {
        let verb = state.gitPushVerb
        switch phase {
        case .pushing:
            GitPushingPill(title: verb == "Publish" ? "Publishing" : "Pushing")
        case .confirming:
            ActionSegment(title: verb, key: Theme.Keys.enter, role: .allow) { state.pressGitPill() }
                .help(state.gitConfirmText)
        case .idle, .pushed, .failed:
            let enabled = state.gitCanPush
            ActionSegment(title: verb, key: Theme.Keys.push, role: enabled ? .allow : .neutral) { state.pressGitPill() }
                .disabled(!enabled)
                .opacity(enabled ? 1 : Theme.Opacity.disabled)
                .help(enabled ? verb + " this branch (asks first)" : state.gitStatusText)
        }
    }
}

/// "notchcode › seadevil ▾  W": the repository dim, then the worktree folder in ink (or the
/// branch in mono when it is checked out nowhere); a press opens the picker.
@MainActor
private struct GitTargetPill: View {
    let parts: (repo: String?, place: String, placeIsBranch: Bool)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.actionKeyGap) {
                HStack(spacing: Theme.Size.spaceS) {
                    if let repo = parts.repo {
                        Text(repo)
                            .font(Theme.Fonts.captionMedium)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                            .lineLimit(1)
                        Text(Theme.Glyphs.pathChevron)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                    }
                    Text(parts.place)
                        .font(parts.placeIsBranch ? Theme.Fonts.monoCaption : Theme.Fonts.action)
                        .foregroundStyle(Theme.Colors.gitTargetPlace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(Theme.Glyphs.pickerChevron)
                        .font(Theme.Fonts.tiny)
                        .foregroundStyle(Theme.Colors.gitTargetRepo)
                }
                InlineKeycap(Theme.Keys.worktree)
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .frame(maxWidth: Theme.Size.gitTargetMaxWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .layoutPriority(2)
        .help("Choose the branch (\(Theme.Keys.worktree))")
    }
}

// MARK: - Branch picker

/// The branch picker: the repository pill with its folder and the branch count, the filter
/// past eight branches, one row per local branch. The repository dropdown hangs under the
/// pill over the rows.
@MainActor
private struct GitBranchPicker: View {
    @ObservedObject var state: AppState
    @FocusState private var filterFocused: Bool

    var body: some View {
        Group {
            if let group = state.gitPickerGroup {
                VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                    header(group)
                    if state.gitPickerShowsFilter {
                        filterField(group)
                    }
                    rows(group)
                }
                .overlay(alignment: .topLeading) {
                    if state.gitPanel.repoMenuOpen {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { state.closeGitRepoMenu() }
                            GitRepoMenu(state: state, current: group.id)
                                .padding(.top, Theme.Size.gitHeaderHeight + Theme.Size.spaceS)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(Theme.Motion.tap, value: state.gitPanel.repoMenuOpen)
            } else {
                EmptyNote(text: state.gitPanel.listing ? "Reading branches" + Theme.Glyphs.ellipsis : "No git repository in any session")
            }
        }
        .onChange(of: filterFocused) { _, focused in
            if state.gitPanel.filterFocused != focused { state.setGitFilterFocused(focused) }
        }
        .onChange(of: state.gitPanel.filterFocused, initial: true) { _, focused in
            if filterFocused != focused { filterFocused = focused }
        }
    }

    /// "notchcode ▾ R   ~/Desktop/notchcode                    8 branches".
    private func header(_ group: GitRepoGroup) -> some View {
        let multiple = state.gitPanel.repos.count > 1
        return HStack(spacing: Theme.Size.spaceM) {
            GitRepoPill(name: group.name, multiple: multiple, open: state.gitPanel.repoMenuOpen) {
                state.openGitRepoMenu()
            }
            Text(GitBranchPicker.abbreviated(group.id))
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.Colors.gitPickerPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Theme.Size.gitPickerPathMaxWidth, alignment: .leading)
                .help(group.id)
            Spacer(minLength: Theme.Size.spaceM)
            Text(group.branches.count == 1 ? "1 branch" : "\(group.branches.count) branches")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.groupHeaderCount)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.gitHeaderHeight)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The Files tree's filter field: "/ design     3 of 10  esc clears".
    private func filterField(_ group: GitRepoGroup) -> some View {
        let filter = state.gitPanel.filter
        return HStack(spacing: Theme.Size.spaceS) {
            Image(systemName: Theme.Symbols.filter)
                .font(Theme.Fonts.symbol(Theme.Fonts.tinySize))
                .foregroundStyle(Theme.Colors.filterPlaceholder)
            TextField(
                "",
                text: Binding(
                    get: { state.gitPanel.filter },
                    set: { value in withAnimation(Theme.Motion.filterRows) { state.setGitFilter(value) } }
                ),
                prompt: Text("Filter branches").foregroundStyle(Theme.Colors.filterPlaceholder)
            )
            .textFieldStyle(.plain)
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(Theme.Colors.ink)
            .focused($filterFocused)
            if !filter.isEmpty {
                Text("\(state.gitPickerRows.count) of \(group.branches.count)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.filterPlaceholder)
                    .fixedSize()
                InlineKeycap(Theme.Keys.escape)
                Text("clears")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.filterPlaceholder)
                    .fixedSize()
            } else if !filterFocused {
                InlineKeycap(Theme.Keys.slash)
            }
        }
        .padding(.horizontal, Theme.Size.filterHPadding)
        .frame(height: Theme.Size.filterHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.Colors.filterFill)
        )
    }

    private func rows(_ group: GitRepoGroup) -> some View {
        let rows = state.gitPickerRows
        let cursor = state.gitPanel.pickerCursor
        let cursorName = rows.indices.contains(cursor) ? rows[cursor].name : nil
        let filter = state.gitPanel.filter
        let hidden = group.branches.count - rows.count
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                    ForEach(rows) { branch in
                        Button { state.pickGitBranch(branch) } label: {
                            GitBranchRow(
                                branch: branch,
                                defaultBranch: group.defaultBranch,
                                match: filter,
                                hasSession: branch.path.map { !state.gitSessions(inWorktree: $0).isEmpty } ?? false,
                                isCurrent: state.gitBranchIsCurrent(branch, repo: group.id),
                                isCursor: branch.name == cursorName
                            )
                        }
                        .buttonStyle(.plain)
                        .id(branch.name)
                    }
                    if !filter.isEmpty && hidden > 0 {
                        Text(rows.isEmpty
                             ? "No branch matches"
                             : (hidden == 1 ? "1 branch hidden by the filter" : "\(hidden) branches hidden by the filter"))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .padding(.horizontal, Theme.Size.gitBranchRowHPadding)
                            .padding(.vertical, Theme.Size.rowVPadding)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let cursorName { proxy.scrollTo(cursorName) } }
            .onChange(of: cursorName) { _, name in
                guard let name else { return }
                withAnimation(Theme.Motion.tap) { proxy.scrollTo(name) }
            }
        }
    }
}

/// "notchcode ▾  R": the repository the picker lists. With more than one it opens the
/// dropdown; with one it is a static label.
@MainActor
private struct GitRepoPill: View {
    let name: String
    let multiple: Bool
    let open: Bool
    let action: () -> Void

    var body: some View {
        if multiple {
            Button(action: action) {
                label
            }
            .buttonStyle(SegmentStyle(fill: open ? Theme.Colors.pickerSelected : Theme.Colors.neutralActionFill))
            .help("Choose the repository (\(Theme.Keys.repository))")
        } else {
            label
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                        .fill(Theme.Colors.neutralActionFill)
                )
        }
    }

    private var label: some View {
        HStack(spacing: Theme.Size.actionKeyGap) {
            Text(name)
                .font(Theme.Fonts.action)
                .foregroundStyle(Theme.Colors.gitTargetPlace)
                .lineLimit(1)
            if multiple {
                Text(Theme.Glyphs.pickerChevron)
                    .font(Theme.Fonts.tiny)
                    .foregroundStyle(Theme.Colors.gitTargetRepo)
                InlineKeycap(Theme.Keys.repository)
            }
        }
        .padding(.horizontal, Theme.Size.actionHPadding)
        .frame(height: Theme.Size.actionHeight)
        .fixedSize()
    }
}

/// The repository dropdown: one row per repository (name, folder, branch count) drawn over
/// the rows in the well, in the inset style. ↑↓ and ⏎ pick, esc or R closes it.
@MainActor
private struct GitRepoMenu: View {
    @ObservedObject var state: AppState
    let current: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.gitPanel.repos.enumerated()), id: \.element.id) { item in
                let repo = item.element
                Button { state.chooseGitRepo(repo.id) } label: {
                    HStack(spacing: Theme.Size.spaceM) {
                        Text(repo.name)
                            .font(Theme.Fonts.captionSemibold)
                            .foregroundStyle(repo.id == current ? Theme.Colors.gitRepoMenuName : Theme.Colors.gitRepoMenuOther)
                            .lineLimit(1)
                            .fixedSize()
                        Text(GitBranchPicker.abbreviated(repo.id))
                            .font(Theme.Fonts.monoSmall)
                            .foregroundStyle(Theme.Colors.gitPickerPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Size.spaceM)
                        if repo.id == current { SmallTag(text: "current") }
                        Text("\(repo.branches.count)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.groupHeaderCount)
                            .fixedSize()
                    }
                    .padding(.horizontal, Theme.Size.rowHPadding)
                    .frame(height: Theme.Size.gitRepoMenuRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(item.offset == state.gitPanel.repoMenuCursor ? Theme.Colors.rowCursor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(repo.id)
            }
        }
        .padding(Theme.Size.gitRepoMenuPadding)
        .frame(width: Theme.Size.gitRepoMenuWidth, alignment: .leading)
        .background(shape.fill(Theme.Colors.gitRepoMenuBase))
        .background(shape.fill(Theme.Colors.gitRepoMenuFill))
        .overlay(shape.strokeBorder(Theme.Colors.gitRepoMenuStroke, lineWidth: Theme.Size.hairline))
    }
}

/// One local branch: "design/toolbar" in mono, "not checked out" under it (or "worktree
/// seadevil" with its glyph, or "main checkout"), the session and current tags, then the
/// counts on the right: "33 uncommitted", "clean", "↑3", "↑2 of main".
@MainActor
private struct GitBranchRow: View {
    let branch: GitBranch
    let defaultBranch: String?
    let match: String
    let hasSession: Bool
    let isCurrent: Bool
    let isCursor: Bool

    var body: some View {
        let counts = Self.counts(branch, defaultBranch: defaultBranch)
        HStack(spacing: Theme.Size.spaceM) {
            VStack(alignment: .leading, spacing: Theme.Size.gitBranchLineGap) {
                Text(name)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.gitPickerBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Theme.Size.spaceS) {
                    if case .worktree = branch.place {
                        Image(systemName: Theme.Symbols.gitWorktree)
                            .font(Theme.Fonts.symbol(Theme.Size.gitPlaceGlyph))
                    }
                    Text(place)
                        .lineLimit(1)
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(branch.place == .nowhere ? Theme.Colors.gitPickerNowhere : Theme.Colors.gitPickerPlace)
            }
            .layoutPriority(1)
            if hasSession { SmallTag(text: "session") }
            if isCurrent { SmallTag(text: "current") }
            Spacer(minLength: Theme.Size.spaceM)
            Text(counts.text)
                .font(Theme.Fonts.caption)
                .foregroundStyle(counts.quiet ? Theme.Colors.gitPickerClean : Theme.Colors.gitPickerCount)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Size.gitBranchRowHPadding)
        .frame(height: Theme.Size.gitBranchRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isCursor ? Theme.Colors.rowCursor : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(isCursor ? Theme.Colors.gitPickerCursorStroke : Color.clear, lineWidth: Theme.Size.hairline)
        )
        .contentShape(Rectangle())
        .help(branch.path ?? branch.name)
    }

    /// The name, the filter's match lit.
    private var name: AttributedString {
        var text = AttributedString(branch.name)
        let query = match.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) {
            text[range].backgroundColor = Theme.Colors.gitFilterMatch
        }
        return text
    }

    private var place: String {
        switch branch.place {
        case .main: return "main checkout"
        case .worktree(let path): return "worktree " + URL(fileURLWithPath: path).lastPathComponent
        case .nowhere: return "not checked out"
        }
    }

    /// "33 uncommitted · ↑2", "clean", "↑3", "↑2 of main", "in main". Quiet (tertiary) when
    /// nothing is uncommitted or ahead.
    static func counts(_ branch: GitBranch, defaultBranch: String?) -> (text: String, quiet: Bool) {
        var parts: [String] = []
        if let n = branch.uncommitted { parts.append(n == 0 ? "clean" : "\(n) uncommitted") }
        let ahead = branch.ahead ?? 0
        if ahead > 0 {
            let of = branch.upstream == nil ? " of " + (defaultBranch ?? "main") : ""
            parts.append(Theme.Glyphs.ahead + "\(ahead)" + of)
        } else if branch.place == .nowhere, branch.ahead != nil {
            parts.append(branch.upstream == nil ? "in " + (defaultBranch ?? "main") : "up to date")
        }
        let quiet = (branch.uncommitted ?? 0) == 0 && ahead == 0
        return (parts.joined(separator: Theme.Glyphs.separator), quiet)
    }
}

/// The pill while git pushes: Claude's pulsing spark and "Pushing", not pressable.
@MainActor
private struct GitPushingPill: View {
    let title: String

    var body: some View {
        Button {} label: {
            HStack(spacing: Theme.Size.actionKeyGap) {
                SparkleGlyph(size: Theme.Size.gitPushingGlyph)
                Text(title)
                    .font(Theme.Fonts.action)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .disabled(true)
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
