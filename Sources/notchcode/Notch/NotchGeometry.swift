// NotchGeometry.swift
// Where the notch is, and how big the black shape is in each state.

import AppKit

/// The physical notch on the built-in screen, or a fallback box at the top
/// centre of the main screen when there is no notch.
struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    /// The notch rect in global screen coordinates (origin bottom-left).
    var notchFrame: NSRect {
        NSRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// Nil when there is no screen at all (the lid closed with nothing attached, or the
    /// moment a display is unplugged).
    @MainActor
    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = notched.auxiliaryTopLeftArea,
           let right = notched.auxiliaryTopRightArea {
            let width = notched.frame.width - left.width - right.width
            let height = notched.safeAreaInsets.top
            if width > 0 && height > 0 {
                return NotchGeometry(screen: notched, notchWidth: width, notchHeight: height, hasNotch: true)
            }
        }
        guard let fallback = NSScreen.main ?? screens.first else { return nil }
        return NotchGeometry(
            screen: fallback,
            notchWidth: Theme.Size.fallbackNotchWidth,
            notchHeight: Theme.Size.fallbackNotchHeight,
            hasNotch: false
        )
    }
}

/// Shape sizes per state, derived from the notch size and the Theme.
/// "Body" is the part below the ears; the ears add `topRadius` on each side.
struct NotchLayout: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    static let fallback = NotchLayout(
        notchWidth: Theme.Size.fallbackNotchWidth,
        notchHeight: Theme.Size.fallbackNotchHeight
    )

    func bodySize(for mode: NotchMode, cardHeight: CGFloat) -> CGSize {
        switch mode {
        case .closed:
            // Ears sit inside the notch width so the closed shape never leaves the hardware notch.
            return CGSize(width: max(0, notchWidth - 2 * Theme.Radius.closedTop), height: notchHeight)
        case .resting:
            return CGSize(width: widened(Theme.Size.restingWidth), height: notchHeight)
        case .wings:
            return CGSize(width: widened(Theme.Size.wingsWidth), height: notchHeight)
        case .peek:
            return CGSize(width: widened(Theme.Size.peekWidth), height: notchHeight)
        case .attention:
            return CGSize(width: widened(Theme.Size.attentionWidth, wing: stripWing), height: notchHeight + Theme.Size.attentionExtraHeight)
        case .card:
            return CGSize(width: widened(Theme.Size.cardWidth, wing: stripWing), height: notchHeight + cardHeight)
        }
    }

    func topRadius(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .closed: return Theme.Radius.closedTop
        case .resting: return Theme.Radius.restingTop
        case .wings: return Theme.Radius.wingsTop
        case .peek: return Theme.Radius.peekTop
        case .attention: return Theme.Radius.attentionTop
        case .card: return Theme.Radius.cardTop
        }
    }

    func bottomRadius(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .closed: return Theme.Radius.closedBottom
        case .resting: return Theme.Radius.restingBottom
        case .wings: return Theme.Radius.wingsBottom
        case .peek: return Theme.Radius.peekBottom
        case .attention: return Theme.Radius.attentionBottom
        case .card: return Theme.Radius.cardBottom
        }
    }

    /// Full drawn size including the ears. This is also the clickable area.
    func outerSize(for mode: NotchMode, cardHeight: CGFloat) -> CGSize {
        let body = bodySize(for: mode, cardHeight: cardHeight)
        return CGSize(width: body.width + 2 * topRadius(for: mode), height: body.height)
    }

    /// Width of one wing's content column for a given body width.
    func wingWidth(bodyWidth: CGFloat) -> CGFloat {
        max(0, (bodyWidth - notchWidth) / 2 - Theme.Size.sidePadding - Theme.Size.wingInnerGap)
    }

    /// One side of the open card and the attention row: the strip's tools, rule and gear,
    /// plus the wing's paddings. A wider notch (a scaled display) widens the card so the
    /// tools are never clipped.
    private var stripWing: CGFloat {
        Theme.Size.stripToolsWidth + Theme.Size.sidePadding + Theme.Size.wingInnerGap + Theme.Size.wingEdgeInset
    }

    /// Keeps wings usable when the notch is wider than the design assumed.
    private func widened(_ width: CGFloat, wing: CGFloat = Theme.Size.minWing) -> CGFloat {
        max(width, notchWidth + 2 * wing)
    }
}
