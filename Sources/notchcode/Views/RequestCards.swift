// RequestCards.swift
// What the card shows when Claude is blocked on the owner: a permission,
// a commit, or (read-only) a question.

import SwiftUI

private let footerText = "At 0:00 the terminal asks instead. Nothing is denied for you."

/// Three pills: two one-unit ghosts and a two-unit white primary.
@MainActor
private struct ActionRow: View {
    let width: CGFloat
    let deny: (title: String, key: String, action: () -> Void)
    let middle: (title: String, key: String, action: () -> Void)
    let primary: (title: String, key: String, action: () -> Void)

    var body: some View {
        let units = 2 + Theme.Size.primaryUnits
        let unit = max(0, (width - 2 * Theme.Size.buttonSpacing) / units)
        HStack(spacing: Theme.Size.buttonSpacing) {
            Button(action: deny.action) {
                PillLabel(title: deny.title, key: deny.key)
            }
            .buttonStyle(PillButtonStyle(variant: .destructive))
            .frame(width: unit)

            Button(action: middle.action) {
                PillLabel(title: middle.title, key: middle.key)
            }
            .buttonStyle(PillButtonStyle(variant: .ghost))
            .frame(width: unit)

            Button(action: primary.action) {
                PillLabel(title: primary.title, key: primary.key, onLight: true)
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
            .frame(width: unit * Theme.Size.primaryUnits)
        }
    }
}

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

/// "+12 −3 · Show changes   D": opens the request's diff inside the card.
@MainActor
private struct ShowChangesRow: View {
    let file: FileChange
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.spaceM) {
                Image(systemName: Theme.Symbols.chevron)
                    .font(Theme.Fonts.chevron)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .rotationEffect(.degrees(open ? Theme.Motion.chevronOpenDegrees : 0))
                HStack(spacing: 0) {
                    DiffCounts(added: file.added, removed: file.removed)
                    Text(Theme.Glyphs.separator + (open ? "Hide changes" : "Show changes"))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Size.spaceM)
                Keycap(Theme.Keys.diff)
            }
            .padding(.horizontal, Theme.Size.rowHPadding)
            .padding(.vertical, Theme.Size.rowVPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct PermissionCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    let width: CGFloat

    private var file: FileChange? { request.files.first }

    var body: some View {
        let open = state.requestDiffPath(for: request) != nil
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            HStack(alignment: .center) {
                Text(request.title)
                    .font(Theme.Fonts.hero)
                    .tracking(Theme.Fonts.heroTracking)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Size.spaceM)
                DeadlineCountdown(request: request, ringSize: Theme.Size.countdownRingLarge, font: Theme.Fonts.bodyMedium)
            }

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

            if let file, !AppState.diffLines(file).isEmpty {
                ShowChangesRow(file: file, open: open) {
                    state.toggleRequestDiff(path: file.path)
                }
                .padding(.vertical, -Theme.Size.spaceS)
            }

            if open, let file {
                // Takes the room left above the pills, which never move.
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

            Spacer(minLength: 0)
                .layoutPriority(-2)

            ActionRow(
                width: width,
                deny: ("Deny", Theme.Keys.delete, { state.deny(id: request.id) }),
                middle: ("Always", Theme.Keys.always, { state.allowAlways(id: request.id) }),
                primary: ("Allow", Theme.Keys.enter, { state.allow(id: request.id) })
            )

            RequestFooter(state: state, sessionId: request.sessionId)
        }
    }
}

@MainActor
struct CommitCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    let width: CGFloat

    /// A file row like the Changes tab's; click (or D on the cursor row) opens its diff under it.
    @ViewBuilder
    private func fileRow(_ file: FileChange, index: Int, openPath: String?) -> some View {
        let hasDiff = !AppState.diffLines(file).isEmpty
        let open = openPath == file.path
        let cursorShown = request.files.count > 1 && hasDiff
        VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
            Button {
                state.requestRowCursor = index
                state.toggleRequestDiff(path: file.path)
            } label: {
                FileRowLabel(
                    file: file,
                    open: open,
                    hasDiff: hasDiff,
                    isCursor: cursorShown && state.requestRowCursor == index,
                    showDirectory: true
                )
            }
            .buttonStyle(.plain)
            .disabled(!hasDiff)

            if open {
                DiffView(file: file, maxHeight: Theme.Size.requestDiffMaxHeight, scroll: state.requestDiffScroll)
                    .layoutPriority(-1)
                    .transition(Theme.Motion.requestDiffTransition)
            }
        }
    }

    var body: some View {
        let openPath = state.requestDiffPath(for: request)
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            HStack(alignment: .center) {
                Text(request.title)
                    .font(Theme.Fonts.hero)
                    .tracking(Theme.Fonts.heroTracking)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(openPath == nil ? 2 : 1)
                Spacer(minLength: Theme.Size.spaceM)
                DeadlineCountdown(request: request, ringSize: Theme.Size.countdownRingLarge, font: Theme.Fonts.bodyMedium)
            }

            InsetGroup {
                VStack(alignment: .leading, spacing: Theme.Size.spaceS) {
                    if request.files.isEmpty {
                        Text(request.detail)
                            .font(Theme.Fonts.monoCaption)
                            .foregroundStyle(Theme.Colors.inkSecondary)
                            .lineLimit(3)
                    } else {
                        let shown = Array(request.files.prefix(Theme.Size.commitMaxFileRows))
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
                        Keycap(Theme.Keys.diff)
                    }
                }
                ToolChip(tool: request.tool)
            }

            Spacer(minLength: 0)
                .layoutPriority(-2)

            ActionRow(
                width: width,
                deny: ("Skip", Theme.Keys.delete, { state.deny(id: request.id) }),
                middle: ("Edit", Theme.Keys.edit, { state.requestCommitEdit(id: request.id) }),
                primary: ("Commit", Theme.Keys.enter, { state.allow(id: request.id) })
            )

            RequestFooter(state: state, sessionId: request.sessionId)
        }
    }
}

/// Preview only: no hook can answer a question, so the one action is teleport.
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
                    ForEach(Array(question.options.prefix(Theme.Size.maxQuestionOptions).enumerated()), id: \.offset) { item in
                        HStack(spacing: Theme.Size.spaceM) {
                            Keycap("\(item.offset + 1)")
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

            Button {
                state.teleport(session: session)
            } label: {
                HStack(spacing: Theme.Size.pillSpacing) {
                    Text("Answer in \(state.terminalName(for: session))")
                    Image(systemName: Theme.Symbols.teleport)
                    Keycap(Theme.Keys.enter, onLight: true)
                }
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
        }
    }
}
