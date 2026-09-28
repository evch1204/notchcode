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

/// The outline of `NotchShape` below its ears, pushed `outset` points outside the black so a
/// stroke of that width never touches the silhouette: down the left side from where the ear
/// ends, around the bottom-left corner, along the bottom, around the bottom-right corner, and
/// up the right side. Used for the hover rim light, so the light follows the shape's radius
/// and sits where the camera housing cannot hide it.
struct NotchRimShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var outset: CGFloat

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

        let left = rect.minX + top - outset
        let right = rect.maxX - top + outset
        let floor = rect.maxY + outset
        let radius = max(0, bottom + outset)
        // The sides start where the ear meets the body.
        let sideTop = min(rect.minY + top, floor - radius)

        var path = Path()
        path.move(to: CGPoint(x: left, y: sideTop))
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
        path.addLine(to: CGPoint(x: right, y: sideTop))
        return path
    }
}
