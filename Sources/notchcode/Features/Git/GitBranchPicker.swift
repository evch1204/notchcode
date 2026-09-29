// GitBranchPicker.swift
// The Git tool's branch picker (W): the repository pill and its dropdown (R), the filter,
// and one row per local branch saying where it lives.

import SwiftUI

// MARK: - Branch picker

/// The branch picker: the repository pill with its folder and the branch count, the filter
/// past eight branches, one row per local branch. The repository dropdown hangs under the
/// pill over the rows.
@MainActor
struct GitBranchPicker: View {
    @ObservedObject var state: AppState
    /// Closed, the picker stays in the tree with nothing in it, so its parts can transition.
    let open: Bool
    let pillSpace: Namespace.ID
    @FocusState private var filterFocused: Bool

    var body: some View {
        let group = state.gitPickerGroup
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                header(group)
                if open, let group, state.gitPickerShowsFilter {
                    filterField(group)
                        .transition(Theme.Motion.pickerHeadTransition)
                }
                if open, let group {
                    rows(group)
                        .transition(Theme.Motion.pickerRowsTransition)
                }
            }
            if open && group == nil {
                EmptyNote(text: state.gitPanel.listing ? "Reading branches" + Theme.Glyphs.ellipsis : "No git repository in any session")
                    .transition(Theme.Motion.pickerHeadTransition)
            }
        }
        .overlay(alignment: .topLeading) {
            if open, state.gitPanel.repoMenuOpen, let group {
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
        .onChange(of: filterFocused) { _, focused in
            if state.gitPanel.filterFocused != focused { state.setGitFilterFocused(focused) }
        }
        .onChange(of: state.gitPanel.filterFocused, initial: true) { _, focused in
            if filterFocused != focused { filterFocused = focused }
        }
    }

    /// "notchcode ▾ R   ~/Desktop/notchcode                    8 branches". The pill takes
    /// the target pill's frame as it arrives; the rest rises in after it.
    private func header(_ group: GitRepoGroup?) -> some View {
        let multiple = state.gitPanel.repos.count > 1
        return HStack(spacing: Theme.Size.spaceM) {
            if open, let group {
                GitRepoPill(name: group.name, multiple: multiple, open: state.gitPanel.repoMenuOpen) {
                    state.openGitRepoMenu()
                }
                .matchedGeometryEffect(id: GitTab.pillID, in: pillSpace, anchor: .leading)
                .transition(.opacity)
            }
            if open, let group {
                headerRest(group)
                    .transition(Theme.Motion.pickerHeadTransition)
            }
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.gitHeaderHeight)
    }

    /// The folder and the branch count.
    private func headerRest(_ group: GitRepoGroup) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
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
                // Not lazy: every row appears (and rises) with the picker, not later as it scrolls in.
                VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, branch in
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
                        .riseIn(index, cap: Theme.Motion.rowStaggerCap)
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
