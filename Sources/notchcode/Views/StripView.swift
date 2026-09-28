// StripView.swift
// The toolbar pieces. In the open card the strip stays on top: the status segment
// left of the camera, the four tools, a rule and the gear right of it (or, while a
// request waits, the action segments). In the collapsed strip, hover swaps the
// right wing for the four tools. The two-row attention state carries the action
// segments on its second row. Segments lift on hover, depress on press, and
// unfold from behind the camera.

import SwiftUI

// MARK: - Segment style

/// Hover lift and press depress for any segment. A `fill` gives the segment a fixed
/// colour (action segments); without one it is invisible at rest.
@MainActor
struct SegmentStyle: ButtonStyle {
    var fill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, fill: fill)
    }
}

@MainActor
private struct SegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color?
    @State private var hovered = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                    .fill(background(pressed: pressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))
            .scaleEffect(pressed && !Theme.Motion.reduceMotion ? Theme.Motion.pressScale : 1)
            .animation(Theme.Motion.press, value: pressed)
            .animation(Theme.Motion.hoverLift, value: hovered)
            .onHover { hovered = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if let fill {
            return pressed ? fill.opacity(Theme.Opacity.pressed) : fill
        }
        if pressed { return Theme.Colors.segmentPressed }
        if hovered { return Theme.Colors.segmentHover }
        return Color.clear
    }
}

/// Scales 0.92 → 1.08 → 1 once on appear, after the unfold delay (Allow arriving).
/// Reduce Motion: nothing.
/// Two plain animations, not a keyframe track: a zero-length keyframe on a button gave
/// SwiftUI's key-view loop a NaN frame.
struct PopIn: ViewModifier {
    @State private var scale: CGFloat = Theme.Motion.reduceMotion ? 1 : Theme.Motion.actionPopStart

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                guard !Theme.Motion.reduceMotion else { scale = 1; return }
                let rise = Theme.Motion.actionPopDuration * Theme.Motion.actionPopRiseShare
                withAnimation(.easeOut(duration: rise).delay(Theme.Motion.unfoldDelay)) {
                    scale = Theme.Motion.actionPopOvershoot
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.unfoldDelay + rise) {
                    withAnimation(Theme.Motion.actionPopSettle) { scale = 1 }
                }
            }
    }
}

extension View {
    func popIn() -> some View { modifier(PopIn()) }
}

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
            Image(systemName: Theme.Symbols.tool(tab))
                .font(Theme.Fonts.symbol(Theme.Size.toolIcon))
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
                    .padding(Theme.Size.toolFocusInset)
                    .matchedGeometryEffect(id: Self.focusId, in: namespace)
            }
        }
        // The name shows as a caption under the strip (`ToolLabelPill`), not a tooltip:
        // tooltips are slow and unreliable on a non-activating panel.
        .onHover(perform: onHover)
    }
}

/// The right wing's tools. `selected` is nil in the collapsed strip. With `settings`
/// (the open card), a rule and the gear follow the four tools. `compact` narrows the
/// tools so the four fit a collapsed wing of `available` points.
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
        let sessionCount = state.sessionGroups.reduce(0) { $0 + $1.sessions.count }
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
/// the wing crossfades from its usual content to the four tools, which unfold from behind
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
        let available = state.layout.wingWidth(bodyWidth: bodyWidth) - Theme.Size.wingEdgeInset
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
        .animation(reveal ? Theme.Motion.toolsRevealIn : Theme.Motion.toolsRevealOut, value: reveal)
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
            CircledStateGlyph(state: shown)
                .unfoldLeft(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(session?.displayFull ?? "notchcode")
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session { subtitle(session) }
            }
            .unfoldLeft(1)
        }
    }

    /// "main · opus · Editing · ■ Explore ■ general-purpose": branch, model, verb, then one
    /// coloured square per running agent. With a second session in the same folder the start
    /// time follows the model: "main · opus · started 1:10 PM · Editing".
    private func subtitle(_ session: Session) -> some View {
        let running = state.runningAgents(for: session.id)
        let shownAgents = Array(running.prefix(Theme.Size.maxHeaderAgents))
        var extras: [String] = []
        if let model = state.modelShortName(for: session.id) { extras.append(model) }
        if state.isAmbiguous(session) {
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

/// Spark pulsing while working, clay triangle when it needs you, green check when done,
/// dim dot when idle, in an inset circle.
@MainActor
private struct CircledStateGlyph: View {
    let state: SessionState

    var body: some View {
        ZStack {
            Circle().fill(Theme.Colors.inset)
            switch state {
            case .working:
                SparkleGlyph(pulsing: true)
            case .needsYou:
                BreathingTriangle()
            case .done:
                Image(systemName: Theme.Symbols.done)
                    .font(Theme.Fonts.symbol(Theme.Size.glyph))
                    .foregroundStyle(Theme.Colors.doneGlyph)
            case .idle:
                Circle()
                    .fill(Theme.Colors.idleGlyph)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
            }
        }
        .frame(width: Theme.Size.iconCircle, height: Theme.Size.iconCircle)
    }
}

// MARK: - Action segments

/// One action: Allow (white, the countdown draining along its bottom edge), Deny (red
/// tint), or a neutral one (Always, Edit).
@MainActor
struct ActionSegment: View {
    enum Variant { case allow, deny, neutral }

    let title: String
    var key: String? = nil
    let variant: Variant
    var countdown: PendingRequest? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.actionKeyGap) {
                Text(title)
                    .font(Theme.Fonts.action)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize()
                if let key {
                    Keycap(key, onLight: variant == .allow)
                }
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .overlay(alignment: .bottomLeading) {
                if let countdown {
                    CountdownBar(request: countdown, tint: barColor)
                        .padding(.horizontal, Theme.Size.countdownBarInset)
                        .padding(.bottom, Theme.Size.spaceXS)
                }
            }
        }
        .buttonStyle(SegmentStyle(fill: fill))
    }

    private var fill: Color {
        switch variant {
        case .allow: return Theme.Colors.allowFill
        case .deny: return Theme.Colors.denyFill
        case .neutral: return Theme.Colors.neutralActionFill
        }
    }

    private var textColor: Color {
        switch variant {
        case .allow: return Theme.Colors.allowText
        case .deny: return Theme.Colors.denyText
        case .neutral: return Theme.Colors.neutralActionText
        }
    }

    private var barColor: Color {
        variant == .allow ? Theme.Colors.allowBar : Theme.Colors.inkSecondary
    }
}

/// A 2 pt bar that drains from full to empty over the request's deadline, every frame,
/// driven by the deadline date. Reduce Motion: it steps once a second.
@MainActor
struct CountdownBar: View {
    let request: PendingRequest
    var tint: Color = Theme.Colors.allowBar

    var body: some View {
        let interval: Double? = Theme.Motion.reduceMotion ? Theme.Motion.clockTick : nil
        TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            let total = max(1, request.deadline.timeIntervalSince(request.receivedAt))
            let remaining = max(0, request.deadline.timeIntervalSince(context.date))
            GeometryReader { geo in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(remaining / total))
            }
            .frame(height: Theme.Size.countdownBar)
        }
    }
}

/// Deny · Always · Allow (or Skip · Edit · Commit). Deny sits nearest the camera; Allow,
/// the primary, at the outer end. `allKeys`: the middle segment shows its keycap too
/// (where there is room; the open card's footer carries it otherwise).
@MainActor
struct ActionStrip: View {
    @ObservedObject var state: AppState
    let request: PendingRequest
    var allKeys = false

    var body: some View {
        let commit = request.kind == .commit
        HStack(spacing: Theme.Size.actionGap) {
            ActionSegment(title: commit ? "Skip" : "Deny", key: Theme.Keys.delete, variant: .deny) {
                state.deny(id: request.id)
            }
            .help(commit ? "Skip this commit (\(Theme.Keys.delete))" : "Deny (\(Theme.Keys.delete))")
            .unfoldRight(0)
            ActionSegment(
                title: commit ? "Edit" : "Always",
                key: allKeys ? (commit ? Theme.Keys.edit : Theme.Keys.always) : nil,
                variant: .neutral
            ) {
                if commit { state.requestCommitEdit(id: request.id) } else { state.allowAlways(id: request.id) }
            }
            .help(commit ? "Ask for a different message (\(Theme.Keys.edit))" : "Allow and remember (\(Theme.Keys.always))")
            .unfoldRight(1)
            ActionSegment(title: commit ? "Commit" : "Allow", key: Theme.Keys.enter, variant: .allow, countdown: request) {
                state.allow(id: request.id)
            }
            .help(commit ? "Commit (\(Theme.Keys.enter))" : "Allow (\(Theme.Keys.enter))")
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
        if let request = state.currentPending {
            ActionStrip(state: state, request: request)
        } else if state.showingQuestion, let question = state.question {
            // A question can only be answered in the terminal: one segment, the teleport.
            let session = state.session(id: question.sessionId)
            ActionSegment(title: "Answer in \(state.terminalName(for: session))", key: Theme.Keys.enter, variant: .allow) {
                state.teleport(session: session)
            }
            .popIn()
            .unfoldRight(0)
        } else {
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
