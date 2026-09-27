// Theme.swift
// Every colour, radius, size, spring, duration, font, glyph and key label the
// app draws with. Views never use literal colours or numbers; they read them here.

import AppKit
import SwiftUI

extension Color {
    /// sRGB colour from a 0xRRGGBB literal. Used only inside Theme.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Theme {

    // MARK: - Colours

    enum Colors {
        /// The notch itself. Pure black so the closed state matches the hardware.
        static let notch = Color(hex: 0x000000)

        static let ink = Color.white
        static let inkSecondary = Color.white.opacity(0.62)
        static let inkTertiary = Color.white.opacity(0.42)
        static let inset = Color.white.opacity(0.07)
        static let hairline = Color.white.opacity(0.10)
        static let track = Color.white.opacity(0.12)
        static let selection = Color.white.opacity(0.10)
        static let tabSelected = Color.white.opacity(0.14)
        static let keycapFill = Color.white.opacity(0.10)
        static let keycapFillOnLight = Color.black.opacity(0.10)
        static let keycapTextOnLight = Color.black.opacity(0.62)
        static let cellEmpty = Color.white.opacity(0.14)

        static let clay = Color(hex: 0xD97757)
        /// "Needs you": Claude's clay. The triangle glyph, the two-row shape and the words
        /// "Needs you" tell it apart from the working spark, which is clay too.
        static let attention = Color(hex: 0xD97757)
        static let attentionText = Color(hex: 0xF0A080)
        static let attentionHighlight = Color(hex: 0xD97757, opacity: 0.14)
        static let attentionGlow = Color(hex: 0xD97757, opacity: 0.60)
        static let attentionGlowDim = Color(hex: 0xD97757, opacity: 0.15)
        static let green = Color(hex: 0x30D158)
        static let greenFill = Color(hex: 0x30D158, opacity: 0.18)
        static let red = Color(hex: 0xFF6961)
        static let redStrong = Color(hex: 0xFF453A)
        static let redFill = Color(hex: 0xFF6961, opacity: 0.18)
        static let blue = Color(hex: 0x64B5FF)
        static let purple = Color(hex: 0xC77DFF)

        static let diffAddedBackground = Color(hex: 0x30D158, opacity: 0.10)
        static let diffRemovedBackground = Color(hex: 0xFF6961, opacity: 0.10)
        static let diffHunk = Color(hex: 0x64B5FF)

        /// Primary pill: white fill, black text.
        static let primaryFill = Color.white
        static let primaryText = Color.black
        static let ghostFill = Color.white.opacity(0.10)

        /// Only the card and attention states carry a shadow.
        static let shadow = Color.black.opacity(0.45)

        // Token breakdown in the Usage tab.
        static let tokenCacheRead = blue
        static let tokenInput = purple
        static let tokenOutput = clay
        static let tokenCacheWrite = green
        /// Limit bars in the Usage tab and the header; context uses clay.
        static let limitBar = ink
        static let contextBar = clay

        /// Idle text in the wings ("Idle", "Done") sits back from the working verb.
        static let wingsIdleText = inkTertiary
        /// Collapsed wings: the session name, and the one state word on the right.
        static let wingsName = ink
        static let wingsWorkingText = inkSecondary
        static let wingsDoneText = inkSecondary
        static let wingsCountText = inkTertiary
        /// State glyphs in the wings: green check when done, dim dot when idle.
        static let doneGlyph = green
        static let idleGlyph = Color.white.opacity(0.28)
        /// Running subagent lanes.
        static let agentDot = clay
        static let laneLine = Color.white.opacity(0.14)
        static let doneChipFill = Color.white.opacity(0.08)
        /// One colour per subagent, cycled by the agent's index within its session.
        static let agentPalette: [Color] = [
            clay,
            blue,
            purple,
            green,
            Color(hex: 0xFFD60A),
            Color(hex: 0x5AC8FA),
        ]
        static func agent(_ index: Int) -> Color {
            agentPalette[((index % agentPalette.count) + agentPalette.count) % agentPalette.count]
        }
        /// Finished agents keep their colour, dimmed.
        static let agentFinishedOpacity: Double = 0.45

        // Settings page inside the card.
        static let settingsError = red
        static let settingsConnected = green
        static let settingsPartial = attention
        static let settingsDisconnected = inkTertiary
        static let switchOn = green
        static let switchOff = Color.white.opacity(0.18)
        static let switchKnob = Color.white
        static let segmentTrack = Color.white.opacity(0.07)
        static let segmentSelected = Color.white.opacity(0.18)

        // Diff view.
        static let diffLineNumber = inkTertiary
        static let diffText = inkSecondary
        /// The selected file row in Changes and Files (keyboard cursor).
        static let rowCursor = Color.white.opacity(0.06)

        // Files tab.
        /// The file whose preview is showing.
        static let treeOpened = Color.white.opacity(0.10)
        static let treeFolder = inkSecondary
        static let treeFile = ink
        static let treeChevron = inkTertiary
        static let filterFill = Color.white.opacity(0.07)
        static let filterPlaceholder = inkTertiary
        static let paneDivider = hairline
        static let badgeFill = Color.white.opacity(0.07)
        static let previewLineNumber = inkTertiary
        static let previewText = inkSecondary
        static let previewAddedBackground = Color(hex: 0x30D158, opacity: 0.12)
        static let previewRemovedMark = red
        static let previewAddedNumber = green

        // Sessions tab group header (it sticks, so it carries the card's own black).
        static let groupHeaderBackground = notch
        static let groupHeaderName = inkSecondary
        static let groupHeaderCount = inkTertiary

        /// Hover rim light on the closed and resting shape, and its soft glow.
        static let rim = Color.white.opacity(0.55)
        static let rimGlow = Color.white.opacity(0.12)
        /// Clay bleed under the shape when attention arrives (scaled by the bleed opacity).
        static let attentionBleed = Color(hex: 0xD97757, opacity: 0.35)
        /// The resting dot: green when the session finished, grey when idle.
        static let restingDone = green
        static let restingIdle = Color.white.opacity(0.42)

        static func state(_ state: SessionState) -> Color {
            switch state {
            case .working: return clay
            case .needsYou: return attention
            case .done: return green
            case .idle: return inkTertiary
            }
        }
    }

    // MARK: - Radii

    enum Radius {
        // Convex bottom corners of the shape, per state.
        static let closedBottom: CGFloat = 10
        static let wingsBottom: CGFloat = 14
        static let peekBottom: CGFloat = 14
        static let attentionBottom: CGFloat = 18
        static let cardBottom: CGFloat = 26

        // Concave "ears" where the shape meets the top edge of the screen.
        static let closedTop: CGFloat = 10
        static let wingsTop: CGFloat = 12
        static let peekTop: CGFloat = 12
        static let restingTop: CGFloat = 12
        static let restingBottom: CGFloat = 14
        static let attentionTop: CGFloat = 14
        static let cardTop: CGFloat = 18

        static let inset: CGFloat = 12
        static let tile: CGFloat = 14
        static let row: CGFloat = 10
        static let keycap: CGFloat = 4
        static let chip: CGFloat = 6
        static let diffCell: CGFloat = 1.5
        static let agentSquare: CGFloat = 1.5
        static let snippet: CGFloat = 8
    }

    // MARK: - Sizes and spacing

    enum Size {
        // Fallback when the screen has no notch (external display).
        static let fallbackNotchWidth: CGFloat = 180
        static let fallbackNotchHeight: CGFloat = 32

        // The panel is a fixed box; the shape draws at its top centre.
        static let panelWidth: CGFloat = 900
        static let panelHeight: CGFloat = 504
        /// Extra points above the shape counted as "inside" for mouse pass-through.
        static let hitSlop: CGFloat = 2

        // Shape body sizes per state (ears are added outside these widths).
        static let wingsWidth: CGFloat = 470
        static let restingWidth: CGFloat = 420
        static let peekWidth: CGFloat = 580
        static let attentionWidth: CGFloat = 620
        static let attentionExtraHeight: CGFloat = 40
        static let cardWidth: CGFloat = 620
        /// Minimum wing width on each side, used when the notch is wider than expected.
        static let minWing: CGFloat = 100

        // Card content height below the notch row, per card kind.
        /// Browsable tabs: includes the footer row (counts, settings gear).
        static let cardHeight: CGFloat = 424
        static let cardFooterHeight: CGFloat = 20
        static let requestCardHeight: CGFloat = 310
        static let commitCardHeight: CGFloat = 356
        static let questionCardHeight: CGFloat = 296

        static let sidePadding: CGFloat = 16
        static let wingInnerGap: CGFloat = 10
        /// Room inside a wing's clip so glyph rings and glows are never cut at the outer edge.
        static let wingEdgeInset: CGFloat = 6

        // Spacing scale.
        static let spaceXS: CGFloat = 2
        static let spaceS: CGFloat = 4
        static let spaceM: CGFloat = 8
        static let spaceL: CGFloat = 12
        static let spaceXL: CGFloat = 16

        // Wings.
        static let glyph: CGFloat = 13
        static let wingSpacing: CGFloat = 5
        static let dot: CGFloat = 6
        static let dotSpacing: CGFloat = 4
        static let maxDots: Int = 6

        // Rings and lines.
        static let ringLine: CGFloat = 1.5
        static let countdownRing: CGFloat = 14
        static let countdownRingLarge: CGFloat = 20
        static let countdownLine: CGFloat = 2
        static let peekLine: CGFloat = 3
        static let peekCircle: CGFloat = 18
        static let iconCircle: CGFloat = 28
        /// Symbol size relative to its circle.
        static let glyphInCircle: CGFloat = 0.5
        static let footerMinScale: CGFloat = 0.9
        static let maxQuestionOptions: Int = 3
        static let hairline: CGFloat = 0.5

        // Keycaps and pills.
        static let keycapMin: CGFloat = 16
        static let keycapHPadding: CGFloat = 4
        static let pillHeight: CGFloat = 34
        static let pillHPadding: CGFloat = 12
        static let pillSpacing: CGFloat = 6
        static let smallPillHPadding: CGFloat = 6
        static let smallPillHeight: CGFloat = 16
        static let tabHeight: CGFloat = 24
        static let tabHPadding: CGFloat = 10
        static let chipHPadding: CGFloat = 6
        static let chipHeight: CGFloat = 18
        static let buttonSpacing: CGFloat = 8
        /// The primary pill is this many units wide; the other two are one unit each.
        static let primaryUnits: CGFloat = 2

        // Bars and tiles.
        static let barHeight: CGFloat = 4
        static let headerBarWidth: CGFloat = 64
        static let stackedBarHeight: CGFloat = 8
        static let legendDot: CGFloat = 6
        static let tilePadding: CGFloat = 10
        static let insetPadding: CGFloat = 10

        // Usage tab: one fixed page, never scrolls. Heights derive from `cardHeight`.
        static let usageRowSpacing: CGFloat = 10
        static let usageTileSpacing: CGFloat = 8
        static let usageLineSpacing: CGFloat = 4
        static let usageLegendSpacing: CGFloat = 10
        static let tokenBarHeight: CGFloat = 8
        static let usageTokenBlockHeight: CGFloat = 60
        static let usageFootnoteHeight: CGFloat = 14
        /// Share of the tile rows' height that goes to the big 5-hour and Week tiles.
        static let usageBigTileShare: CGFloat = 0.56
        /// Height of a browsable tab pane: the card minus its paddings, the tab row and the footer.
        static var tabPaneHeight: CGFloat {
            cardHeight - spaceM - sidePadding - tabHeight - cardFooterHeight - 2 * spaceM
        }
        static var usageTileRowsHeight: CGFloat {
            tabPaneHeight - usageTokenBlockHeight - usageFootnoteHeight - 3 * usageRowSpacing
        }
        static var usageBigTileHeight: CGFloat { (usageTileRowsHeight * usageBigTileShare).rounded(.down) }
        static var usageSmallTileHeight: CGFloat { usageTileRowsHeight - usageBigTileHeight }

        // Hover rim light.
        static let rimLine: CGFloat = 2
        static let rimGlowRadius: CGFloat = 12
        /// The rim sits this far inside the shape's edge so the stroke never leaves the black.
        static let rimInset: CGFloat = 1

        // Clay bleed under the attention shape.
        static let bleedWidthFactor: CGFloat = 0.8
        static let bleedHeight: CGFloat = 44
        static let bleedBlur: CGFloat = 22
        /// How far below the shape's bottom edge the bleed's centre sits.
        static let bleedDrop: CGFloat = 4

        // Done peek check, drawn in a unit square inside the peek circle.
        static let checkLine: CGFloat = 1.8
        static let checkInset: CGFloat = 0.28

        // Changes tab.
        static let diffCellCount: Int = 5
        static let diffCellWidth: CGFloat = 5
        static let diffCellHeight: CGFloat = 8
        static let diffCellSpacing: CGFloat = 1.5
        static let snippetMaxHeight: CGFloat = 132
        static let snippetLinePadding: CGFloat = 6
        /// A snippet shorter than this opens inline by default.
        static let inlineSnippetMaxLines: Int = 8
        static let rowVPadding: CGFloat = 6
        static let rowHPadding: CGFloat = 8

        // Sessions tab: agent lanes under a session row.
        static let laneIndent: CGFloat = 22
        static let laneDot: CGFloat = 5
        static let laneVPadding: CGFloat = 3
        static let laneLineWidth: CGFloat = 1
        static let gearSize: CGFloat = 12
        /// Chevron plus its gap, so lane clocks line up with the row clock.
        static let chevronColumn: CGFloat = 14

        // Settings page inside the card.
        static let settingsCardHeight: CGFloat = 424
        static let settingsRowHeight: CGFloat = 28
        static let settingsGroupSpacing: CGFloat = 10
        static let settingsLabelSpacing: CGFloat = 4
        static let switchWidth: CGFloat = 28
        static let switchHeight: CGFloat = 16
        static let switchKnobInset: CGFloat = 2
        static let segmentHeight: CGFloat = 22
        static let segmentHPadding: CGFloat = 9
        static let segmentInset: CGFloat = 2
        static let stepperValueWidth: CGFloat = 36
        static let backPillHeight: CGFloat = 22
        static let backPillHPadding: CGFloat = 9

        // Subagent colour squares.
        static let agentSquare: CGFloat = 7
        static let agentSquareSpacing: CGFloat = 3
        /// The wings show coloured squares for up to this many running agents, then "N agents".
        static let maxWingAgentSquares: Int = 3
        static let maxHeaderAgents: Int = 3

        // Diff view.
        static let diffLineHeight: CGFloat = 16
        static let diffMaxHeight: CGFloat = 220
        static let diffLineNumberWidth: CGFloat = 30
        static let diffGutterSpacing: CGFloat = 4
        static let diffVPadding: CGFloat = 4
        static let groupHeaderTopPadding: CGFloat = 6

        // Sessions tab: one slim sticky header per repository.
        static let repoHeaderHeight: CGFloat = 22
        static let repoGroupSpacing: CGFloat = 6

        // Changes tab: one-line turn header.
        static let turnHeaderVPadding: CGFloat = 5
        static let turnFilesIndent: CGFloat = 14

        // Files tab: the tree on the left, the preview on the right.
        /// The tree column's share of the card's content width.
        static let fileTreeShare: CGFloat = 0.4
        static let filesColumnGap: CGFloat = 10
        static let filterHeight: CGFloat = 22
        static let filterHPadding: CGFloat = 8
        static let treeRowHeight: CGFloat = 20
        static let treeIndent: CGFloat = 12
        static let treeChevronWidth: CGFloat = 10
        static let treeRowHPadding: CGFloat = 6
        static let badgeHPadding: CGFloat = 4
        static let badgeHeight: CGFloat = 14
        static let previewLineHeight: CGFloat = 16
        static let previewNumberWidth: CGFloat = 34
        static let previewGutterSpacing: CGFloat = 8
        static let previewHPadding: CGFloat = 6
        static let previewVPadding: CGFloat = 4
        static let removedMarkWidth: CGFloat = 2
        /// Children beyond this index rise in together, so a big folder never trickles in.
        static let maxStaggeredChildren: Int = 12
        /// File previews kept in memory for flipping back and forth.
        static let maxCachedPreviews: Int = 8

        static let shadowRadius: CGFloat = 18
        static let shadowY: CGFloat = 8
    }

    // MARK: - Opacity

    enum Opacity {
        static let pressed: Double = 0.7
        /// Controls that do nothing right now (peek length while peeks are off).
        static let disabled: Double = 0.4
        static let pulseStart: Double = 0.8
        /// The resting state's worktree name; hover brings it to full.
        static let resting: Double = 0.6
        static let restingHover: Double = 1
        /// Clay bleed: peak on arrival, then where it settles.
        static let bleedPeak: Double = 1
        static let bleedRest: Double = 0.4
        /// Fill behind a symbol in a tinted circle.
        static let glyphCircle: Double = 0.2
    }

    // MARK: - Motion

    enum Motion {
        @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        static let reduced = Animation.easeInOut(duration: 0.2)

        /// Opening: width leads.
        @MainActor static var width: Animation { reduceMotion ? reduced : .spring(response: 0.45, dampingFraction: 0.72) }
        /// Opening: height follows.
        @MainActor static var height: Animation { reduceMotion ? reduced : .spring(response: 0.55, dampingFraction: 0.78) }
        /// Closing runs backwards, faster.
        @MainActor static var closeWidth: Animation { reduceMotion ? reduced : .spring(response: 0.34, dampingFraction: 0.86) }
        @MainActor static var closeHeight: Animation { reduceMotion ? reduced : .spring(response: 0.30, dampingFraction: 0.90) }
        /// Gap between the leading axis and the following axis.
        static let axisDelay: Double = 0.06

        static let contentFadeDelay: Double = 0.12
        static let contentFadeDuration: Double = 0.2
        static let contentOutDuration: Double = 0.08
        /// Content fades in and rises this far; no blur anywhere.
        static let contentRise: CGFloat = 10
        /// Card rows follow each other by this much.
        static let rowStagger: Double = 0.04
        static var contentIn: Animation { .easeOut(duration: contentFadeDuration).delay(contentFadeDelay) }
        static var contentOut: Animation { .easeIn(duration: contentOutDuration) }
        static func rowIn(_ index: Int) -> Animation {
            .easeOut(duration: contentFadeDuration).delay(contentFadeDelay + rowStagger * Double(index))
        }
        /// Content in: opacity plus a 10 pt rise (opacity only under Reduce Motion).
        /// `rise: false` for content whose rows rise on their own (the card).
        @MainActor static func contentTransition(rise: Bool) -> AnyTransition {
            let insertion: AnyTransition = (rise && !reduceMotion)
                ? AnyTransition.opacity.combined(with: .offset(y: contentRise))
                : AnyTransition.opacity
            return .asymmetric(
                insertion: insertion.animation(contentIn),
                removal: AnyTransition.opacity.animation(contentOut)
            )
        }

        // Hover rim light.
        static let rimDelay: Double = 0.25
        static var rimIn: Animation { .easeOut(duration: 0.18) }
        static var rimOut: Animation { .easeIn(duration: 0.25) }

        // Attention arrival: a 3% breath from the top edge and a clay bleed.
        static let breathScale: CGFloat = 1.03
        static let breathDuration: Double = 0.5
        static let bleedInDuration: Double = 0.3
        /// The bleed has settled to its resting opacity by this long after arrival.
        static let bleedSettledAt: Double = 1
        static var bleedIn: Animation { .easeOut(duration: bleedInDuration) }
        static var bleedSettle: Animation { .easeInOut(duration: bleedSettledAt - bleedInDuration) }

        // Tabs.
        @MainActor static var tabPill: Animation { reduceMotion ? reduced : .spring(response: 0.32, dampingFraction: 0.7) }
        static let tabInDuration: Double = 0.32
        static let tabOutDuration: Double = 0.2
        static var tabIn: Animation { .easeOut(duration: tabInDuration) }
        static var tabOut: Animation { .easeOut(duration: tabOutDuration) }
        /// Inset groups inside a sliding pane move by this share of the pane's offset, on top of it.
        static let tabParallax: CGFloat = 0.4
        /// Usage bars fill after the pane has landed.
        static let barFillDuration: Double = 0.5
        static var barFill: Animation { .easeOut(duration: barFillDuration).delay(tabInDuration) }

        // Done peek.
        static let checkDelay: Double = 0.15
        static let checkPopDuration: Double = 0.3
        static let checkPopOvershoot: CGFloat = 1.15
        /// Share of the pop spent rising to the overshoot; the rest springs back to 1.
        static let checkPopRiseShare: Double = 0.6
        static let checkDrawDuration: Double = 0.35
        static let countDelay: Double = 0.25
        static let countDuration: Double = 0.6
        static var checkDraw: Animation { .easeOut(duration: checkDrawDuration).delay(checkDelay) }
        static var countUp: Animation { .easeOut(duration: countDuration).delay(countDelay) }

        // Teleport fold: height collapses, then the width settles; the terminal comes up at 0.15 s.
        static let foldHeightDuration: Double = 0.28
        static var foldHeight: Animation { .easeIn(duration: foldHeightDuration) }
        static var foldWidth: Animation { .spring(response: 0.3, dampingFraction: 0.6).delay(foldHeightDuration) }
        static let teleportActivateAt: Double = 0.15
        /// The fold flag clears after this long.
        static let foldTotal: Double = 0.9

        static let tap = Animation.easeOut(duration: 0.12)
        static let chevronOpenDegrees: Double = 90
        static let ringStartDegrees: Double = -90

        /// Default peek length; the owner sets the real one in Settings.
        static let peekLifetime: Double = 4
        static let peekSecondsRange: ClosedRange<Double> = 2...8
        static let peekSecondsStep: Double = 1

        /// Hover to open: rest this long on the shape to open, leave the card this long to close.
        static let hoverOpenDelay: Double = 0.25
        static let hoverCloseDelay: Double = 0.40
        /// Inline hints ("No terminal found", "Copied") show this long.
        static let hintDuration: Double = 2
        /// A session that got a hook envelope this recently is driven by hooks; the transcript
        /// watcher does not override its state.
        static let hookDrivenWindow: Double = 10 * 60
        /// Sessions with no activity for this long leave the list.
        static let sessionIdleCutoff: Double = 2 * 3600
        /// A session counts as live (keeps the wings up) when active this recently.
        static let liveSessionWindow: Double = 10 * 60

        /// A hook agent and a transcript agent of the same type starting this close together are the same agent.
        static let agentMatchWindow: Double = 15
        static let permissionDeadline: Double = 60
        /// `.needsYou` without a pending request lasts at most this long.
        static let needsYouLifetime: Double = 90
        /// Transcript writes this soon after a needs-you notification belong to it, not to new activity.
        static let needsYouActivityGrace: Double = 2
        /// Status line limits older than this are not shown.
        static let limitsFreshWindow: Double = 10 * 60
        /// A reset closer than this reads "resets in 1h 52m"; further out, "resets Thu 3:40 PM".
        static let resetRelativeWindow: Double = 24 * 3600
        /// A transcript turn that started this long before the hook's prompt still counts as that turn.
        static let turnMatchSlack: Double = 5

        static let pulseDuration: Double = 1.4
        static let pulseScale: CGFloat = 1.9
        static let pulseStartScale: CGFloat = 1.0
        static var pulse: Animation { .easeOut(duration: pulseDuration).repeatForever(autoreverses: false) }

        static let breatheDuration: Double = 1.6
        static let breatheRadius: CGFloat = 6
        static var breathe: Animation { .easeInOut(duration: breatheDuration).repeatForever(autoreverses: true) }

        static let clockTick: Double = 1
    }

    // MARK: - Fonts (SF Pro and SF Mono through .system, tabular numerals)

    enum Fonts {
        static let captionSize: CGFloat = 12
        static let bodySize: CGFloat = 13
        static let titleSize: CGFloat = 16
        static let heroSize: CGFloat = 19
        static let keycapSize: CGFloat = 11
        static let monoSmallSize: CGFloat = 11
        static let bigNumberSize: CGFloat = 26
        static let tinySize: CGFloat = 10
        static let chevronSize: CGFloat = 9

        static let caption = Font.system(size: captionSize).monospacedDigit()
        static let captionMedium = Font.system(size: captionSize, weight: .medium).monospacedDigit()
        static let captionSemibold = Font.system(size: captionSize, weight: .semibold).monospacedDigit()
        static let body = Font.system(size: bodySize).monospacedDigit()
        static let bodyMedium = Font.system(size: bodySize, weight: .medium).monospacedDigit()
        static let bodySemibold = Font.system(size: bodySize, weight: .semibold).monospacedDigit()
        static let title = Font.system(size: titleSize, weight: .semibold).monospacedDigit()
        static let hero = Font.system(size: heroSize, weight: .semibold).monospacedDigit()
        static let heroTracking: CGFloat = -0.5
        static let bigNumber = Font.system(size: bigNumberSize, weight: .semibold).monospacedDigit()

        static let mono = Font.system(size: bodySize, design: .monospaced)
        static let monoCaption = Font.system(size: captionSize, design: .monospaced)
        static let monoSmall = Font.system(size: monoSmallSize, design: .monospaced)

        static let tiny = Font.system(size: tinySize).monospacedDigit()
        static let sectionTitle = Font.system(size: captionSize, weight: .semibold).monospacedDigit()

        static let keycap = Font.system(size: keycapSize, weight: .medium).monospacedDigit()
        static let chevron = Font.system(size: chevronSize, weight: .semibold)

        static func symbol(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    }

    // MARK: - SF Symbols

    enum Symbols {
        static let claude = "sparkle"
        static let attention = "exclamationmark.triangle.fill"
        static let question = "questionmark"
        static let done = "checkmark"
        static let teleport = "arrow.up.right"
        static let chevron = "chevron.right"
        static let settings = "gearshape"
        static let diff = "plusminus"
        static let back = "chevron.left"
        static let expand = "chevron.down"
    }

    // MARK: - Key labels for keycaps

    enum Keys {
        static let enter = "⏎"
        static let delete = "⌫"
        static let option = "⌥"
        static let space = "space"
        static let treeChevron = Font.system(size: treeChevronSize, weight: .semibold)
        static let badge = Font.system(size: tinySize, design: .monospaced)
        static let groupHeader = Font.system(size: captionSize, weight: .semibold).monospacedDigit()
        static let tab = "⇥"
        static let escape = "esc"
        static let always = "A"
        static let edit = "E"
        static let settings = "⌘,"
        static let copy = "Y"
        static let optionEnter = "⌥⏎"
        static let minus = "\u{2212}"
        static let plus = "+"
    }

    // MARK: - Glyph characters used in text

    enum Glyphs {
        static let minus = "\u{2212}"
        static let separator = " · "
        static let middot = "·"
        static let approx = "\u{2248} "
        static let ellipsis = "\u{2026}"
        /// "~$1.42": an estimated cost.
        static let estimate = "~"
        static let emDash = "\u{2014}"
    }

    // MARK: - Drawn glyphs

    enum Shapes {
        /// The done check, as points in a unit square (short leg, then long leg).
        static let check: [CGPoint] = [
            CGPoint(x: 0.0, y: 0.55),
            CGPoint(x: 0.36, y: 0.9),
            CGPoint(x: 1.0, y: 0.12),
        ]
    }
}
