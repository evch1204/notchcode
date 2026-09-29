// Components.swift
// Small shared views. Every value comes from Theme.

import SwiftUI

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

/// The inset fill around a group, with the pane parallax. `fillsHeight` stretches it to the
/// room it is given, content at the top (the Usage tiles, at the tile radius).
@MainActor
struct InsetGroup<Content: View>: View {
    var radius: CGFloat = Theme.Radius.inset
    var fillsHeight = false
    let content: Content

    init(radius: CGFloat = Theme.Radius.inset, fillsHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.fillsHeight = fillsHeight
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.Size.insetPadding)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil,
                   alignment: fillsHeight ? .topLeading : .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.Colors.inset)
            )
            .parallaxGroup()
    }
}

extension View {
    /// The snippet box around a diff, the Files preview or rendered Markdown: the inset fill
    /// at the snippet radius, the content clipped to it.
    func snippetBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.snippet, style: .continuous)
        return background(shape.fill(Theme.Colors.inset)).clipShape(shape)
    }

    /// A small capsule behind a label: tags, count pills, the tree's ± badges.
    func capsuleTag(
        fill: Color = Theme.Colors.doneChipFill,
        hPadding: CGFloat = Theme.Size.smallPillHPadding,
        height: CGFloat = Theme.Size.smallPillHeight
    ) -> some View {
        padding(.horizontal, hPadding)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(fill))
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

/// A short tertiary line for empty tabs and panes, centred in the room it has.
@MainActor
struct EmptyNote: View {
    let text: String
    var font: Font = Theme.Fonts.body

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Theme.Colors.inkTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bars and rings

@MainActor
struct UsageBar: View {
    let fraction: Double
    var tint: Color = Theme.Colors.ink

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.Colors.track)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: Theme.Size.barHeight)
    }
}

@MainActor
struct CountdownRing: View {
    let fraction: Double
    var size: CGFloat = Theme.Size.countdownRing

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.track, lineWidth: Theme.Size.countdownLine)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(Theme.Colors.attention, style: StrokeStyle(lineWidth: Theme.Size.countdownLine, lineCap: .round))
                .rotationEffect(.degrees(Theme.Motion.ringStartDegrees))
        }
        .frame(width: size, height: size)
    }
}

/// Redraws its content every frame until the request's deadline, from the deadline date,
/// so countdowns stay right even after the app was busy. Reduce Motion: once a second.
@MainActor
struct RequestTimeline<Content: View>: View {
    let request: PendingRequest
    @ViewBuilder let content: (_ fraction: Double, _ remaining: TimeInterval) -> Content

    var body: some View {
        let interval: Double? = Theme.Motion.reduceMotion ? Theme.Timing.clockTick : nil
        TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            content(request.remainingFraction(at: context.date), request.remaining(at: context.date))
        }
    }
}

/// Ring plus "0:53" until the request's deadline.
@MainActor
struct DeadlineCountdown: View {
    let request: PendingRequest
    var ringSize: CGFloat = Theme.Size.countdownRing
    var font: Font = Theme.Fonts.captionMedium

    var body: some View {
        RequestTimeline(request: request) { fraction, remaining in
            HStack(spacing: Theme.Size.spaceS) {
                CountdownRing(fraction: fraction, size: ringSize)
                Text(Format.clock(remaining))
                    .font(font)
                    .foregroundStyle(Theme.Colors.attentionText)
                    .fixedSize()
            }
        }
    }
}

/// Elapsed "mm:ss" since a date in tertiary, ticking once a second.
@MainActor
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: Theme.Timing.clockTick)) { context in
            Text(Format.clock(context.date.timeIntervalSince(since)))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .fixedSize()
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
        let cells = Theme.Limits.diffCellCount
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

/// "+12 −3" in mono, at the caption size.
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
        .lineLimit(1)
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

/// "+12" in a small tinted capsule. `countsUp`: the number counts up from 0 when it appears
/// (done peek); Reduce Motion: it is there at once.
@MainActor
struct CountPill: View {
    let count: Int
    let format: (Int) -> String
    let tint: Color
    let fill: Color
    var countsUp = false
    @State private var shown: Double = 0

    var body: some View {
        Group {
            if countsUp {
                CountingText(value: shown, format: format)
            } else {
                Text(format(count))
            }
        }
        .font(Theme.Fonts.monoCaption)
        .foregroundStyle(tint)
        .capsuleTag(fill: fill)
        .onAppear {
            guard countsUp else { return }
            if Theme.Motion.reduceMotion {
                shown = Double(count)
            } else {
                withAnimation(Theme.Motion.countUp) { shown = Double(count) }
            }
        }
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

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.agentSquare, style: .continuous)
            .fill(Theme.Colors.agent(colorIndex))
            .opacity(finished ? Theme.Opacity.agentFinished : 1)
            .frame(width: Theme.Size.agentSquare, height: Theme.Size.agentSquare)
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
