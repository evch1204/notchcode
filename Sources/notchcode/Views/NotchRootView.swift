// NotchRootView.swift
// One black shape that morphs between states. Width leads on the way out,
// height leads on the way back. Content fades and rises in after the shape moves.
// Around the shape: the hover rim light (closed and resting), the attention
// breath and clay bleed, and the teleport fold.

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

    /// Bumped on each attention arrival; drives the 3% breath.
    @State private var breathTrigger = 0
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

                rim(on: rimOn)
            }
            .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            // The glow lives in a background so its size can never move the shape.
            .background(alignment: .top) { attentionBleed }
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                    debugLog("rendered shape frame=\(f) size=\(g.size)")
                }
            })
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

    /// A 2 pt light along the bottom edge, following the radius, with a soft glow.
    /// Reduce Motion: the same light, no glow.
    private func rim(on: Bool) -> some View {
        NotchRimShape(topRadius: topRadius, bottomRadius: bottomRadius, inset: Theme.Size.rimInset)
            .stroke(Theme.Colors.rim, style: StrokeStyle(lineWidth: Theme.Size.rimLine, lineCap: .round))
            .shadow(
                color: Theme.Motion.reduceMotion ? Color.clear : Theme.Colors.rimGlow,
                radius: Theme.Size.rimGlowRadius
            )
            .opacity(on ? 1 : 0)
            .animation(on ? Theme.Motion.rimIn : Theme.Motion.rimOut, value: on)
            .allowsHitTesting(false)
    }

    /// A blurred clay ellipse behind the shape, centred just below its bottom edge,
    /// so only the glow below the black shows.
    private var attentionBleed: some View {
        Ellipse()
            .fill(Theme.Colors.attentionBleed)
            .frame(width: shapeWidth * Theme.Size.bleedWidthFactor, height: Theme.Size.bleedHeight)
            .blur(radius: Theme.Size.bleedBlur)
            .offset(y: shapeHeight - Theme.Size.bleedHeight / 2 + Theme.Size.bleedDrop)
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
        let body = layout.bodySize(for: mode, cardHeight: state.cardHeight)
        let top = layout.topRadius(for: mode)
        let bottom = layout.bottomRadius(for: mode)
        let newWidth = body.width + 2 * top
        let newHeight = body.height
        if CommandLine.arguments.contains("--debug-log") {
            let line = "\(Date()) mode=\(mode) size=\(newWidth)x\(newHeight) notch=\(layout.notchWidth)x\(layout.notchHeight) card=\(state.cardHeight) shown=\(shownMode) cur=\(shapeWidth)x\(shapeHeight)\n"
            let url = NotchcodePaths.supportDirectory.appendingPathComponent("debug.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
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

    /// The breath from the top edge and the clay bleed: 0 → 100% in 0.3 s, then 40% by 1 s.
    /// Reduce Motion: no breath, a static 40% bleed.
    private func attentionArrived() {
        bleedGeneration += 1
        if Theme.Motion.reduceMotion {
            withAnimation(Theme.Motion.reduced) { bleed = Theme.Opacity.bleedRest }
            return
        }
        breathTrigger += 1
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

/// Appends a line to ~/Library/Application Support/notchcode/debug.log when launched with --debug-log.
func debugLog(_ text: String) {
    guard CommandLine.arguments.contains("--debug-log") else { return }
    let line = "\(Date()) \(text)\n"
    let url = NotchcodePaths.supportDirectory.appendingPathComponent("debug.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}
