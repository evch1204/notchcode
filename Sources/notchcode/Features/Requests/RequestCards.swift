// RequestCards.swift
// What the well shows when Claude is blocked on the owner: a permission, a
// commit, or (read-only) a question. The answers live in the strip's action
// segments; the well shows what is being asked, the diff behind it, and the
// way out to the terminal.

import SwiftUI

private let footerText = "At 0:00 the terminal asks instead. Nothing is denied for you."
/// The command box's scroll view, for how far its text has scrolled.
private let commandBoxSpace = "commandBox"

@MainActor
private struct RequestFooter: View {
    @ObservedObject var state: AppState
    let sessionId: String

    var body: some View {
        let session = state.session(id: sessionId)
        HStack(spacing: Theme.Size.spaceM) {
            Text(footerText)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(Theme.Size.footerMinScale)
            Spacer(minLength: Theme.Size.spaceS)
            TeleportLink(title: "Open in \(state.terminalName(for: session))") {
                state.teleport(session: session)
            }
        }
    }
}

/// "+12 −3 · Show changes   D": opens the request's diff inside the well.
@MainActor
private struct ShowChangesRow: View {
    let file: FileChange
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.spaceM) {
                RowChevron(open: open, width: nil, animated: false)
                HStack(spacing: 0) {
                    DiffCounts(added: file.added, removed: file.removed)
                    Text(Theme.Glyphs.separator + (open ? "Hide changes" : "Show changes"))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Size.spaceM)
                InlineKeycap(Theme.Keys.diff)
            }
            .padding(.horizontal, Theme.Size.rowHPadding)
            .padding(.vertical, Theme.Size.rowVPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The request's title with the countdown ring on the right.
@MainActor
private struct RequestTitle: View {
    let request: PendingRequest
    var lines = 1

    var body: some View {
        HStack(alignment: .center) {
            Text(request.title)
                .font(Theme.Fonts.hero)
                .tracking(Theme.Fonts.heroTracking)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(lines)
            Spacer(minLength: Theme.Size.spaceM)
            DeadlineCountdown(request: request, ringSize: Theme.Size.countdownRingLarge, font: Theme.Fonts.bodyMedium)
        }
    }
}

/// A Bash command in full: it wraps, is never cut, and scrolls inside its box when taller
/// than the card allows, with "… 3 more lines · scroll" while more is below. Allow runs all
/// of it, so the owner must be able to read all of it.
@MainActor
private struct CommandBox: View {
    let command: String
    let tool: String

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// How far the text has scrolled up, in points.
    @State private var scrolled: CGFloat = 0

    private static let lineHeight = NSLayoutManager().defaultLineHeight(
        for: NSFont.monospacedSystemFont(ofSize: Theme.Fonts.bodySize, weight: .regular))

    var body: some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
                HStack(alignment: .top, spacing: Theme.Size.spaceM) {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(command)
                            .font(Theme.Fonts.mono)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(commandBoxSpace)) } action: {
                                contentHeight = $0.height
                                scrolled = max(0, -$0.minY)
                            }
                    }
                    .coordinateSpace(name: commandBoxSpace)
                    .frame(
                        minHeight: min(contentHeight, Theme.Size.requestDiffMinHeight),
                        maxHeight: min(contentHeight, Theme.Size.requestDiffMaxHeight)
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                    ToolChip(tool: tool)
                }
                if let note {
                    Text(note)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// "… 3 more lines · scroll" while text is below the box, "end of command" once scrolled
    /// to the bottom of a command that did not fit, nil when it all fits.
    private var note: String? {
        guard viewportHeight > 0, contentHeight.rounded() > viewportHeight.rounded() else { return nil }
        let below = Int(((contentHeight - viewportHeight - scrolled) / Self.lineHeight).rounded(.up))
        guard below > 0 else { return "end of command" }
        return Format.moreLines(below) + Theme.Glyphs.separator + "scroll"
    }
}

/// Every rule Always would add (all of them are sent back), in tertiary ink: at most
/// `alwaysRuleLines`, then "+N more".
@MainActor
private struct AlwaysRules: View {
    let rules: [String]

    var body: some View {
        let shown = rules.prefix(Theme.Limits.alwaysRuleLines)
        VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
            ForEach(Array(shown.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if rules.count > shown.count {
                Text("+\(rules.count - shown.count) more")
            }
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.inkTertiary)
        .help(rules.joined(separator: "\n"))
    }
}

@MainActor
struct PermissionCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest

    private var file: FileChange? { request.files.first }

    var body: some View {
        let open = state.requestDiffPath(for: request) != nil
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            RequestTitle(request: request)

            if request.tool == "Bash" {
                CommandBox(command: request.detail, tool: request.tool)
                    .layoutPriority(-1)
            } else {
                InsetGroup {
                    HStack(alignment: .top, spacing: Theme.Size.spaceM) {
                        Text(request.detail)
                            .font(Theme.Fonts.mono)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(file == nil ? 4 : 2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ToolChip(tool: request.tool)
                    }
                }
            }

            if let file, !AppState.diffLines(file).isEmpty {
                ShowChangesRow(file: file, open: open) {
                    state.toggleRequestDiff(path: file.path)
                }
                .padding(.vertical, -Theme.Size.spaceS)
            }

            if open, let file {
                // Takes the room left above the footer, which never moves.
                DiffView(file: file, maxHeight: Theme.Size.requestDiffMaxHeight, scroll: state.requestDiffScroll)
                    .layoutPriority(-1)
                    .transition(Theme.Motion.requestDiffTransition)
            }

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(open ? 1 : 2)
            }

            if !request.alwaysRules.isEmpty {
                AlwaysRules(rules: request.alwaysRules)
            }

            Spacer(minLength: 0)
                .layoutPriority(-2)

            RequestFooter(state: state, sessionId: request.sessionId)
        }
    }
}

@MainActor
struct CommitCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest

    /// A file row like the Changes tool's; click (or D on the cursor row) opens its diff under it.
    private func fileRow(_ file: FileChange, index: Int, openPath: String?) -> some View {
        let cursorShown = request.files.count > 1 && !AppState.diffLines(file).isEmpty
        return FileDiffRow(
            file: file,
            open: openPath == file.path,
            isCursor: cursorShown && state.requestRowCursor == index,
            spacing: 0,
            disabledWithoutDiff: true
        ) {
            state.requestRowCursor = index
            state.toggleRequestDiff(path: file.path)
        } diff: {
            DiffView(file: file, maxHeight: Theme.Size.requestDiffMaxHeight, scroll: state.requestDiffScroll)
                .layoutPriority(-1)
                .transition(Theme.Motion.requestDiffTransition)
        }
    }

    var body: some View {
        let openPath = state.requestDiffPath(for: request)
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            RequestTitle(request: request, lines: openPath == nil ? 2 : 1)

            InsetGroup {
                VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
                    if request.files.isEmpty {
                        Text(request.detail)
                            .font(Theme.Fonts.monoCaption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .lineLimit(3)
                    } else {
                        let shown = Array(request.files.prefix(Theme.Limits.commitMaxFileRows))
                        ForEach(Array(shown.enumerated()), id: \.element.id) { item in
                            fileRow(item.element, index: item.offset, openPath: openPath)
                        }
                        if request.files.count > shown.count {
                            Text("\(request.files.count - shown.count) more files")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .padding(.horizontal, Theme.Size.rowHPadding)
                        }
                    }
                }
                .padding(-Theme.Size.spaceS)
            }
            .layoutPriority(openPath == nil ? 0 : -1)

            HStack(spacing: Theme.Size.spaceM) {
                Text(request.detail)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if request.files.contains(where: { !AppState.diffLines($0).isEmpty }) {
                    HStack(spacing: Theme.Size.spaceS) {
                        Text(openPath == nil ? "Show changes" : "Hide changes")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        InlineKeycap(Theme.Keys.diff)
                    }
                }
                ToolChip(tool: request.tool)
            }

            Spacer(minLength: 0)
                .layoutPriority(-2)

            RequestFooter(state: state, sessionId: request.sessionId)
        }
    }
}

/// A finished plan: its heading as the hero, the rest rendered as Markdown in a box that
/// takes the room above the footer and scrolls (↑↓ by blocks, or the wheel).
@MainActor
struct PlanCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            RequestTitle(request: request)

            if request.detail.isEmpty {
                Text("The plan is in the terminal.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .padding(Theme.Size.markdownPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .snippetBox()
            } else {
                let body = HookText.planBody(request.detail)
                let shown = Array(body.prefix(Theme.Limits.planMaxLines))
                let footer = body.count > shown.count
                    ? Format.moreLines(body.count - shown.count) + Theme.Glyphs.separator + "open in the terminal"
                    : nil
                MarkdownView(lines: shown, footer: footer, scroll: state.requestDiffScroll)
                    .id(request.id)   // each plan starts at its top with its own scroll state
                    .layoutPriority(-1)
            }

            Spacer(minLength: 0)
                .layoutPriority(-2)

            RequestFooter(state: state, sessionId: request.sessionId)
        }
    }
}

/// Preview only: no hook can answer a question, so the one action (in the strip) is teleport.
@MainActor
struct QuestionCard: View {
    @ObservedObject var state: AppState
    let question: QuestionPreview

    var body: some View {
        let session = state.session(id: question.sessionId)
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            Text(question.question)
                .font(Theme.Fonts.hero)
                .tracking(Theme.Fonts.heroTracking)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(3)

            if !question.options.isEmpty {
                VStack(spacing: Theme.Size.spaceS) {
                    ForEach(Array(question.options.prefix(Theme.Limits.maxQuestionOptions).enumerated()), id: \.offset) { item in
                        // No keycaps: no hook can answer a question, so the options are read-only.
                        HStack(spacing: Theme.Size.spaceM) {
                            Text(item.element)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Colors.inkSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Size.rowHPadding)
                        .padding(.vertical, Theme.Size.rowVPadding)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .fill(Theme.Colors.inset)
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Size.spaceM) {
                Text("Only the terminal can take the answer.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Size.spaceS)
                TeleportLink(title: "Answer in \(state.terminalName(for: session))") {
                    state.teleport(session: session)
                }
            }
        }
    }
}
