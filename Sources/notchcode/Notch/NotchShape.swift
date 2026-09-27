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
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bodyWidth = rect.width - 2 * top
        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))

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

/// The bottom edge of `NotchShape`, inset so a stroke stays inside the black: from where the
/// bottom-left corner starts, around it, along the bottom, and around the bottom-right corner.
/// Used for the hover rim light, so the light follows the shape's radius exactly.
struct NotchRimShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var inset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Same clamping as NotchShape, so both agree at every size.
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bodyWidth = rect.width - 2 * top
        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))

        let left = rect.minX + top + inset
        let right = rect.maxX - top - inset
        let floor = rect.maxY - inset
        let radius = max(0, bottom - inset)

        var path = Path()
        path.move(to: CGPoint(x: left, y: floor - radius))
        path.addArc(
            tangent1End: CGPoint(x: left, y: floor),
            tangent2End: CGPoint(x: left + radius, y: floor),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: right, y: floor),
            tangent2End: CGPoint(x: right, y: floor - radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: right, y: floor - radius))
        return path
    }
}
