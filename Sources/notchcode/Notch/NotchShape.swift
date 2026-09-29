// NotchShape.swift
// The one black shape. Concave "ears" at the top corners where it meets the
// screen edge, convex rounded corners at the bottom.
//
//   ____                          ____
//       \  <- topRadius (ear)    /
//        |                      |
//         \____________________/  <- bottomRadius
//
// The rect's top edge spans the full width; the body sits `topRadius` in from each side.

import SwiftUI

/// The ear and corner radii that fit `rect`: ears at most a quarter of the width and half
/// the height, corners at most half the body and what the ears leave of the height.
func clampedRadii(top topRadius: CGFloat, bottom bottomRadius: CGFloat, in rect: CGRect) -> (top: CGFloat, bottom: CGFloat) {
    let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
    let bodyWidth = rect.width - 2 * top
    let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))
    return (top, bottom)
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let (top, bottom) = clampedRadii(top: topRadius, bottom: bottomRadius, in: rect)

        let left = rect.minX + top
        let right = rect.maxX - top

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left ear: concave, from the top edge down into the body's left side.
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.minY),
            tangent2End: CGPoint(x: left, y: rect.minY + top),
            radius: top
        )
        // Left side down to the bottom-left corner.
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left + bottom, y: rect.maxY),
            radius: bottom
        )
        // Bottom edge to the bottom-right corner.
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY),
            tangent2End: CGPoint(x: right, y: rect.maxY - bottom),
            radius: bottom
        )
        // Right side up to the right ear.
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: top
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The hover rim light: the Motion board M7's `inset 0 -2px 0 0` mirrored outward. The
/// shape's body shifted `rimLine` down, minus `NotchShape` in place: a crescent `rimLine`
/// thick under the flat bottom edge that thins to nothing up each bottom corner, vanishing
/// where the arc turns vertical. Nothing on the sides or top. Fill it, don't stroke it.
/// The ears are left out of the shifted copy (the board's box has none): shifted, a concave
/// ear would leave a sliver of light along the screen edge.
struct NotchRimShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Same clamping as NotchShape, so both agree at every size.
        let (top, bottom) = clampedRadii(top: topRadius, bottom: bottomRadius, in: rect)
        let left = rect.minX + top
        let right = rect.maxX - top
        let drop = Theme.Size.rimLine

        // The body: the shape without its ears, shifted down.
        var body = Path()
        body.move(to: CGPoint(x: left, y: rect.minY))
        body.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left + bottom, y: rect.maxY),
            radius: bottom
        )
        body.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY),
            tangent2End: CGPoint(x: right, y: rect.maxY - bottom),
            radius: bottom
        )
        body.addLine(to: CGPoint(x: right, y: rect.minY))
        body.closeSubpath()

        let shifted = body.applying(CGAffineTransform(translationX: 0, y: drop))
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: rect)
        return shifted.subtracting(shape)
    }
}
