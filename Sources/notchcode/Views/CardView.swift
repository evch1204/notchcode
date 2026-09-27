// CardView.swift
// The open card. Header in the wings (session on the left, usage on the right),
// then either a pending request or the companion tabs.

import SwiftUI

@MainActor
struct CardView: View {
    @ObservedObject var state: AppState
    let bodySize: CGSize
    @Namespace private var tabPill

    private var contentWidth: CGFloat { bodySize.width - 2 * Theme.Size.sidePadding }
    private var contentHeight: CGFloat { bodySize.height - state.layout.notchHeight }

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture { state.closeCard() }
                .riseIn(0)

            Group {
                if let request = state.currentPending {
                    Group {
                        if request.kind == .commit {
                            CommitCard(state: state, request: request, width: contentWidth)
                        } else {
                            PermissionCard(state: state, request: request, width: contentWidth)
                        }
                    }
                    .riseIn(1)
                } else if state.showingQuestion, let question = state.question {
                    QuestionCard(state: state, question: question)
                        .riseIn(1)
                } else if state.selectedTab == .settings {
                    SettingsPage(state: state)
                        .riseIn(1)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                        tabRow
                            .riseIn(1)
                        tabPanes
                            .riseIn(2)
                        footer
                            .riseIn(3)
                    }
                }
            }
            .padding(.horizontal, Theme.Size.sidePadding)
            .padding(.top, Theme.Size.spaceM)
            .padding(.bottom, Theme.Size.sidePadding)
            .frame(width: bodySize.width, height: contentHeight, alignment: .top)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        let session = state.focusedSession
        let needsYou = state.currentPending != nil
        return WingRow(layout: state.layout, bodyWidth: bodySize.width) {
            HStack(spacing: Theme.Size.spaceM) {
                if needsYou {
                    CircleGlyph(symbol: Theme.Symbols.attention, tint: Theme.Colors.attention, size: Theme.Size.iconCircle)
                } else {
                    ZStack {
                        Circle().fill(Theme.Colors.inset)
                        SparkleGlyph(pulsing: session?.state == .working)
                    }
                    .frame(width: Theme.Size.iconCircle, height: Theme.Size.iconCircle)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(session?.displayFull ?? "notchcode")
                        .font(Theme.Fonts.bodySemibold)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let session {
                        headerSubtitle(session)
                    }
                }
            }
        } right: {
            headerUsage
        }
    }

    /// "notchcode · main · Editing · ■ Explore ■ general-purpose": one coloured square per running agent.
    /// With a second session in the same folder: "notchcode · main · opus · started 1:10 PM · Editing".
    private func headerSubtitle(_ session: Session) -> some View {
        let running = state.runningAgents(for: session.id)
        let shown = Array(running.prefix(Theme.Size.maxHeaderAgents))
        var extras: [String] = []
        if state.isAmbiguous(session) {
            if let model = state.modelShortName(for: session.id) { extras.append(model) }
            extras.append(Format.started(state.startTime(for: session)))
        }
        if let verb = session.verb, state.shownState(session) == .working { extras.append(verb) }
        let text = Format.sessionSubtitle(session, extra: extras.joined(separator: Theme.Glyphs.separator))
        return HStack(spacing: Theme.Size.spaceS) {
            if !text.isEmpty {
                Text(text + (running.isEmpty ? "" : Theme.Glyphs.separator))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(shown) { agent in
                HStack(spacing: Theme.Size.agentSquareSpacing) {
                    AgentSquare(colorIndex: state.agentColorIndex(agent))
                    Text(agent.type)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            if running.count > shown.count {
                Text("+\(running.count - shown.count)")
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(Theme.Fonts.monoSmall)
        .foregroundStyle(Theme.Colors.inkTertiary)
    }

    /// The 5-hour limit when the status line reported it recently, else context with "ctx".
    @ViewBuilder
    private var headerUsage: some View {
        if state.limitsAreFresh, let percent = state.usage.fiveHourPercent {
            HStack(spacing: Theme.Size.spaceM) {
                Text("5h")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                UsageBar(fraction: percent / 100, tint: Theme.Colors.limitBar)
                    .frame(width: Theme.Size.headerBarWidth)
                Text(Format.percent(min(100, percent)))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .help("Current session (5h) limit")
        } else if let percent = state.contextPercent {
            HStack(spacing: Theme.Size.spaceM) {
                Text("ctx")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                UsageBar(fraction: percent / 100, tint: Theme.Colors.contextBar)
                    .frame(width: Theme.Size.headerBarWidth)
                Text(Format.percent(percent))
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .help("Context window used")
        } else {
            Color.clear
        }
    }

    // MARK: Tabs

    private var tabRow: some View {
        HStack(spacing: Theme.Size.spaceS) {
            ForEach(Array(CardTab.browsable.enumerated()), id: \.offset) { item in
                Button {
                    state.selectTab(item.element)
                } label: {
                    Text(item.element.label)
                }
                .buttonStyle(TabPillStyle(selected: state.selectedTab == item.element, pill: tabPill))
            }
            Spacer(minLength: Theme.Size.spaceM)
            Keycap(Theme.Keys.tab)
        }
        .animation(Theme.Motion.tabPill, value: state.selectedTab)
    }

    /// The tab body, sliding in the direction of the tab change. The pane's offset reaches
    /// its inset groups through `PaneParallax`, so they move a little further (parallax).
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
        let distance = contentWidth
        let inEdge: Edge = forward ? .trailing : .leading
        let outEdge: Edge = forward ? .leading : .trailing
        let insertion = AnyTransition.move(edge: inEdge)
            .combined(with: .opacity)
            .combined(with: .modifier(
                active: PaneParallax(offset: forward ? distance : -distance),
                identity: PaneParallax(offset: 0)
            ))
        let removal = AnyTransition.move(edge: outEdge)
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
            Button {
                state.openSettings()
            } label: {
                HStack(spacing: Theme.Size.spaceS) {
                    Image(systemName: Theme.Symbols.settings)
                        .font(Theme.Fonts.symbol(Theme.Size.gearSize))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                    Keycap(Theme.Keys.settings)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .frame(height: Theme.Size.cardFooterHeight)
    }

    /// Keycap hints for the current tab.
    @ViewBuilder
    private var footerKeys: some View {
        switch state.selectedTab {
        case .changes, .files:
            HStack(spacing: Theme.Size.spaceS) {
                Keycap(Theme.Keys.enter)
                footerLabel("diff")
                if state.selectedTab == .files {
                    Keycap(Theme.Keys.copy)
                    footerLabel("copy path:line")
                }
            }
            .fixedSize()
        case .sessions:
            HStack(spacing: Theme.Size.spaceS) {
                Keycap(Theme.Keys.enter)
                footerLabel("changes")
                Keycap(Theme.Keys.optionEnter)
                footerLabel("terminal")
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }

    private func footerLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.inkTertiary)
    }

    /// "2 working · 1 waiting · 3 agents" on the Sessions tab.
    private var footerCounts: String {
        guard state.selectedTab == .sessions else { return "" }
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
}
