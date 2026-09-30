// MotionModifiers.swift
// Motion shared by the surfaces: pane parallax, rise-in, fade-in, the wings' unfold, the Git rail's row
// collapse, a shake, a count's pop and a ring burst. Curves come from Theme.

import SwiftUI

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
/// Reduce Motion: one 0.2 s crossfade, no rise, no stagger.
struct RiseIn: ViewModifier {
    let index: Int
    /// Rows past this index share its delay (the Git picker passes `rowStaggerCap`).
    var cap: Int = .max
    @State private var shown = false

    func body(content: Content) -> some View {
        let reduce = Theme.Motion.reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : Theme.Motion.contentRise)
            .onAppear {
                // Reduce Motion: one crossfade for every row, no stagger.
                let animation = reduce
                    ? Theme.Motion.reduced.delay(Theme.Motion.contentFadeDelay)
                    : Theme.Motion.rowIn(min(index, cap))
                withAnimation(animation) { shown = true }
            }
    }
}

/// Fades a view's content in once it appears (`Theme.Motion.contentIn`), no rise: the text
/// inside a box that travels, so only the arriving copy shows. Reduce Motion: `reduced`.
struct FadeIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(Theme.Motion.reduceMotion ? Theme.Motion.reduced : Theme.Motion.contentIn) { shown = true }
            }
    }
}

/// One end of a box that travels (`matchedGeometryEffect`): the arriving copy at full opacity
/// throughout (`share` 0), the departing one gone within the first `share` of the travel.
/// A real, animated transition on both ends: with `.identity` the departing copy leaves the
/// tree at once, nothing is left to match, and the box jumps instead of gliding.
struct TravelFade: ViewModifier, Animatable {
    /// 1 in place, 0 fully transitioned.
    var progress: Double
    let share: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(share <= 0 ? 1 : min(1, max(0, (progress - (1 - share)) / share)))
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

/// A Git rail row folding its height away (a commit took the file) or unfolding back (an
/// undo): `fraction` 0 is gone, 1 is the whole 20 pt row. Drives `Theme.Motion.railRowCollapse`.
struct RowCollapse: ViewModifier, Animatable {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: Theme.Size.treeRowHeight * fraction, alignment: .top)
            .clipped()
            .opacity(Double(fraction))
    }
}

/// One horizontal shake whenever `trigger` changes to a value (nil never shakes): out
/// `pillShakeDistance`, back past the middle, home, `pillShakeHalf` each. Reduce Motion: none.
struct Shake<T: Equatable>: ViewModifier {
    let trigger: T?
    @State private var x: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .onChange(of: trigger) { _, value in
                guard value != nil, !Theme.Motion.reduceMotion else { return }
                let half = Theme.Motion.pillShakeHalf
                let distance = Theme.Motion.pillShakeDistance
                withAnimation(Theme.Motion.pillShake) { x = distance }
                DispatchQueue.main.asyncAfter(deadline: .now() + half) {
                    withAnimation(Theme.Motion.pillShake) { x = -distance }
                    DispatchQueue.main.asyncAfter(deadline: .now() + half) {
                        withAnimation(Theme.Motion.pillShake) { x = 0 }
                    }
                }
            }
    }
}

/// Pops once (1 → `actionPopOvershoot` → 1) whenever `value` changes to a non-nil value: a
/// count that just moved. Two plain animations, as `PopIn`. Reduce Motion: nothing.
struct CountPop<T: Equatable>: ViewModifier {
    let value: T?
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: value) { _, new in
                guard new != nil, !Theme.Motion.reduceMotion else { return }
                withAnimation(Theme.Motion.countPopRise) { scale = Theme.Motion.actionPopOvershoot }
                let rise = Theme.Motion.actionPopDuration * Theme.Motion.actionPopRiseShare
                DispatchQueue.main.asyncAfter(deadline: .now() + rise) {
                    withAnimation(Theme.Motion.actionPopSettle) { scale = 1 }
                }
            }
    }
}

/// One ring burst whenever `trigger` changes to a value (nil never fires): the view's
/// rounded outline, stroked `Theme.Size.gitRingStroke`, grows from just outside the view's frame
/// (`gitRingStartGap`) to `gitRingScaleX` × `gitRingScaleY` of it (ease-out) while it fades
/// linearly from `gitRingStartOpacity`, over `gitRingDuration`; visible from the first frame. `reverse` runs it back in: from the full scale to the frame,
/// 0 → `gitRingReversePeak` → 0, over `gitRingReverseDuration`, ease-in-out. An overlay, so layout never
/// moves; the stroke stays its width as the ring grows, and it grows from the frame's top-right
/// corner leftward and downward so the well's edges never clip it. Reduce Motion: none.
struct RingBurst<T: Equatable>: ViewModifier {
    let trigger: T?
    let color: Color
    var reverse = false
    /// When the running burst began; nil when there is none.
    @State private var start: Date?

    private var duration: Double { reverse ? Theme.Motion.gitRingReverseDuration : Theme.Motion.gitRingDuration }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let start {
                    // Driven by the clock rather than an animated value, so the phase change
                    // that fires it (and its own animations) cannot cut it short.
                    TimelineView(.animation) { context in
                        let t = min(1, max(0, context.date.timeIntervalSince(start) / duration))
                        RingFrame(time: t, progress: CGFloat(reverse ? Self.easeInOut(t) : Self.easeOut(t)), reverse: reverse, color: color)
                    }
                    .allowsHitTesting(false)
                    .transition(.identity)
                }
            }
            .onChange(of: trigger) { _, value in
                guard value != nil, !Theme.Motion.reduceMotion else { return }
                let now = Date()
                start = now
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    // A later shot owns the ring now.
                    if start == now { start = nil }
                }
            }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) * (1 - t) }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}

/// The ring at `time` (0 → 1, linear: its fade) and `progress` (eased: its growth) of its burst.
private struct RingFrame: View {
    let time: Double
    let progress: CGFloat
    let reverse: Bool
    let color: Color

    var body: some View {
        // How far out the ring is: 0 on the frame, 1 at the full scale.
        let out = reverse ? 1 - progress : progress
        let opacity = reverse
            ? Theme.Motion.gitRingReversePeak * sin(Double(progress) * .pi)
            : Theme.Motion.gitRingStartOpacity * (1 - time)
        GeometryReader { geo in
            // The ring keeps the frame's top-right corner and grows leftward and downward
            // only: the sync pill sits against the well's top and trailing edges, which would
            // clip anything growing that way. It starts `gitRingStartGap` outside on those two
            // sides, so it shows from the first frame even over a white pill mid-pop.
            let gap = Theme.Size.gitRingStartGap
            let dx = gap + geo.size.width * (Theme.Motion.gitRingScaleX - 1) * out
            let dy = gap + geo.size.height * (Theme.Motion.gitRingScaleY - 1) * out
            RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                .stroke(color, lineWidth: Theme.Size.gitRingStroke)
                .frame(width: geo.size.width + dx, height: geo.size.height + dy)
                .offset(x: -dx, y: 0)
                .opacity(opacity)
        }
    }
}

extension View {
    func shake<T: Equatable>(trigger: T?) -> some View { modifier(Shake(trigger: trigger)) }
    func countPop<T: Equatable>(_ value: T?) -> some View { modifier(CountPop(value: value)) }
    func ringBurst<T: Equatable>(trigger: T?, color: Color, reverse: Bool = false) -> some View {
        modifier(RingBurst(trigger: trigger, color: color, reverse: reverse))
    }
    func fadeIn() -> some View { modifier(FadeIn()) }
    func riseIn(_ index: Int, cap: Int = .max) -> some View { modifier(RiseIn(index: index, cap: cap)) }
    func parallaxGroup() -> some View { modifier(ParallaxGroup()) }
    /// Left wing: segments counted from the camera outward, sliding out to the left.
    func unfoldLeft(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: 1)) }
    /// Right wing: segments counted from the camera outward, sliding out to the right.
    func unfoldRight(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: -1)) }
}
