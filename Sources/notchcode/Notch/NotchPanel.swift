// NotchPanel.swift
// A borderless, non-activating panel above the menu bar. It is a fixed box;
// the SwiftUI content draws the shape at its top centre. Everything outside the
// drawn shape ignores the mouse so clicks reach the apps underneath.

import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    /// True only while the card is open, so keys reach the card and focus
    /// otherwise stays in the terminal.
    var allowsKey = false

    let container: NotchContainerView

    init(rootView: NotchRootView) {
        let rect = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: Theme.Size.panelHeight)
        container = NotchContainerView(frame: rect)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        // Set after every other property: isFloatingPanel and friends reset the level.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

        let hosting = NotchHostingView(rootView: rootView)
        hosting.sizingOptions = []
        // The panel sits over the camera housing on purpose: never let the hosting view
        // shrink or shift the content for the notch's safe area.
        hosting.safeAreaRegions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Never let AppKit push the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// The drawn shape's rect in global screen coordinates.
    func interactiveScreenRect() -> NSRect {
        let size = container.interactiveSize
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height + Theme.Size.hitSlop
        )
    }
}

/// Content view that only claims hits inside the drawn shape.
final class NotchContainerView: NSView {
    /// Outer size of the shape (including ears), anchored at the top centre.
    var interactiveSize: CGSize = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let rect = NSRect(
            x: (bounds.width - interactiveSize.width) / 2,
            y: bounds.height - interactiveSize.height,
            width: interactiveSize.width,
            height: interactiveSize.height
        )
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Hosting view that takes the first click, so a click on the notch acts
/// straight away without first making the panel key.
final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
