// Segments.swift
// The segment look shared by the strip, the Git header's pills and the Settings pills:
// the segment style and body (hover lift, press depress) and the pop-in an arriving
// segment does. And the action segment by role (Allow, Deny, neutral), with the
// countdown bar Allow drains along its bottom edge.

import SwiftUI

// MARK: - Segment style

/// Hover lift and press depress for any segment. A `fill` gives the segment a fixed
/// colour (action segments); without one it is invisible at rest.
@MainActor
struct SegmentStyle: ButtonStyle {
    var fill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(label: configuration.label, pressed: configuration.isPressed, fill: fill)
    }
}

/// The segment's look around any label; `SegmentStyle` and the Settings pills share it.
/// `capsule` rounds it fully (the Settings pills) instead of the segment radius.
@MainActor
struct SegmentBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let fill: Color?
    var capsule = false
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? .infinity : Theme.Radius.segment, style: .continuous)
        label
            .background(shape.fill(background(pressed: pressed)))
            .contentShape(shape)
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
                withAnimation(Theme.Motion.actionPopRise) {
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

// MARK: - Action segment

/// An action's part in a request: Allow (primary, white), Deny (red tint), or neutral.
enum ActionRole { case allow, deny, neutral }

/// One action segment. Allow carries the countdown draining along its bottom edge. `count`:
/// a number right after the title in the same pill ("Push 3"), coloured like the keycap text.
@MainActor
struct ActionSegment: View {
    let title: String
    var key: String? = nil
    let role: ActionRole
    var count: Int? = nil
    var countdown: PendingRequest? = nil
    let action: () -> Void

    var body: some View {
        let colors = Theme.Colors.action(role)
        Button(action: action) {
            HStack(spacing: Theme.Size.actionKeyGap) {
                HStack(spacing: Theme.Size.spaceS) {
                    Text(title)
                        .font(Theme.Fonts.action)
                        .foregroundStyle(colors.text)
                        .lineLimit(1)
                        .fixedSize()
                    if let count {
                        Text("\(count)")
                            .font(Theme.Fonts.captionMedium)
                            .foregroundStyle(role == .allow ? Theme.Colors.keycapTextOnLight : Theme.Colors.inkSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let key {
                    Keycap(key, onLight: role == .allow)
                }
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .overlay(alignment: .bottomLeading) {
                if let countdown {
                    CountdownBar(request: countdown, tint: colors.bar)
                        .padding(.horizontal, Theme.Size.countdownBarInset)
                        .padding(.bottom, Theme.Size.spaceXS)
                }
            }
        }
        .buttonStyle(SegmentStyle(fill: colors.fill))
    }
}

/// A bar that drains from full to empty over the request's deadline.
@MainActor
struct CountdownBar: View {
    let request: PendingRequest
    var tint: Color = Theme.Colors.allowBar

    var body: some View {
        RequestTimeline(request: request) { fraction, _ in
            GeometryReader { geo in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
            .frame(height: Theme.Size.countdownBar)
        }
    }
}
