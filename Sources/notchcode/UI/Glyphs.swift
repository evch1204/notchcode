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

// MARK: - Tool glyphs

/// A strip tool's icon (the gear for `.settings`): the canvas outline stroked with round
/// caps and joins in the current foreground style, the stroke kept proportional to `size`.
struct ToolGlyph: View {
    let tab: CardTab
    var size: CGFloat = Theme.Size.toolIcon

    var body: some View {
        let ratio = tab == .settings ? Theme.Size.gearStrokeRatio : Theme.Size.toolStrokeRatio
        ZStack {
            ToolShape(path: ToolShapes.stroke(tab))
                .stroke(style: StrokeStyle(lineWidth: size * ratio, lineCap: .round, lineJoin: .round))
            if let dot = ToolShapes.fill(tab) {
                ToolShape(path: dot).fill()
            }
        }
        .frame(width: size, height: size)
    }
}

/// A path drawn in the canvas's 24 × 24 box, scaled to the frame it is given.
struct ToolShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / ToolShapes.box, y: rect.height / ToolShapes.box)
        return path.applying(scale)
    }
}

/// The strip's tool icons, copied from the design canvas: Lucide-style outlines in a
/// 24 × 24 box. The paths are the canvas's SVG, parsed once.
enum ToolShapes {
    static let box: CGFloat = 24

    static func stroke(_ tab: CardTab) -> Path {
        switch tab {
        case .sessions: return sessions
        case .changes: return changes
        case .files: return files
        case .usage: return usage
        case .git: return git
        case .settings: return settings
        }
    }

    /// The filled part, if any: only the gauge's hub.
    static func fill(_ tab: CardTab) -> Path? {
        tab == .usage ? usageHub : nil
    }

    private static let sessions: Path = {
        var p = Path(roundedRect: CGRect(x: 4, y: 9, width: 16, height: 11), cornerRadius: 2.5)
        p.addPath(svg("M7 6h10 M9 3h6"))
        return p
    }()

    private static let changes: Path = {
        var p = circle(12, 12, 9)
        p.addPath(svg("M8 9.5h8 M12 5.5v8 M8 15.5h8"))
        return p
    }()

    private static let files = svg(
        "M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"
    )

    private static let usage = svg("M4 16a8 8 0 1 1 16 0 M12 16l4.5-5")
    private static let usageHub = circle(12, 16, 1.5)

    private static let git: Path = {
        var p = circle(6, 5, 2)
        p.addPath(circle(6, 19, 2))
        p.addPath(circle(18, 6, 2))
        p.addPath(svg("M6 7v10 M18 8c0 5-12 3-12 9"))
        return p
    }()

    private static let settings: Path = {
        var p = circle(12, 12, 3.2)
        p.addPath(svg(
            "M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 "
            + "1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3"
            + "l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 "
            + "0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1"
            + "a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 "
            + "1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 "
            + "0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
        ))
        return p
    }()

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// Parses the SVG path commands the canvas uses: M L H V C A Z, absolute or relative.
    /// Arcs are circular (rx = ry, no rotation), which is all Lucide draws.
    private static func svg(_ d: String) -> Path {
        var p = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"
        var numbers: [CGFloat] = []

        func next() -> CGFloat {
            numbers.isEmpty ? 0 : numbers.removeFirst()
        }

        // Tokenise into (command, numbers) groups.
        var groups: [(Character, [CGFloat])] = []
        var i = d.startIndex
        while i < d.endIndex {
            let c = d[i]
            if c.isLetter {
                groups.append((c, []))
                i = d.index(after: i)
            } else if c == "-" || c == "." || c.isNumber {
                var j = d.index(after: i)
                var seenDot = c == "."
                while j < d.endIndex {
                    let n = d[j]
                    if n.isNumber { j = d.index(after: j); continue }
                    if n == ".", !seenDot { seenDot = true; j = d.index(after: j); continue }
                    break
                }
                if let value = Double(d[i..<j]), !groups.isEmpty {
                    groups[groups.count - 1].1.append(CGFloat(value))
                }
                i = j
            } else {
                i = d.index(after: i)
            }
        }

        for (cmd, values) in groups {
            command = cmd
            numbers = values
            let relative = command.isLowercase
            repeat {
                switch command.uppercased().first! {
                case "M":
                    current = CGPoint(x: base(relative, current).x + next(), y: base(relative, current).y + next())
                    p.move(to: current)
                    start = current
                    command = relative ? "l" : "L"
                case "L":
                    let o = base(relative, current)
                    current = CGPoint(x: o.x + next(), y: o.y + next())
                    p.addLine(to: current)
                case "H":
                    current.x = (relative ? current.x : 0) + next()
                    p.addLine(to: current)
                case "V":
                    current.y = (relative ? current.y : 0) + next()
                    p.addLine(to: current)
                case "C":
                    let o = base(relative, current)
                    let c1 = CGPoint(x: o.x + next(), y: o.y + next())
                    let c2 = CGPoint(x: o.x + next(), y: o.y + next())
                    current = CGPoint(x: o.x + next(), y: o.y + next())
                    p.addCurve(to: current, control1: c1, control2: c2)
                case "A":
                    let o = base(relative, current)
                    let r = next()
                    _ = next() // ry: equal to rx on the canvas
                    _ = next() // x-axis rotation: always 0
                    let large = next() != 0
                    let sweep = next() != 0
                    let end = CGPoint(x: o.x + next(), y: o.y + next())
                    addArc(&p, from: current, to: end, radius: r, large: large, sweep: sweep)
                    current = end
                case "Z":
                    p.closeSubpath()
                    current = start
                default:
                    numbers = []
                }
            } while !numbers.isEmpty
        }
        return p
    }

    private static func base(_ relative: Bool, _ current: CGPoint) -> CGPoint {
        relative ? current : .zero
    }

    /// An SVG circular arc from its endpoints, converted to a centre and two angles.
    private static func addArc(
        _ p: inout Path, from a: CGPoint, to b: CGPoint, radius: CGFloat, large: Bool, sweep: Bool
    ) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = (dx * dx + dy * dy).squareRoot()
        guard chord > 0 else { return }
        let r = max(radius, chord / 2)
        let h = (r * r - chord * chord / 4).squareRoot()
        // Unit normal to the chord; which side the centre falls on follows the flags.
        let sign: CGFloat = large == sweep ? -1 : 1
        let center = CGPoint(x: mid.x - sign * h * dy / chord, y: mid.y + sign * h * dx / chord)
        let start = atan2(a.y - center.y, a.x - center.x)
        let end = atan2(b.y - center.y, b.x - center.x)
        // SwiftUI's `clockwise: false` runs toward increasing angles, SVG's sweep = 1.
        p.addArc(center: center, radius: r, startAngle: .radians(start), endAngle: .radians(end),
                 clockwise: !sweep)
    }
}
