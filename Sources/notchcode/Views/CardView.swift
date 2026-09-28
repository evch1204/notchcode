// CardView.swift
// The open panel. The strip stays on top as the toolbar (status on the left, the
// tools with the selected one filled on the right, the gear after a rule). Under
// it, a hairline with a short bridge beneath the selected tool, then the content
// well: a request, a question, Settings, or the selected tool's pane. The footer
// under the well carries the keys for that tool. Switching tools glides the fill,
// slides the bridge, re-targets the panel's height, and slides the pane toward
// its new anchor with parallax.

import SwiftUI

@MainActor
struct CardView: View {
    @ObservedObject var state: AppState
    let bodySize: CGSize

    private var contentWidth: CGFloat { bodySize.width - 2 * Theme.Size.sidePadding }
    private var contentHeight: CGFloat { bodySize.height - state.layout.notchHeight }

    var body: some View {
        VStack(spacing: 0) {
            strip
                .riseIn(0)

            VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                BridgeDivider(state: state, contentWidth: contentWidth)
                    .riseIn(0)
                    // The tool name caption hangs from the divider over the well's top edge.
                    .zIndex(1)

                well
                    .riseIn(1)

                footer
                    .riseIn(2)
            }
            .padding(.horizontal, Theme.Size.sidePadding)
            .padding(.bottom, Theme.Size.sidePadding)
            .frame(width: bodySize.width, height: contentHeight, alignment: .top)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
    }

    // MARK: Strip

    private var strip: some View {
        let session = state.focusedSession
        let shown: SessionState = state.currentPending != nil ? .needsYou : (session.map { state.shownState($0) } ?? .idle)
        return WingRow(layout: state.layout, bodyWidth: bodySize.width) {
            StatusSegment(state: state, session: session, shown: shown)
        } right: {
            StripRightWing(state: state)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.closeCard() }
    }

    // MARK: Well

    /// The content well: what a window shows under its toolbar.
    private var well: some View {
        Group {
            if let request = state.currentPending {
                Group {
                    if request.kind == .commit {
                        CommitCard(state: state, request: request, width: wellContentWidth)
                    } else {
                        PermissionCard(state: state, request: request, width: wellContentWidth)
                    }
                }
                .padding(Theme.Size.wellPadding)
            } else if state.showingQuestion, let question = state.question {
                QuestionCard(state: state, question: question)
                    .padding(Theme.Size.wellPadding)
            } else if state.selectedTab == .settings {
                SettingsPage(state: state)
                    .padding(Theme.Size.wellPadding)
            } else {
                tabPanes
                    .padding(Theme.Size.wellPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                .fill(Theme.Colors.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                .strokeBorder(Theme.Colors.wellStroke, lineWidth: Theme.Size.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous))
    }

    private var wellContentWidth: CGFloat { contentWidth - 2 * Theme.Size.wellPadding }

    /// The tool's pane, sliding a short way toward its anchor when the tool changes. The pane's
    /// offset reaches its inset groups through `PaneParallax`, so they move a little further.
    /// Reduce Motion: a crossfade.
    private var tabPanes: some View {
        ZStack(alignment: .top) {
            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(state.selectedTab)
                .transition(paneTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var paneTransition: AnyTransition {
        if Theme.Motion.reduceMotion {
            return AnyTransition.opacity.animation(Theme.Motion.reduced)
        }
        let forward = state.tabMovedForward
        let distance = Theme.Motion.paneSlide
        let insertion = AnyTransition.offset(x: forward ? distance : -distance)
            .combined(with: .opacity)
            .combined(with: .modifier(
                active: PaneParallax(offset: forward ? distance : -distance),
                identity: PaneParallax(offset: 0)
            ))
        let removal = AnyTransition.offset(x: forward ? -distance : distance)
            .combined(with: .opacity)
            .combined(with: .modifier(
                active: PaneParallax(offset: forward ? -distance : distance),
                identity: PaneParallax(offset: 0)
            ))
        return .asymmetric(
            insertion: insertion.animation(Theme.Motion.tabIn),
            removal: removal.animation(Theme.Motion.tabOut)
        )
    }

    @ViewBuilder
    private var tabBody: some View {
        switch state.selectedTab {
        case .files:
            FilesTab(state: state)
        case .usage:
            UsageTab(state: state)
        case .sessions:
            SessionsTab(state: state)
        default:
            ChangesTab(state: state)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Size.spaceM) {
            if let hint = state.hint {
                HintText(text: hint)
            } else {
                footerKeys
                Text(footerCounts)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Size.spaceM)
            headerUsage
            HStack(spacing: Theme.Size.spaceS) {
                Keycap(Theme.Keys.escape)
                footerLabel(state.selectedTab == .settings ? "back" : "close")
            }
            .fixedSize()
        }
        .frame(height: Theme.Size.cardFooterHeight)
    }

    /// Keycap hints for the current tool.
    @ViewBuilder
    private var footerKeys: some View {
        if let request = state.currentPending {
            HStack(spacing: Theme.Size.spaceS) {
                if request.kind == .commit {
                    Keycap(Theme.Keys.edit)
                    footerLabel("edit")
                } else {
                    Keycap(Theme.Keys.always)
                    footerLabel("always")
                }
                if request.files.contains(where: { !AppState.diffLines($0).isEmpty }) {
                    Keycap(Theme.Keys.diff)
                    footerLabel("diff")
                }
            }
            .fixedSize()
        } else {
            switch state.selectedTab {
            case .changes:
                HStack(spacing: Theme.Size.spaceS) {
                    Keycap(Theme.Keys.enter)
                    footerLabel("open")
                    Keycap(Theme.Keys.copy)
                    footerLabel("copy path:line")
                }
                .fixedSize()
            case .files:
                HStack(spacing: Theme.Size.spaceS) {
                    Keycap(Theme.Keys.enter)
                    footerLabel("open")
                    Keycap(Theme.Keys.slash)
                    footerLabel("filter")
                    Keycap(Theme.Keys.copy)
                    footerLabel("copy path:line")
                    Keycap(Theme.Keys.optionEnter)
                    footerLabel("terminal")
                }
                .fixedSize()
            case .sessions:
                HStack(spacing: Theme.Size.spaceS) {
                    Keycap(Theme.Keys.enter)
                    footerLabel("changes")
                    Keycap(Theme.Keys.optionEnter)
                    footerLabel("terminal")
                    Keycap(Theme.Keys.tab)
                    footerLabel("next tool")
                }
                .fixedSize()
            case .settings:
                HStack(spacing: Theme.Size.spaceS) {
                    Keycap(Theme.Keys.settings)
                    footerLabel("toggles this page")
                }
                .fixedSize()
            default:
                HStack(spacing: Theme.Size.spaceS) {
                    Keycap(Theme.Keys.tab)
                    footerLabel("next tool")
                }
                .fixedSize()
            }
        }
    }

    private func footerLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkTertiary)
    }

    /// "2 working · 1 waiting · 3 agents" on the Sessions tool.
    private var footerCounts: String {
        guard state.currentPending == nil, state.selectedTab == .sessions else { return "" }
        let pendingIds = Set(state.pending.map { $0.sessionId })
        var working = 0, waiting = 0, done = 0, idle = 0
        for session in state.sessions {
            if pendingIds.contains(session.id) || session.state == .needsYou {
                waiting += 1
            } else {
                switch session.state {
                case .working: working += 1
                case .done: done += 1
                case .idle, .needsYou: idle += 1
                }
            }
        }
        return Format.sessionCounts(working: working, waiting: waiting, done: done, idle: idle, agents: state.runningAgentCount)
    }

    /// The 5-hour limit once the status line has reported it (the last known value, as the
    /// Usage tool shows it), else context with "ctx". A 5-hour window that has reset since
    /// the report is stale, so context shows instead.
    @ViewBuilder
    private var headerUsage: some View {
        if let percent = state.usage.fiveHourPercent, !AppState.limitWindowHasReset(state.usage.fiveHourResetsAt) {
            HStack(spacing: Theme.Size.spaceS) {
                Text("5h")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                UsageBar(fraction: percent / 100, tint: Theme.Colors.limitBar)
                    .frame(width: Theme.Size.headerBarWidth)
                Text(Format.percent(min(100, percent)))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .fixedSize()
            .help(state.limitsUpdatedAt.map { "Current session (5h) limit, " + Format.limitsAsOf($0) } ?? "Current session (5h) limit")
        } else if let percent = state.contextPercent {
            HStack(spacing: Theme.Size.spaceS) {
                Text("ctx")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                UsageBar(fraction: percent / 100, tint: Theme.Colors.contextBar)
                    .frame(width: Theme.Size.headerBarWidth)
                Text(Format.percent(percent))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .fixedSize()
            .help("Context window used")
        }
    }
}

/// The hairline between the strip and the well, with a short bridge under the selected
/// tool: where the panel hangs from. It slides along the strip when the tool changes.
/// Requests and questions hang from the action segments instead, so they show none.
@MainActor
struct BridgeDivider: View {
    @ObservedObject var state: AppState
    let contentWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.Colors.stripDivider)
                .frame(height: Theme.Size.hairline)
            if let x = bridgeCentre {
                RoundedRectangle(cornerRadius: Theme.Radius.bridge, style: .continuous)
                    .fill(Theme.Colors.bridge)
                    .frame(width: Theme.Size.bridgeWidth, height: Theme.Size.bridgeHeight)
                    .offset(x: x - Theme.Size.bridgeWidth / 2, y: -Theme.Size.bridgeHeight / 2)
                    .animation(Theme.Motion.toolSelect, value: x)
            }
        }
        .frame(width: contentWidth, height: Theme.Size.bridgeHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            ToolLabelPill(tab: toolsShown ? state.toolLabel : nil) { toolCentre($0) }
        }
    }

    /// The strip shows the tools (not a request's or a question's action segments).
    private var toolsShown: Bool { state.currentPending == nil && !state.showingQuestion }

    private var bridgeCentre: CGFloat? {
        toolsShown ? toolCentre(state.selectedTab) : nil
    }

    /// A tool's centre, in the content's coordinates: measured in from the strip's trailing
    /// edge, tool by tool, so it lands under the icon whatever the panel's width.
    private func toolCentre(_ tab: CardTab) -> CGFloat? {
        let step = Theme.Size.toolWidth + Theme.Size.toolGap
        // The rule with its padding, and the strip's gap on each side of it.
        let rule = Theme.Size.toolRuleWidth + 2 * Theme.Size.toolGroupGap + 2 * Theme.Size.toolGap
        let fromTrailing: CGFloat
        if tab == .settings {
            fromTrailing = Theme.Size.gearWidth / 2
        } else if let index = CardTab.browsable.firstIndex(of: tab) {
            let after = CardTab.browsable.count - 1 - index
            fromTrailing = Theme.Size.gearWidth + rule + CGFloat(after) * step + Theme.Size.toolWidth / 2
        } else {
            return nil
        }
        return contentWidth - Theme.Size.wingEdgeInset - fromTrailing
    }
}
