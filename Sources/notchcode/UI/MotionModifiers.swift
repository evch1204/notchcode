// MotionModifiers.swift
// Motion shared by the surfaces: pane parallax, rise-in, the wings' unfold, the Git rail's row
// collapse, a shake and a count's pop. Curves come from Theme.

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

extension View {
    func shake<T: Equatable>(trigger: T?) -> some View { modifier(Shake(trigger: trigger)) }
    func countPop<T: Equatable>(_ value: T?) -> some View { modifier(CountPop(value: value)) }
    func riseIn(_ index: Int, cap: Int = .max) -> some View { modifier(RiseIn(index: index, cap: cap)) }
    func parallaxGroup() -> some View { modifier(ParallaxGroup()) }
    /// Left wing: segments counted from the camera outward, sliding out to the left.
    func unfoldLeft(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: 1)) }
    /// Right wing: segments counted from the camera outward, sliding out to the right.
    func unfoldRight(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: -1)) }
}
