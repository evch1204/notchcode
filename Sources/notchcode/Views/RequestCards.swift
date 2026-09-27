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

@MainActor
struct PermissionCard: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    let width: CGFloat

    var body: some View {
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
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ToolChip(tool: request.tool)
                }
            }

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceL) {
            HStack(alignment: .center) {
                Text(request.title)
                    .font(Theme.Fonts.hero)
                    .tracking(Theme.Fonts.heroTracking)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(2)
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
                        ForEach(request.files) { file in
                            HStack(spacing: Theme.Size.spaceM) {
                                Text(file.path)
                                    .font(Theme.Fonts.monoCaption)
                                    .foregroundStyle(Theme.Colors.ink)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: Theme.Size.spaceM)
                                DiffCells(added: file.added, removed: file.removed)
                                DiffCounts(added: file.added, removed: file.removed)
                            }
                        }
                    }
                }
            }

            HStack(spacing: Theme.Size.spaceM) {
                Text(request.detail)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                ToolChip(tool: request.tool)
            }

            Spacer(minLength: 0)

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
