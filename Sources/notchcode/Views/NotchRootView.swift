// NotchRootView.swift
// One black shape that morphs between states. Width leads on the way out,
// height leads on the way back. Content fades and rises in after the shape moves.
// Inside one state the shape re-targets with one spring (the card changing tool).
// Around the shape: the hover rim light (closed and resting), the attention
// clay bleed, and the teleport fold. Every light sits outside the
// black silhouette, never under the camera.

import SwiftUI
import os

@MainActor
struct NotchRootView: View {
    @ObservedObject var state: AppState

    // Animated shape values. The content is laid out for the target size and
    // clipped by the animating shape, so text never reflows mid-spring.
    @State private var shapeWidth: CGFloat = 0
    @State private var shapeHeight: CGFloat = 0
    @State private var topRadius: CGFloat = Theme.Radius.closedTop
    @State private var bottomRadius: CGFloat = Theme.Radius.closedBottom
    @State private var shownMode: NotchMode = .closed

    /// Clay bleed opacity under the shape (0 outside attention).
    @State private var bleed: Double = 0
    /// Guards the delayed bleed settle against a newer arrival or departure.
    @State private var bleedGeneration = 0

    var body: some View {
        let layout = state.layout
        let target = layout.bodySize(for: shownMode, cardHeight: state.cardHeight)
        let raised = shownMode == .card || shownMode == .attention
        let rimOn = state.hovering && (shownMode == .closed || shownMode == .resting)

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .fill(Theme.Colors.notch)
                    .shadow(
                        color: raised ? Theme.Colors.shadow : Color.clear,
                        radius: raised ? Theme.Size.shadowRadius : 0,
                        x: 0,
                        y: raised ? Theme.Size.shadowY : 0
                    )

                ZStack(alignment: .top) {
                    content(for: shownMode, bodySize: target)
                        .frame(width: target.width, height: target.height, alignment: .top)
                        // The card's rows rise one by one; everything else rises as one.
                        .transition(Theme.Motion.contentTransition(rise: shownMode != .card))
                        .id(shownMode)
                }
                .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
                .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            }
            .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            // Every light lives behind the black, outside the silhouette: the black covers
            // whatever falls inside it, so nothing is drawn under the camera and the
            // closed state stays the hardware notch. Backgrounds never move the shape.
            .background(alignment: .top) { rim(on: rimOn) }
            .background(alignment: .top) { attentionBleed }
            #if DEBUG
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                    debugLog("rendered shape frame=\(f) size=\(g.size)")
                }
            })
            #endif
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusEffectDisabled()
        .onAppear { morph(to: state.mode, animated: false) }
        .onChange(of: state.mode) { _, newMode in morph(to: newMode, animated: true) }
        .onChange(of: state.layout) { _, _ in morph(to: state.mode, animated: false) }
        .onChange(of: state.cardHeight) { _, _ in morph(to: state.mode, animated: true) }
    }

    // MARK: Rim and bleed

    /// The Motion board M7's rim light, mirrored outward so it sits outside the black: the
    /// shape shifted 2 pt down minus the shape, a 2 pt crescent at 50% white under the flat
    /// bottom edge that thins to nothing up each bottom corner, so it fades out on the sides
    /// by geometry. Behind it, the board's `0 2px 12px` glow: the whole shape at 12%, dropped
    /// 2 pt and blurred 6 pt, drawn behind the black so only the spill outside shows. Nothing
    /// on the sides or top. Reduce Motion: the same crescent, no glow.
    private func rim(on: Bool) -> some View {
        ZStack {
            if !Theme.Motion.reduceMotion {
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .fill(Theme.Colors.rimGlow)
                    .offset(y: Theme.Size.rimGlowDrop)
                    .blur(radius: Theme.Size.rimGlowRadius)
            }
            NotchRimShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(Theme.Colors.rim)
        }
        .frame(width: shapeWidth, height: shapeHeight)
        // Room below the shape for the crescent and the glow's spill; nothing clips it.
        .frame(
            height: shapeHeight + Theme.Size.rimLine + Theme.Size.rimGlowDrop + 2 * Theme.Size.rimGlowRadius,
            alignment: .top
        )
        .opacity(on ? 1 : 0)
        .animation(on ? Theme.Motion.hoverIn : Theme.Motion.hoverOut, value: on)
        .allowsHitTesting(false)
    }

    /// A blurred clay ellipse behind the shape, centred below its bottom edge and wider
    /// than the whole shape, so the light falls under both wings rather than under the camera.
    private var attentionBleed: some View {
        Ellipse()
            .fill(Theme.Colors.attentionBleed)
            .frame(width: shapeWidth * Theme.Size.bleedWidthFactor, height: Theme.Size.bleedHeight)
            .blur(radius: Theme.Size.bleedBlur)
            .offset(y: shapeHeight - Theme.Size.bleedHeight / 2 + Theme.Size.bleedDrop)
            .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            .opacity(bleed)
            .allowsHitTesting(false)
    }

    // MARK: Content

    @ViewBuilder
    private func content(for mode: NotchMode, bodySize: CGSize) -> some View {
        switch mode {
        case .closed:
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.toggleFromNotchTap() }
        case .resting:
            RestingView(state: state, bodySize: bodySize)
        case .wings:
            WingsView(state: state, bodySize: bodySize)
        case .peek:
            if let peek = state.peek {
                PeekView(state: state, peek: peek, bodySize: bodySize)
                    .id(peek.id)
            } else {
                WingsView(state: state, bodySize: bodySize)
            }
        case .attention:
            if let request = state.currentPending {
                AttentionView(state: state, request: request, bodySize: bodySize)
            } else {
                Color.clear
            }
        case .card:
            CardView(state: state, bodySize: bodySize)
        }
    }

    // MARK: Morph

    private func morph(to mode: NotchMode, animated: Bool) {
        let layout = state.layout
        let outer = layout.outerSize(for: mode, cardHeight: state.cardHeight)
        let top = layout.topRadius(for: mode)
        let bottom = layout.bottomRadius(for: mode)
        let newWidth = outer.width
        let newHeight = outer.height
        debugLog("mode=\(mode) size=\(newWidth)x\(newHeight) notch=\(layout.notchWidth)x\(layout.notchHeight) card=\(state.cardHeight) shown=\(shownMode) cur=\(shapeWidth)x\(shapeHeight)")
        let arriving = mode == .attention && shownMode != .attention
        let leaving = mode != .attention && shownMode == .attention

        guard animated else {
            shapeWidth = newWidth
            shapeHeight = newHeight
            topRadius = top
            bottomRadius = bottom
            shownMode = mode
            bleed = mode == .attention ? Theme.Opacity.bleedRest : 0
            return
        }

        // `mode` and `cardHeight` often change in one update (opening lands on another tool,
        // closing resets it). The first call already set these targets with the sequenced
        // springs; a second call must not replace them with the re-target spring.
        if mode == shownMode && newWidth == shapeWidth && newHeight == shapeHeight
            && top == topRadius && bottom == bottomRadius {
            return
        }

        if mode == shownMode && !state.teleportFold {
            // Same state, new size: the card re-targets its height for another tool or a
            // request's diff. One spring, no axis sequencing.
            withAnimation(Theme.Motion.panelRetarget) {
                shapeWidth = newWidth
                shapeHeight = newHeight
                topRadius = top
                bottomRadius = bottom
            }
            return
        }

        if arriving { attentionArrived() }
        if leaving { attentionLeft() }

        if state.teleportFold {
            // Teleport: height folds up first (ease-in), then the width settles with a small bounce.
            withAnimation(Theme.Motion.foldHeight) {
                shapeHeight = newHeight
                topRadius = top
                bottomRadius = bottom
            }
            withAnimation(Theme.Motion.foldWidth) {
                shapeWidth = newWidth
            }
            withAnimation(Theme.Motion.contentIn) {
                shownMode = mode
            }
            return
        }

        // Growing: sideways first, then down. Shrinking: up first, then in, faster.
        let growing = newHeight >= shapeHeight
        let widthAnimation = growing
            ? Theme.Motion.width
            : Theme.Motion.closeWidth.delay(Theme.Motion.axisDelay)
        let heightAnimation = growing
            ? Theme.Motion.height.delay(Theme.Motion.axisDelay)
            : Theme.Motion.closeHeight

        withAnimation(widthAnimation) {
            shapeWidth = newWidth
        }
        withAnimation(heightAnimation) {
            shapeHeight = newHeight
            topRadius = top
            bottomRadius = bottom
        }
        withAnimation(Theme.Motion.contentIn) {
            shownMode = mode
        }
    }

    /// The clay bleed: 0 → 100% in 0.3 s, then 40% by 1 s. No breath: the shape growing to
    /// two rows is the signal, and a scale on top of the height spring read as a bounce.
    /// Reduce Motion: a static 40% bleed.
    private func attentionArrived() {
        bleedGeneration += 1
        if Theme.Motion.reduceMotion {
            withAnimation(Theme.Motion.reduced) { bleed = Theme.Opacity.bleedRest }
            return
        }
        withAnimation(Theme.Motion.bleedIn) { bleed = Theme.Opacity.bleedPeak }
        let generation = bleedGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.bleedInDuration) {
            guard bleedGeneration == generation else { return }
            withAnimation(Theme.Motion.bleedSettle) { bleed = Theme.Opacity.bleedRest }
        }
    }

    private func attentionLeft() {
        bleedGeneration += 1
        withAnimation(Theme.Motion.reduceMotion ? Theme.Motion.reduced : Theme.Motion.contentOut) { bleed = 0 }
    }
}
