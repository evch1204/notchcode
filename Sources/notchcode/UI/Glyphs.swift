// Glyphs.swift
// Drawn glyphs: Claude's sparkle, the breathing triangle, circles and status dots, the
// session state glyph, and the done check.

import SwiftUI

// MARK: - Glyphs

/// Claude's clay sparkle with a pulsing ring while work is happening.
@MainActor
struct SparkleGlyph: View {
    var size: CGFloat = Theme.Size.glyph
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !Theme.Motion.reduceMotion {
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
            guard !Theme.Motion.reduceMotion else { return }
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
                radius: Theme.Size.breatheRadius
            )
            .onAppear {
                guard !Theme.Motion.reduceMotion else { return }
                withAnimation(Theme.Motion.breathe) { bright = true }
            }
    }
}

/// A symbol in a tinted circle (peek glyphs).
@MainActor
struct CircleGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        let size = Theme.Size.peekCircle
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

    var body: some View {
        Circle()
            .fill(Theme.Colors.stateGlyph(state))
            .frame(width: Theme.Size.dot, height: Theme.Size.dot)
    }
}

/// A session's state as a glyph: the clay spark pulsing while working, the clay triangle
/// when it needs you, a green check when done, a dim dot when idle. `circled` sets it in
/// an inset circle (the open card's status segment).
@MainActor
struct StateGlyph: View {
    let state: SessionState
    var circled = false

    var body: some View {
        if circled {
            ZStack {
                Circle().fill(Theme.Colors.inset)
                glyph
            }
            .frame(width: Theme.Size.iconCircle, height: Theme.Size.iconCircle)
        } else {
            glyph
                .frame(width: Theme.Size.glyph, height: Theme.Size.glyph)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .working:
            SparkleGlyph()
        case .needsYou:
            BreathingTriangle()
        case .done:
            Image(systemName: Theme.Symbols.done)
                .font(Theme.Fonts.symbol(Theme.Size.glyph))
                .foregroundStyle(Theme.Colors.stateGlyph(.done))
        case .idle:
            Circle()
                .fill(Theme.Colors.stateGlyph(.idle))
                .frame(width: Theme.Size.dot, height: Theme.Size.dot)
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
    @State private var scale: CGFloat = 0
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
        .scaleEffect(scale)
        // Two plain animations (0 → overshoot, then a spring to 1), not a keyframe track:
        // a zero-length keyframe is the pattern that gave SwiftUI a NaN frame.
        .onAppear {
            if reduce {
                popped = true
                scale = 1
                drawn = 1
                return
            }
            let rise = Theme.Motion.checkPopDuration * Theme.Motion.checkPopRiseShare
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.checkDelay) {
                popped = true
                withAnimation(Theme.Motion.checkPopRise) { scale = Theme.Motion.checkPopOvershoot }
                DispatchQueue.main.asyncAfter(deadline: .now() + rise) {
                    withAnimation(Theme.Motion.checkPopSettle) { scale = 1 }
                }
            }
            withAnimation(Theme.Motion.checkDraw) { drawn = 1 }
        }
    }
}
