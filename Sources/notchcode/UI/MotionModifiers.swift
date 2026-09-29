// MotionModifiers.swift
// Motion shared by the surfaces: pane parallax, rise-in, the wings' unfold. Curves come from Theme.

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

extension View {
    func riseIn(_ index: Int, cap: Int = .max) -> some View { modifier(RiseIn(index: index, cap: cap)) }
    func parallaxGroup() -> some View { modifier(ParallaxGroup()) }
    /// Left wing: segments counted from the camera outward, sliding out to the left.
    func unfoldLeft(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: 1)) }
    /// Right wing: segments counted from the camera outward, sliding out to the right.
    func unfoldRight(_ index: Int) -> some View { modifier(Unfold(index: index, towardCamera: -1)) }
}
