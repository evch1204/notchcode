// Components.swift
// Small shared views. Every value comes from Theme.

import SwiftUI

// MARK: - Keycap

@MainActor
struct Keycap: View {
    let label: String
    var onLight = false

    init(_ label: String, onLight: Bool = false) {
        self.label = label
        self.onLight = onLight
    }

    var body: some View {
        Text(label)
            .font(Theme.Fonts.keycap)
            .foregroundStyle(onLight ? Theme.Colors.keycapTextOnLight : Theme.Colors.inkSecondary)
            .padding(.horizontal, Theme.Size.keycapHPadding)
            .frame(minWidth: Theme.Size.keycapMin, minHeight: Theme.Size.keycapMin)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                    .fill(onLight ? Theme.Colors.keycapFillOnLight : Theme.Colors.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                    .strokeBorder(onLight ? Color.clear : Theme.Colors.hairline, lineWidth: Theme.Size.hairline)
            )
    }
}

// MARK: - Pill buttons

@MainActor
struct PillButtonStyle: ButtonStyle {
    enum Variant { case ghost, primary, destructive }
    var variant: Variant = .ghost

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodySemibold)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Size.pillHPadding)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.pillHeight)
            .background(Capsule(style: .continuous).fill(background))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? Theme.Opacity.pressed : 1)
    }

    private var foreground: Color {
        switch variant {
        case .ghost: return Theme.Colors.ink
        case .primary: return Theme.Colors.primaryText
        case .destructive: return Theme.Colors.red
        }
    }

    private var background: Color {
        switch variant {
        case .ghost, .destructive: return Theme.Colors.ghostFill
        case .primary: return Theme.Colors.primaryFill
        }
    }
}

/// Title plus keycap, used inside pill buttons.
@MainActor
struct PillLabel: View {
    let title: String
    let key: String
    var onLight = false

    var body: some View {
        HStack(spacing: Theme.Size.pillSpacing) {
            Text(title)
            Keycap(key, onLight: onLight)
        }
    }
}

// MARK: - Motion helpers

private struct PaneOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The horizontal offset of the tab pane sliding in or out, in points. Inset groups
    /// read it to move a little further than the pane (parallax).
    var paneOffset: CGFloat {
        get { self[PaneOffsetKey.self] }
        set { self[PaneOffsetKey.self] = newValue }
    }
}

/// Publishes a pane's slide offset to its children, frame by frame, so inset groups can
/// add `Theme.Motion.tabParallax` of it. Rides along the pane's `.move` transition.
struct PaneParallax: ViewModifier, Animatable {
    var offset: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.paneOffset, offset)
    }
}

/// Moves a view by the parallax share of the enclosing pane's slide.
struct ParallaxGroup: ViewModifier {
    @Environment(\.paneOffset) private var paneOffset

    func body(content: Content) -> some View {
        content.offset(x: paneOffset * Theme.Motion.tabParallax)
    }
}

/// A card row that fades in and rises 10 pt, 120 ms + 40 ms per row after it appears.
/// Reduce Motion: opacity only.
struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Theme.Motion.reduceMotion ? 0 : Theme.Motion.contentRise)
            .onAppear {
                withAnimation(Theme.Motion.rowIn(index)) { shown = true }
            }
    }
}

/// A strip segment that unfolds from behind the camera: it starts `unfoldDistance` toward
/// the centre and transparent, then springs into place, `index` × 30 ms after the first.
/// `towardCamera` is +1 for the left wing and −1 for the right wing. Reduce Motion: opacity only.
struct Unfold: ViewModifier {
    let index: Int
    let towardCamera: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        let reduce = Theme.Motion.reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown || reduce ? 0 : towardCamera * Theme.Motion.unfoldDistance)
            .onAppear {
                withAnimation(Theme.Motion.unfold(index)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
    func parallaxGroup() -> some View { modifier(ParallaxGroup()) }
    /// Left wing: segments counted from the camera outward, sliding out to the left.
    func unfoldLeft(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: 1)) }
    /// Right wing: segments counted from the camera outward, sliding out to the right.
    func unfoldRight(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: -1)) }
}

/// "Open in Ghostty ↗" text link.
@MainActor
struct TeleportLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.spaceXS) {
                Text(title)
                Image(systemName: Theme.Symbols.teleport)
            }
            .font(Theme.Fonts.captionMedium)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Containers

@MainActor
struct InsetGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.Size.insetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous)
                    .fill(Theme.Colors.inset)
            )
            .parallaxGroup()
    }
}

/// The header row of every state: a left wing, the camera gap, a right wing.
/// Nothing is ever drawn in the centre notch width.
@MainActor
struct WingRow<Left: View, Right: View>: View {
    let layout: NotchLayout
    let bodyWidth: CGFloat
    let left: Left
    let right: Right

    init(layout: NotchLayout, bodyWidth: CGFloat, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.layout = layout
        self.bodyWidth = bodyWidth
        self.left = left()
        self.right = right()
    }

    var body: some View {
        let wing = layout.wingWidth(bodyWidth: bodyWidth)
        HStack(spacing: 0) {
            // Each wing is clipped to its slot: an oversized wing must never spill under the camera.
            left
                .padding(.leading, Theme.Size.wingEdgeInset)
                .frame(width: wing, height: layout.notchHeight, alignment: .leading)
                .clipped()
            Color.clear
                .frame(width: layout.notchWidth + 2 * Theme.Size.wingInnerGap, height: layout.notchHeight)
            right
                .padding(.trailing, Theme.Size.wingEdgeInset)
                .frame(width: wing, height: layout.notchHeight, alignment: .trailing)
                .clipped()
        }
        .padding(.horizontal, Theme.Size.sidePadding)
        .frame(width: bodyWidth, height: layout.notchHeight)
    }
}

/// A short tertiary line for empty tabs.
@MainActor
struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bars and rings

@MainActor
struct UsageBar: View {
    let fraction: Double
    var tint: Color = Theme.Colors.ink
    var height: CGFloat = Theme.Size.barHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.Colors.track)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

@MainActor
struct CountdownRing: View {
    let fraction: Double
    var size: CGFloat = Theme.Size.countdownRing
    var tint: Color = Theme.Colors.attention

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.track, lineWidth: Theme.Size.countdownLine)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: Theme.Size.countdownLine, lineCap: .round))
                .rotationEffect(.degrees(Theme.Motion.ringStartDegrees))
        }
        .frame(width: size, height: size)
    }
}

/// Ring plus "0:53" until the request's deadline. The ring drains every frame from the
/// deadline date, so it is right even after the app was busy. Reduce Motion: it jumps once a second.
@MainActor
struct DeadlineCountdown: View {
    let request: PendingRequest
    var ringSize: CGFloat = Theme.Size.countdownRing
    var font: Font = Theme.Fonts.captionMedium

    var body: some View {
        let interval: Double? = Theme.Motion.reduceMotion ? Theme.Motion.clockTick : nil
        TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            let total = max(1, request.deadline.timeIntervalSince(request.receivedAt))
            let remaining = max(0, request.deadline.timeIntervalSince(context.date))
            HStack(spacing: Theme.Size.spaceS) {
                CountdownRing(fraction: remaining / total, size: ringSize)
                Text(Format.clock(remaining))
                    .font(font)
                    .foregroundStyle(Theme.Colors.attentionText)
                    .fixedSize()
            }
        }
    }
}

/// Elapsed "mm:ss" since a date, ticking once a second.
@MainActor
struct ElapsedText: View {
    let since: Date
    var font: Font = Theme.Fonts.caption
    var color: Color = Theme.Colors.inkSecondary

    var body: some View {
        TimelineView(.periodic(from: .now, by: Theme.Motion.clockTick)) { context in
            Text(Format.clock(context.date.timeIntervalSince(since)))
                .font(font)
                .foregroundStyle(color)
                .fixedSize()
        }
    }
}

// MARK: - Glyphs

/// Claude's clay sparkle with a pulsing ring while work is happening.
@MainActor
struct SparkleGlyph: View {
    var pulsing = true
    var size: CGFloat = Theme.Size.glyph
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing && !Theme.Motion.reduceMotion {
                Circle()
                    .stroke(Theme.Colors.clay, lineWidth: Theme.Size.ringLine)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? Theme.Motion.pulseScale : Theme.Motion.pulseStartScale)
                    .opacity(pulse ? 0 : Theme.Opacity.pulseStart)
            }
            Image(systemName: Theme.Symbols.claude)
                .font(Theme.Fonts.symbol(size))
                .foregroundStyle(Theme.Colors.clay)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard pulsing && !Theme.Motion.reduceMotion else { return }
            withAnimation(Theme.Motion.pulse) { pulse = true }
        }
    }
}

/// Clay warning triangle with a slow breathing glow.
@MainActor
struct BreathingTriangle: View {
    var size: CGFloat = Theme.Size.glyph
    @State private var bright = false

    var body: some View {
        Image(systemName: Theme.Symbols.attention)
            .font(Theme.Fonts.symbol(size))
            .foregroundStyle(Theme.Colors.attention)
            .shadow(
                color: bright ? Theme.Colors.attentionGlow : Theme.Colors.attentionGlowDim,
                radius: Theme.Motion.breatheRadius
            )
            .onAppear {
                guard !Theme.Motion.reduceMotion else { return }
                withAnimation(Theme.Motion.breathe) { bright = true }
            }
    }
}

/// A symbol in a tinted circle (peek glyphs, card header icon).
@MainActor
struct CircleGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Theme.Size.peekCircle

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(Theme.Opacity.glyphCircle))
            Image(systemName: symbol)
                .font(Theme.Fonts.symbol(size * Theme.Size.glyphInCircle))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
struct StatusDot: View {
    let state: SessionState
    var size: CGFloat = Theme.Size.dot

    var body: some View {
        Circle()
            .fill(Theme.Colors.state(state))
            .frame(width: size, height: size)
    }
}

/// A small dot with a ring that pulses outward: a running subagent.
@MainActor
struct PulsingDot: View {
    var color: Color = Theme.Colors.agentDot
    var size: CGFloat = Theme.Size.laneDot
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !Theme.Motion.reduceMotion {
                Circle()
                    .stroke(color, lineWidth: Theme.Size.ringLine)
                    .scaleEffect(pulse ? Theme.Motion.pulseScale : Theme.Motion.pulseStartScale)
                    .opacity(pulse ? 0 : Theme.Opacity.pulseStart)
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !Theme.Motion.reduceMotion else { return }
            withAnimation(Theme.Motion.pulse) { pulse = true }
        }
    }
}

// MARK: - Diff pieces

/// Five small cells, green and red in proportion to added and removed.
@MainActor
struct DiffCells: View {
    let added: Int
    let removed: Int

    var body: some View {
        let cells = Theme.Size.diffCellCount
        let total = added + removed
        let greens = total == 0 ? 0 : Int((Double(added) / Double(total) * Double(cells)).rounded())
        let reds = total == 0 ? 0 : cells - greens
        HStack(spacing: Theme.Size.diffCellSpacing) {
            ForEach(0..<cells, id: \.self) { index in
                RoundedRectangle(cornerRadius: Theme.Radius.diffCell, style: .continuous)
                    .fill(color(index: index, greens: greens, reds: reds))
                    .frame(width: Theme.Size.diffCellWidth, height: Theme.Size.diffCellHeight)
            }
        }
    }

    private func color(index: Int, greens: Int, reds: Int) -> Color {
        if index < greens { return Theme.Colors.green }
        if index < greens + reds { return Theme.Colors.red }
        return Theme.Colors.cellEmpty
    }
}

/// "+12 −3" in mono.
@MainActor
struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Text(Format.added(added)).foregroundStyle(Theme.Colors.green)
            Text(Format.removed(removed)).foregroundStyle(Theme.Colors.red)
        }
        .font(Theme.Fonts.monoCaption)
    }
}

/// An integer that counts through every value while it animates ("+0" … "+48").
struct CountingText: View, Animatable {
    var value: Double
    let format: (Int) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(Int(value.rounded())))
            .contentTransition(.numericText(value: value))
    }
}

/// A `CountPill` whose number counts up from 0 when it appears (done peek).
/// Reduce Motion: the number is there at once.
@MainActor
struct CountUpPill: View {
    let count: Int
    let format: (Int) -> String
    let tint: Color
    let fill: Color
    @State private var shown: Double = 0

    var body: some View {
        CountingText(value: shown, format: format)
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Size.smallPillHPadding)
            .frame(height: Theme.Size.smallPillHeight)
            .background(Capsule(style: .continuous).fill(fill))
            .onAppear {
                if Theme.Motion.reduceMotion {
                    shown = Double(count)
                } else {
                    withAnimation(Theme.Motion.countUp) { shown = Double(count) }
                }
            }
    }
}

/// The done check drawn as a path, so it can draw on.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Theme.Shapes.check.map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// The done peek's green circle: pops in (0 → 1.15 → 1) 150 ms after the peek opens, then
/// the check draws on. Reduce Motion: it simply appears.
@MainActor
struct DoneCheckGlyph: View {
    var size: CGFloat = Theme.Size.peekCircle
    @State private var popped = false
    @State private var drawn: CGFloat = 0

    var body: some View {
        let reduce = Theme.Motion.reduceMotion
        ZStack {
            Circle().fill(Theme.Colors.green.opacity(Theme.Opacity.glyphCircle))
            CheckShape()
                .trim(from: 0, to: drawn)
                .stroke(Theme.Colors.green, style: StrokeStyle(lineWidth: Theme.Size.checkLine, lineCap: .round, lineJoin: .round))
                .padding(size * Theme.Size.checkInset)
        }
        .frame(width: size, height: size)
        .opacity(popped ? 1 : 0)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: popped) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            // Under Reduce Motion every keyframe is 1: no pop.
            LinearKeyframe(reduce ? 1 : 0, duration: 0)
            CubicKeyframe(reduce ? 1 : Theme.Motion.checkPopOvershoot, duration: Theme.Motion.checkPopDuration * Theme.Motion.checkPopRiseShare)
            SpringKeyframe(1, duration: Theme.Motion.checkPopDuration * (1 - Theme.Motion.checkPopRiseShare))
        }
        .onAppear {
            if reduce {
                popped = true
                drawn = 1
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.checkDelay) { popped = true }
            withAnimation(Theme.Motion.checkDraw) { drawn = 1 }
        }
    }
}

/// "+12" in a small tinted capsule.
@MainActor
struct CountPill: View {
    let text: String
    let tint: Color
    let fill: Color

    var body: some View {
        Text(text)
            .font(Theme.Fonts.monoCaption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Size.smallPillHPadding)
            .frame(height: Theme.Size.smallPillHeight)
            .background(Capsule(style: .continuous).fill(fill))
    }
}

/// Tool name chip ("Bash") on the permission card.
@MainActor
struct ToolChip: View {
    let tool: String

    var body: some View {
        Text(tool)
            .font(Theme.Fonts.monoSmall)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .padding(.horizontal, Theme.Size.chipHPadding)
            .frame(height: Theme.Size.chipHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.Colors.inset)
            )
    }
}

// MARK: - Subagents

/// A subagent's colour square. The colour is stable per agent within its session.
@MainActor
struct AgentSquare: View {
    let colorIndex: Int
    var finished = false
    var size: CGFloat = Theme.Size.agentSquare

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.agentSquare, style: .continuous)
            .fill(Theme.Colors.agent(colorIndex))
            .opacity(finished ? Theme.Colors.agentFinishedOpacity : 1)
            .frame(width: size, height: size)
    }
}

// MARK: - Hints

/// A one-line hint that appears for a moment ("No terminal found").
@MainActor
struct HintText: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(Theme.Colors.attentionText)
                .lineLimit(1)
                .transition(.opacity)
        }
    }
}
