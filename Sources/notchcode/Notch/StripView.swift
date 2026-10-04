// StripView.swift
// The toolbar pieces. In the open card the strip stays on top: the status segment
// left of the camera, the tools, a rule and the gear right of it (or, while a
// request waits, the action strip). In the collapsed strip, hover swaps the
// right wing for the tools. The two-row attention state carries the action strip
// on its second row. The segments themselves are UI/Segments.swift.

import SwiftUI

// MARK: - Tools

/// One tool: an SF Symbol in a segment. The selected tool carries a shared fill (and,
/// while the card has the keys, a focus ring) that glides between tools.
@MainActor
struct ToolButton: View {
    let tab: CardTab
    let selected: Bool
    let focusRing: Bool
    var badge: Int? = nil
    var width: CGFloat = Theme.Size.toolWidth
    let namespace: Namespace.ID
    /// The mouse entered (true) or left (false) this tool; drives the name caption.
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void

    static let selectionId = "toolSelection"
    static let focusId = "toolFocus"

    var body: some View {
        Button(action: action) {
            ToolGlyph(tab: tab)
                .foregroundStyle(selected ? Theme.Colors.segmentIconSelected : Theme.Colors.segmentIcon)
                .frame(width: width, height: Theme.Size.toolHeight)
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 1 {
                        Text("\(badge)")
                            .font(Theme.Fonts.toolBadge)
                            .foregroundStyle(Theme.Colors.toolBadgeText)
                            .padding(.horizontal, Theme.Size.toolBadgeHPadding)
                            .frame(height: Theme.Size.toolBadgeHeight)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.toolBadge, style: .continuous)
                                    .fill(Theme.Colors.toolBadgeFill)
                            )
                            .offset(x: -Theme.Size.toolBadgeOffset, y: Theme.Size.spaceXS)
                    }
                }
        }
        .buttonStyle(SegmentStyle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                    .fill(Theme.Colors.toolSelected)
                    .matchedGeometryEffect(id: Self.selectionId, in: namespace)
            }
        }
        .overlay {
            if selected && focusRing {
                RoundedRectangle(cornerRadius: Theme.Radius.toolFocus, style: .continuous)
                    .strokeBorder(Theme.Colors.toolFocusRing, lineWidth: Theme.Size.toolFocusLine)
                    .padding(-Theme.Size.toolFocusOutset)
                    .matchedGeometryEffect(id: Self.focusId, in: namespace)
            }
        }
        // The name shows as a caption under the strip (`ToolLabelPill`), not a tooltip:
        // tooltips are slow and unreliable on a non-activating panel.
        .onHover(perform: onHover)
        // Where this tool is, for the bridge and the caption to hang from.
        .anchorPreference(key: ToolAnchorsKey.self, value: .bounds) { [tab: $0] }
    }
}

/// Each tool's bounds in the strip, measured, so the card hangs its bridge and the tool
/// name caption under the real icon instead of re-deriving the strip's layout.
struct ToolAnchorsKey: PreferenceKey {
    static let defaultValue: [CardTab: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CardTab: Anchor<CGRect>], nextValue: () -> [CardTab: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The right wing's tools. `selected` is nil in the collapsed strip. With `settings`
/// (the open card), a rule and the gear follow the tools. `compact` narrows the
/// tools so all of them fit a collapsed wing of `available` points.
@MainActor
struct ToolStrip: View {
    @ObservedObject var state: AppState
    let selected: CardTab?
    var focusRing = false
    var settings = false
    var compact = false
    var available: CGFloat = .infinity
    let onSelect: (CardTab) -> Void
    @Namespace private var namespace

    var body: some View {
        let count = CGFloat(CardTab.browsable.count)
        let gap = compact ? Theme.Size.compactToolGap : Theme.Size.toolGap
        let width = compact
            ? max(0, min(Theme.Size.compactToolWidth, (available - (count - 1) * gap) / count))
            : Theme.Size.toolWidth
        let sessionCount = state.sessions.count
        HStack(spacing: gap) {
            ForEach(Array(CardTab.browsable.enumerated()), id: \.offset) { item in
                ToolButton(
                    tab: item.element,
                    selected: selected == item.element,
                    focusRing: focusRing,
                    badge: (!compact && item.element == .sessions) ? sessionCount : nil,
                    width: width,
                    namespace: namespace,
                    onHover: { state.hoverTool(item.element, inside: $0) }
                ) {
                    onSelect(item.element)
                }
                .unfoldRight(item.offset)
            }
            if settings {
                ToolRule()
                    .unfoldRight(CardTab.browsable.count)
                ToolButton(
                    tab: .settings,
                    selected: selected == .settings,
                    focusRing: focusRing,
                    width: Theme.Size.gearWidth,
                    namespace: namespace,
                    onHover: { state.hoverTool(.settings, inside: $0) }
                ) {
                    onSelect(.settings)
                }
                .unfoldRight(CardTab.browsable.count + 1)
            }
        }
        .animation(Theme.Motion.toolSelect, value: selected)
    }
}

/// A thin vertical rule between the tools and the gear.
@MainActor
struct ToolRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.toolGroupRule)
            .frame(width: Theme.Size.toolRuleWidth, height: Theme.Size.toolGroupRuleHeight)
            .padding(.horizontal, Theme.Size.toolGroupGap)
    }
}

/// A collapsed strip's right wing. For click-to-open owners, after the rim's hover dwell
/// the wing crossfades from its usual content to the tools, which unfold from behind
/// the camera; a press opens the card on that tool. Leaving crossfades back. The shape
/// never changes size.
@MainActor
struct HoverToolsWing<Content: View>: View {
    @ObservedObject var state: AppState
    let bodyWidth: CGFloat
    let content: Content

    init(state: AppState, bodyWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.state = state
        self.bodyWidth = bodyWidth
        self.content = content()
    }

    var body: some View {
        let reveal = state.hovering && state.prefs.openGesture == .click
        let available = state.layout.wingContentWidth(bodyWidth: bodyWidth)
        ZStack(alignment: .trailing) {
            if reveal {
                ToolStrip(state: state, selected: nil, compact: true, available: available) { tab in
                    state.openCard(tab: tab)
                }
                .transition(.opacity)
            } else {
                content
                    .transition(.opacity)
            }
        }
        .animation(reveal ? Theme.Motion.hoverIn : Theme.Motion.hoverOut, value: reveal)
    }
}

/// A collapsed strip's left wing. While the tools show in the right wing and one is
/// named, the wing crossfades from its usual content to that tool's name: below the
/// collapsed strip is outside the black, and the right wing has no room left beside the
/// tools, so the name takes the other wing. Nothing moves; nothing sits over the camera.
@MainActor
struct HoverToolsNameWing<Content: View>: View {
    @ObservedObject var state: AppState
    let content: Content

    init(state: AppState, @ViewBuilder content: () -> Content) {
        self.state = state
        self.content = content()
    }

    var body: some View {
        let reveal = state.hovering && state.prefs.openGesture == .click
        let name = reveal ? state.toolLabel : nil
        ZStack(alignment: .leading) {
            if let name {
                Text(name.label)
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(Theme.Colors.wingsName)
                    .lineLimit(1)
                    .transition(.opacity)
                    .id(name)
            } else {
                content
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.toolLabelFade, value: name)
    }
}

/// The open card's tool name: a small caption pill centred on `x`, hung just below the
/// strip's hairline. An overlay, so it never moves anything; it glides to the next tool.
/// Reduce Motion: it appears, moves and leaves without a fade.
@MainActor
struct ToolLabelPill: View {
    let tab: CardTab?
    let centre: (CardTab) -> CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tab, let x = centre(tab) {
                Text(tab.label)
                    .font(Theme.Fonts.toolLabel)
                    .foregroundStyle(Theme.Colors.toolLabelText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Theme.Size.toolLabelHPadding)
                    .frame(height: Theme.Size.toolLabelHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.toolLabel, style: .continuous)
                            .fill(Theme.Colors.toolLabelFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.toolLabel, style: .continuous)
                            .strokeBorder(Theme.Colors.toolLabelStroke, lineWidth: Theme.Size.hairline)
                    )
                    // Centred on the tool: the pill's own width is unknown here, so it is
                    // placed in a zero-width frame at `x` and centred on it.
                    .frame(width: 0, alignment: .center)
                    .offset(x: x, y: Theme.Size.toolLabelDrop)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.toolLabelFade, value: tab)
        .allowsHitTesting(false)
    }
}

// MARK: - Status segment

/// The open card's left wing: the state glyph in a circle, the worktree name over
/// "branch · model · verb · ■ agents".
@MainActor
struct StatusSegment: View {
    @ObservedObject var state: AppState
    let session: Session?
    let shown: SessionState

    var body: some View {
        HStack(spacing: Theme.Size.statusSpacing) {
            StateGlyph(state: shown, circled: true)
                .unfoldLeft(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayOrApp)
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session { subtitle(session) }
            }
            .unfoldLeft(1)
        }
    }

    /// "main · opus · Editing · bypass · ■ Explore ■ general-purpose": branch, model, verb, the
    /// permission mode when not default ("bypass" in clay, "plan" in blue), then one coloured
    /// square per running agent. With a second session in the same folder the start time
    /// follows the model: "main · opus · started 1:10 PM · Editing".
    private func subtitle(_ session: Session) -> some View {
        let running = state.runningAgents(for: session.id)
        let shownAgents = Array(running.prefix(Theme.Limits.maxStatusAgents))
        let text = Format.statusSubtitle(
            session,
            model: state.modelShortName(for: session.id),
            started: state.isAmbiguous(session) ? state.startTime(for: session) : nil,
            verb: state.shownState(session) == .working ? session.verb : nil
        )
        let mode = Format.permissionModeLabel(session.permissionMode)
        let sep = Theme.Glyphs.separator
        var line = Text(text)
        if let mode {
            line = line + Text(text.isEmpty ? "" : sep)
                + Text(mode).foregroundStyle(Theme.Colors.permissionMode(session.permissionMode))
        }
        let hasLine = !text.isEmpty || mode != nil
        return HStack(spacing: Theme.Size.spaceS) {
            if hasLine {
                (line + Text(running.isEmpty ? "" : sep))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(shownAgents) { agent in
                HStack(spacing: Theme.Size.agentSquareSpacing) {
                    AgentSquare(colorIndex: state.agentColorIndex(agent))
                    Text(agent.type)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            if running.count > shownAgents.count {
                Text("+\(running.count - shownAgents.count)")
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(Theme.Fonts.monoSmall)
        .foregroundStyle(Theme.Colors.inkTertiary)
    }
}

// MARK: - Action segments

/// Deny · Always · Allow (or Skip · Edit · Commit). Deny sits nearest the camera; Allow,
/// the primary, at the outer end. `allKeys`: the middle segment shows its keycap too
/// (where there is room; the open card's footer carries it otherwise).
@MainActor
struct ActionStrip: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    var allKeys = false

    var body: some View {
        let actions = request.kind.actions
        // A plan's titles fill the open card's wing, so its ⌫ keycap stays in the footer there.
        let denyKey = allKeys || request.kind != .plan ? actions.deny.key : nil
        HStack(spacing: Theme.Size.actionGap) {
            ActionSegment(title: actions.deny.title, key: denyKey, role: actions.deny.role) {
                state.answer(.deny, to: request)
            }
            .help(actions.deny.help)
            .unfoldRight(0)
            ActionSegment(title: actions.middle.title, key: allKeys ? actions.middle.key : nil, role: actions.middle.role) {
                state.answer(request.kind == .commit ? .edit : .always, to: request)
            }
            .help(actions.middle.help)
            .unfoldRight(1)
            ActionSegment(title: actions.allow.title, key: actions.allow.key, role: actions.allow.role, countdown: request) {
                state.answer(.allow, to: request)
            }
            .help(actions.allow.help)
            .popIn()
            .unfoldRight(2)
        }
        .id(request.id)
    }
}

// MARK: - The open card's right wing

/// The tools with the selected one filled, a rule, the gear; or the action segments while
/// a request waits; or one "Answer in <terminal>" segment for a question. The well never
/// repeats these: the strip is where things are done.
@MainActor
struct StripRightWing: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.cardContent {
        case .request(let request):
            ActionStrip(state: state, request: request)
        case .question(let question):
            // A question can only be answered in the terminal: one segment, the teleport.
            let session = state.session(id: question.sessionId)
            ActionSegment(title: "Answer in \(state.terminalName(for: session))", key: Theme.Keys.enter, role: .allow) {
                state.teleport(session: session)
            }
            .popIn()
            .unfoldRight(0)
        case .settings, .tool:
            ToolStrip(state: state, selected: state.selectedTab, focusRing: true, settings: true) { tab in
                if tab == .settings {
                    if state.selectedTab == .settings { state.closeSettings() } else { state.openSettings() }
                } else {
                    state.selectTab(tab)
                }
            }
        }
    }
}
