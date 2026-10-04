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

        // Base colours. Everything below is one of these, or one of these at an opacity.
        static let ink = Color.white
        static let clay = Color(hex: 0xD97757)
        static let green = Color(hex: 0x30D158)
        static let red = Color(hex: 0xFF6961)
        static let blue = Color(hex: 0x64B5FF)
        static let purple = Color(hex: 0xC77DFF)
        static let yellow = Color(hex: 0xFFD60A)
        static let cyan = Color(hex: 0x5AC8FA)

        static let inkSecondary = ink.opacity(0.62)
        static let inkTertiary = ink.opacity(0.42)
        static let inset = ink.opacity(0.07)
        static let hairline = ink.opacity(0.10)
        static let track = ink.opacity(0.12)
        /// The quiet white fill shared by keycaps, neutral actions and the selected row.
        static let quietFill = ink.opacity(0.10)
        static let selection = quietFill
        static let keycapFill = quietFill
        static let keycapFillOnLight = Color.black.opacity(0.10)
        static let keycapTextOnLight = Color.black.opacity(0.62)
        static let cellEmpty = ink.opacity(0.14)

        // The toolbar strip (the open card, and the collapsed strip on hover).
        /// A tool segment at rest draws nothing; hover lifts it, selection fills it.
        static let segmentHover = ink.opacity(0.09)
        static let segmentPressed = ink.opacity(0.05)
        static let toolSelected = ink.opacity(0.16)
        static let segmentIcon = ink.opacity(0.66)
        static let segmentIconSelected = ink
        /// Keyboard focus ring that rides the selected tool while the card has the keys.
        static let toolFocusRing = ink.opacity(0.38)
        /// The short bar under the selected tool where the well hangs from the strip.
        static let bridge = ink.opacity(0.30)
        /// Hairline between the strip and the well.
        static let stripDivider = ink.opacity(0.09)
        /// The thin vertical rule between the four tools and the gear.
        static let toolGroupRule = ink.opacity(0.14)
        /// Small numeric badge on the Sessions tool.
        static let toolBadgeFill = ink.opacity(0.14)
        static let toolBadgeText = ink.opacity(0.8)
        /// The card's content well: a lighter inset under the strip.
        static let well = ink.opacity(Opacity.well)
        static let wellStroke = ink.opacity(0.06)
        /// The tool name caption under the strip: an opaque dark pill so it reads over the well.
        static let toolLabelFill = Color(hex: 0x262626)
        static let toolLabelStroke = ink.opacity(0.10)
        static let toolLabelText = inkSecondary

        /// Primary action: white fill, black text.
        static let primaryFill = Color.white
        static let primaryText = Color.black
        static let ghostFill = quietFill

        // Action segments (Deny · Always · Allow, Skip · Edit · Commit).
        static let allowFill = primaryFill
        static let allowText = primaryText
        /// The countdown draining along Allow's bottom edge.
        static let allowBar = primaryText.opacity(0.35)
        static let denyFill = red.opacity(0.16)
        static let denyText = red
        static let neutralActionFill = quietFill
        static let neutralActionText = ink

        /// An action segment's fill, text and countdown bar, by its role.
        static func action(_ role: ActionRole) -> (fill: Color, text: Color, bar: Color) {
            switch role {
            case .allow: return (allowFill, allowText, allowBar)
            case .deny: return (denyFill, denyText, inkSecondary)
            case .neutral: return (neutralActionFill, neutralActionText, inkSecondary)
            }
        }

        /// "Needs you": Claude's clay. The triangle glyph, the two-row shape and the words
        /// "Needs you" tell it apart from the working spark, which is clay too.
        static let attention = clay
        static let attentionText = Color(hex: 0xF0A080)
        static let attentionHighlight = clay.opacity(0.14)
        static let attentionGlow = clay.opacity(0.60)
        static let attentionGlowDim = clay.opacity(0.15)
        static let greenFill = green.opacity(0.18)
        static let redFill = red.opacity(0.18)

        static let diffAddedBackground = green.opacity(0.10)
        static let diffRemovedBackground = red.opacity(0.10)
        /// The words that differ inside a paired removed and added line.
        static let diffAddedWord = green.opacity(0.34)
        static let diffRemovedWord = red.opacity(0.34)
        static let diffHunk = blue
        /// The diff's minimap: its track, the change marks (green, red), the visible range.
        static let diffMinimapTrack = ink.opacity(0.05)
        static let diffMinimapViewport = ink.opacity(0.10)
        static let diffMinimapRing = toolFocusRing

        /// Only the card and attention states carry a shadow.
        static let shadow = Color.black.opacity(0.45)

        // Token breakdown in the Usage tab.
        static let tokenCacheRead = blue
        static let tokenInput = purple
        static let tokenOutput = clay
        static let tokenCacheWrite = green
        /// Limit bars in the Usage tool and the footer meter; context uses clay.
        static let limitBar = ink
        /// A limit bar at or past `Limits.limitWarnPercent`.
        static let limitBarHigh = clay
        static let contextBar = clay

        /// Collapsed wings: the session name and the "+N sessions" count.
        static let wingsName = ink
        static let wingsCountText = inkTertiary
        /// State glyphs in the wings: green check when done, dim dot when idle.
        static let doneGlyph = green
        static let idleGlyph = ink.opacity(0.28)
        /// Running subagent lanes.
        static let laneLine = ink.opacity(0.14)
        static let doneChipFill = ink.opacity(0.08)
        /// One colour per subagent, cycled by the agent's index within its session.
        static let agentPalette: [Color] = [
            clay,
            blue,
            purple,
            green,
            yellow,
            cyan,
        ]
        static func agent(_ index: Int) -> Color {
            agentPalette[((index % agentPalette.count) + agentPalette.count) % agentPalette.count]
        }

        // Settings page inside the card.
        static let settingsError = red
        static let settingsConnected = green
        static let settingsPartial = attention
        static let settingsDisconnected = inkTertiary
        static let switchOn = green
        static let switchOff = ink.opacity(0.18)
        static let switchKnob = Color.white
        static let pickerTrack = ink.opacity(0.07)
        static let pickerSelected = ink.opacity(0.18)

        // Diff view.
        static let diffLineNumber = inkTertiary
        static let diffText = inkSecondary
        /// The selected file row in Changes and Files (keyboard cursor).
        static let rowCursor = ink.opacity(0.06)

        // Changes tool (Direction G, Timeline).
        /// The spine down the timeline's left edge.
        static let changesSpine = hairline
        /// A turn with files: a filled node on the spine.
        static let changesNode = ink
        /// The live turn's node and its breathing halo.
        static let changesNodeLive = clay
        static let changesHalo = clay.opacity(0.25)
        /// A quiet turn's tick, and the three stacked ticks of a quiet group.
        static let changesTick = inkTertiary
        /// A file chip; the selected one, and the hovered one, a step brighter.
        static let changesChipFill = filterFill
        static let changesChipSelected = quietFill
        /// The keyboard cursor's ring around a chip.
        static let changesChipRing = inkSecondary

        // Files tab.
        /// The file whose preview is showing.
        static let treeOpened = quietFill
        static let treeFolder = inkSecondary
        static let treeFile = ink
        static let treeChevron = inkTertiary
        static let filterFill = ink.opacity(0.07)
        static let filterPlaceholder = inkTertiary
        static let paneDivider = hairline
        static let badgeFill = ink.opacity(0.07)
        static let previewLineNumber = inkTertiary
        static let previewText = inkSecondary
        static let previewAddedBackground = green.opacity(0.12)
        static let previewRemovedMark = red
        static let previewAddedNumber = green
        // Markdown preview in the Files tool.
        static let markdownText = inkSecondary
        static let markdownHeading = ink
        static let markdownMarker = inkTertiary
        static let markdownLink = blue
        static let markdownCodeFill = inset
        static let markdownQuoteRule = track
        static let markdownRule = hairline
        static let markdownTableHeader = inset

        // Sessions tab group header. It sticks over the well, so it carries the well's
        // colour flattened onto the black (the well's white opacity as a grey).
        static let groupHeaderBackground = Color(.sRGB, white: Opacity.well, opacity: 1)
        static let groupHeaderName = inkSecondary
        static let groupHeaderCount = inkTertiary

        // Git tool.
        static let gitBranch = ink
        static let gitStatus = inkSecondary
        static let gitPushed = green
        static let gitError = red
        static let gitSection = groupHeaderName
        /// The target pill ("notchcode › seadevil ▾"): the repository dim, the place in ink.
        static let gitTargetRepo = inkTertiary
        static let gitTargetPlace = ink
        static let gitTargetNote = inkTertiary
        /// The file kind badge (M, A, D) in the diff pane's header.
        static let gitKindText = inkSecondary
        static let gitKindFill = badgeFill
        /// The branch picker: the repository pill's folder, the rows, the filter's lit match.
        static let gitPickerPath = inkTertiary
        static let gitPickerBranch = ink
        static let gitPickerPlace = inkSecondary
        static let gitPickerNowhere = inkTertiary
        static let gitPickerCount = inkSecondary
        static let gitPickerClean = inkTertiary
        static let gitPickerCursorStroke = hairline
        static let gitFilterMatch = ink.opacity(0.14)
        /// The repository dropdown over the rows: the well's colour flattened (as the
        /// Sessions group header), the inset on top, a hairline edge.
        static let gitRepoMenuBase = groupHeaderBackground
        static let gitRepoMenuFill = inset
        static let gitRepoMenuStroke = hairline
        static let gitRepoMenuName = ink
        static let gitRepoMenuOther = inkSecondary
        /// The commit checkboxes: a tertiary edge, white when on with a dark mark (the white
        /// pill's keycap text); an unchecked file's name dims.
        static let gitCheckStroke = inkTertiary
        static let gitCheckFill = ink
        static let gitCheckMark = keycapTextOnLight
        static let gitUnchecked = inkTertiary
        /// The ring on the commit form's focused field.
        static let gitFieldFocusRing = ink.opacity(0.24)
        /// The dock after a commit: "Committed · …" with Undo, quiet (it is not a field).
        static let gitReceiptFill = quietFill
        /// The rail's checked-files totals ("+38 −6") and the dock's pen.
        static let gitRailTotals = inkTertiary
        /// The commit form's co-author chips and the ring on the suggestion ⏎ adds.
        static let gitCoauthorChipFill = quietFill
        static let gitCoauthorChipText = inkSecondary
        static let gitSuggestionRing = inkSecondary

        /// A session's permission mode, as a word in its Sessions row and the open card's status
        /// line: bypass in clay (the dangerous one), plan in blue, the rest tertiary.
        static func permissionMode(_ raw: String?) -> Color {
            switch raw {
            case "bypassPermissions": return clay
            case "plan": return blue
            default: return inkTertiary
            }
        }

        /// Hover rim light (Motion board M7): the crescent under the bottom edge of the closed
        /// and resting shape (50% white), and its glow (12%). Both sit outside the black.
        static let rim = ink.opacity(0.5)
        static let rimGlow = ink.opacity(0.12)
        /// Clay bleed below the shape when attention arrives (scaled by the bleed opacity).
        static let attentionBleed = clay.opacity(0.35)
        /// The resting dot: green when the session finished, grey when idle.
        static let restingDone = green
        static let restingIdle = inkTertiary

        /// A state's glyph and dot colour.
        static func stateGlyph(_ state: SessionState) -> Color {
            switch state {
            case .working: return clay
            case .needsYou: return attention
            case .done: return doneGlyph
            case .idle: return idleGlyph
            }
        }

        /// A state's word ("Needs you", "Editing", "Done", "Idle").
        static func stateText(_ state: SessionState) -> Color {
            switch state {
            case .needsYou: return attentionText
            case .working: return clay
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
        static let restingBottom: CGFloat = 14
        static let peekBottom: CGFloat = 14
        static let attentionBottom: CGFloat = 18
        static let cardBottom: CGFloat = 26

        // Concave "ears" where the shape meets the top edge of the screen.
        static let closedTop: CGFloat = 10
        static let wingsTop: CGFloat = 12
        static let peekTop: CGFloat = 12
        static let restingTop: CGFloat = 12
        static let attentionTop: CGFloat = 14
        static let cardTop: CGFloat = 18

        static let inset: CGFloat = 12
        static let tile: CGFloat = 14
        static let row: CGFloat = 10
        static let keycap: CGFloat = 4
        static let chip: CGFloat = 6
        /// The Git tool's commit checkboxes.
        static let gitCheckbox: CGFloat = 3
        static let diffCell: CGFloat = 1
        static let diffMinimap: CGFloat = 2
        static let diffMinimapViewport: CGFloat = 3
        static let agentSquare: CGFloat = 1.5
        static let snippet: CGFloat = 8

        // The toolbar strip.
        /// Tool and action segments.
        static let segment: CGFloat = 6
        /// Concentric with the segment it rings.
        static let toolFocus: CGFloat = segment + Size.toolFocusOutset
        static let bridge: CGFloat = 1
        static let toolBadge: CGFloat = 4
        static let toolLabel: CGFloat = 5
        /// The card's content well.
        static let well: CGFloat = 14
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
        /// Attention and the card share one width, so the three action segments fit the
        /// right wing with room. The panel holds the outer size plus ears and shadow.
        static let attentionWidth: CGFloat = 640
        static let attentionExtraHeight: CGFloat = 40
        static let cardWidth: CGFloat = attentionWidth
        /// Minimum wing width on each side, used when the notch is wider than expected.
        static let minWing: CGFloat = 100

        // Card content height below the strip, per tool. The card re-targets its height
        // with one spring when the tool changes, so each tool gets the room it needs.
        static let sessionsCardHeight: CGFloat = 400
        static let changesCardHeight: CGFloat = 424
        static let filesCardHeight: CGFloat = 440
        static let usageCardHeight: CGFloat = 420
        static let gitCardHeight: CGFloat = 424
        /// The Git tool: the header row (branch, status, the sync pill).
        static let gitHeaderHeight: CGFloat = 26
        static let gitPushingGlyph: CGFloat = 10
        /// The rail: its header row ("Uncommitted · 4"), and its width folded (⌘B), the
        /// checkbox column only.
        static let gitRailHeaderHeight: CGFloat = treeRowHeight
        static let gitRailFolded: CGFloat = 22
        /// The stage's header row (the ⌘B pill, then the file, "Commit to main", or nothing).
        static let gitStageHeaderHeight: CGFloat = treeRowHeight
        /// The dock at the rail's foot: the summary field's box, the same height as the form's.
        static let gitDockHeight: CGFloat = gitFieldHeight
        /// Between the dock's box and the Undo pill inside it ((26 − 22) / 2).
        static let gitDockPillInset: CGFloat = (gitFieldHeight - actionHeight) / 2
        /// The confirm's question sits with its centre at this share of the stage's height.
        static let gitConfirmCentre: CGFloat = 0.4
        /// Co-author chips: their padding, the "recent" suggestion row, the ring on the first.
        static let gitChipVPadding: CGFloat = 2
        static let gitChipHPadding: CGFloat = 6
        static let gitChipGap: CGFloat = 4
        static let gitSuggestionRowHeight: CGFloat = 20
        static let gitSuggestionRing: CGFloat = 1
        /// The green check before "Nothing to commit · up to date" in the empty diff pane.
        static let gitCleanCircle: CGFloat = 22
        /// The target pill never takes more than this; the place truncates in the middle.
        static let gitTargetMaxWidth: CGFloat = 220
        /// The push confirm's question wraps at this width, two lines at most.
        static let gitConfirmMaxWidth: CGFloat = 360
        /// The file kind badge (M, A, D) in the diff pane's header.
        static let gitKindWidth: CGFloat = 14
        /// The branch picker: two-line rows, the worktree glyph before "worktree seadevil",
        /// the repository dropdown.
        static let gitBranchRowHeight: CGFloat = 40
        static let gitBranchRowHPadding: CGFloat = 10
        static let gitBranchLineGap: CGFloat = 1
        static let gitPlaceGlyph: CGFloat = 9
        static let gitRepoMenuWidth: CGFloat = 300
        static let gitRepoMenuRowHeight: CGFloat = 26
        static let gitRepoMenuPadding: CGFloat = 4
        static let gitPickerPathMaxWidth: CGFloat = 260
        /// The commit checkboxes and their gap to the file name.
        static let gitCheckbox: CGFloat = 12
        static let gitCheckboxGap: CGFloat = 6
        /// The mark inside a checkbox: the drawn check's box and stroke, the mixed state's dash.
        static let gitCheckMark: CGFloat = 8
        static let gitCheckLine: CGFloat = 1.6
        static let gitCheckDash: CGFloat = 6
        static let gitCheckboxStroke: CGFloat = 1
        /// Unticking: the box's fill shrinks to this scale as it fades.
        static let gitUntickScale: CGFloat = 0.6
        /// The commit form: the summary box, its side padding, the description's least height,
        /// and the text view's own inset that its "Description" prompt lines up with.
        static let gitFieldHeight: CGFloat = 26
        static let gitFieldHPadding: CGFloat = 8
        static let gitFieldVPadding: CGFloat = 6
        static let gitDescriptionMinHeight: CGFloat = 60
        static let gitDescriptionTextInset: CGFloat = 5
        /// The commit form's focus ring.
        static let gitFieldFocusStroke: CGFloat = 1
        static let cardFooterHeight: CGFloat = 20
        static let requestCardHeight: CGFloat = 310
        /// A permission or commit card with its diff open. Keeps the panel clear of the notch row plus shadow.
        static let requestCardHeightExpanded: CGFloat = 440
        /// A plan request: the rendered plan takes the room a diff takes.
        static let planCardHeight: CGFloat = 440
        static let commitCardHeight: CGFloat = 356
        static let questionCardHeight: CGFloat = 296
        static let settingsCardHeight: CGFloat = 424

        static let sidePadding: CGFloat = 16
        static let wingInnerGap: CGFloat = 10
        /// Room inside a wing's clip so glyph rings and glows are never cut at the outer edge.
        static let wingEdgeInset: CGFloat = 6

        // Spacing scale.
        static let spaceXS: CGFloat = 2
        static let spaceS: CGFloat = 4
        static let spaceM: CGFloat = 8
        static let spaceL: CGFloat = 12

        // Wings.
        static let glyph: CGFloat = 13
        static let wingSpacing: CGFloat = 5
        static let dot: CGFloat = 6

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
        static let hairline: CGFloat = 0.5

        // Keycaps and pills.
        static let keycapMin: CGFloat = 16
        static let keycapHPadding: CGFloat = 4
        static let smallPillHPadding: CGFloat = 6
        static let smallPillHeight: CGFloat = 16
        static let chipHPadding: CGFloat = 6
        static let chipHeight: CGFloat = 18

        // Bars and tiles.
        static let barHeight: CGFloat = 4
        static let footerBarWidth: CGFloat = 64
        static let legendDot: CGFloat = 6
        static let insetPadding: CGFloat = 10
        /// Padding inside the card's content well.
        static let wellPadding: CGFloat = 8

        // The toolbar strip: tool segments.
        static let toolWidth: CGFloat = 36
        static let gearWidth: CGFloat = 26
        static let toolHeight: CGFloat = 22
        static let toolGap: CGFloat = 2
        /// The stroked outlines span about three quarters of their box, so 15 pt reads like the 11 pt symbols did.
        static let toolIcon: CGFloat = 15
        /// A tool icon's stroke as a share of its size: the canvas draws 2.4 in a 24 box.
        static let toolStrokeRatio: CGFloat = 2.4 / 24
        /// The gear's stroke, a little finer: 2.2 in the canvas's 24 box.
        static let gearStrokeRatio: CGFloat = 2.2 / 24
        /// The collapsed strip's tools on hover: narrower, so all five fit the resting wing.
        static let compactToolWidth: CGFloat = 20
        static let compactToolGap: CGFloat = 1
        /// The collapsed strip's five tools side by side. The resting and wings shapes widen
        /// past `restingWidth` / `wingsWidth` to keep this whole (NotchLayout).
        static var compactToolsWidth: CGFloat {
            let tools = CGFloat(CardTab.browsable.count)
            return tools * compactToolWidth + (tools - 1) * compactToolGap
        }
        static let toolGroupGap: CGFloat = 6
        static let toolGroupRuleHeight: CGFloat = 12
        static let toolRuleWidth: CGFloat = 1
        /// The focus ring sits this far outside the tool segment.
        static let toolFocusOutset: CGFloat = 2
        static let toolFocusLine: CGFloat = 1
        static let bridgeWidth: CGFloat = 14
        static let bridgeHeight: CGFloat = 2
        /// The open strip's right wing: the tools, the rule with its padding, the gear,
        /// and the gaps between them. The card widens past `cardWidth` to keep this whole.
        static var stripToolsWidth: CGFloat {
            let tools = CGFloat(CardTab.browsable.count)
            let rule = toolRuleWidth + 2 * toolGroupGap
            return tools * toolWidth + (tools + 1) * toolGap + rule + gearWidth
        }
        /// Room left free on the camera side of the tools, so the first tool's focus ring
        /// (outset plus its line) is never cut by the wing's clip.
        static let stripToolsSlack: CGFloat = toolFocusOutset + toolFocusLine
        static let toolBadgeHeight: CGFloat = 11
        static let toolBadgeHPadding: CGFloat = 3
        static let toolBadgeOffset: CGFloat = 4
        // The tool name caption: a small pill hung just under the strip (open card), or
        // the collapsed strip's left wing (there is no room below it inside the black).
        static let toolLabelHeight: CGFloat = 16
        static let toolLabelHPadding: CGFloat = 6
        /// Gap between the strip's hairline and the top of the pill.
        static let toolLabelDrop: CGFloat = 3
        // Action segments.
        static let actionHeight: CGFloat = 22
        static let actionHPadding: CGFloat = 6
        static let actionGap: CGFloat = 3
        static let actionKeyGap: CGFloat = 3
        static let countdownBar: CGFloat = 2
        static let countdownBarInset: CGFloat = 5
        /// The open card's status segment (left wing).
        static let statusSpacing: CGFloat = 8
        /// The narrowest left wing the status segment gets: what the four-tool card gave it
        /// on a 179 pt notch ((640 − 179) / 2 − 26). The card widens to keep it.
        static let statusMinWidth: CGFloat = 204

        // Usage tab: one fixed page, never scrolls. The limits row takes what the others leave.
        static let usageRowSpacing: CGFloat = 10
        static let usageTileSpacing: CGFloat = 8
        static let usageLineSpacing: CGFloat = 4
        static let usageLegendSpacing: CGFloat = 10
        /// The context bar.
        static let tokenBarHeight: CGFloat = 8
        /// The context row: its line, the bar, the legend.
        static let usageContextRowHeight: CGFloat = 66
        /// This session, Today and This week.
        static let usageSessionRowHeight: CGFloat = 76
        /// What's using your limits: two lines.
        static let usageBehaviorsRowHeight: CGFloat = 44
        /// This session's four-part token bar.
        static let usageMiniBarHeight: CGFloat = 6
        /// Top and bottom padding inside the session and behaviour tiles, so their lines fit the fixed heights.
        static let usageCompactPadding: CGFloat = 6
        static let usageFootnoteHeight: CGFloat = 14
        /// Height of a tool's pane inside the well: the card minus the bridge row, the two
        /// gaps around the well, the footer, the bottom padding and the well's own padding.
        static func tabPaneHeight(cardHeight: CGFloat) -> CGFloat {
            cardHeight - bridgeHeight - 2 * spaceM - cardFooterHeight - sidePadding - 2 * wellPadding
        }
        /// The limit tiles: the pane minus the other rows and the four gaps.
        static var usageLimitsRowHeight: CGFloat {
            tabPaneHeight(cardHeight: usageCardHeight) - usageContextRowHeight - usageSessionRowHeight
                - usageBehaviorsRowHeight - usageFootnoteHeight - 4 * usageRowSpacing
        }

        // Hover rim light, the Motion board M7: the CSS `inset 0 -2px 0 0 white/50%` mirrored
        // outward (the shape shifted 2 pt down minus the shape: a 2 pt band under the flat
        // bottom edge that thins to nothing up each corner) and its `0 2px 12px white/12%`
        // glow behind the black. 2 px per pt.
        static let rimLine: CGFloat = 2
        /// The glow: the whole shape dropped 2 pt and blurred 6 pt (the board's 12 px blur).
        static let rimGlowDrop: CGFloat = 2
        static let rimGlowRadius: CGFloat = 6

        // Clay bleed below the attention shape. Wider than the whole shape so both wings
        // carry it, centred below the bottom edge so nothing relies on the camera area.
        static let bleedWidthFactor: CGFloat = 1.1
        static let bleedHeight: CGFloat = 44
        static let bleedBlur: CGFloat = 22
        /// How far below the shape's bottom edge the bleed's centre sits.
        static let bleedDrop: CGFloat = 6

        // Done peek check, drawn in a unit square inside the peek circle.
        static let checkLine: CGFloat = 1.8
        static let checkInset: CGFloat = 0.28

        // The five cells in a changed-file row.
        static let diffCellWidth: CGFloat = 4
        static let diffCellHeight: CGFloat = 7
        static let diffCellSpacing: CGFloat = 1
        /// Every list row (Sessions, request rows) pads by these.
        static let rowVPadding: CGFloat = 6
        static let rowHPadding: CGFloat = 8

        // Sessions tab: agent lanes under a session row.
        static let laneIndent: CGFloat = 22
        static let laneVPadding: CGFloat = 3
        static let laneLineWidth: CGFloat = 1
        /// Chevron plus its gap, so lane clocks line up with the row clock.
        static let chevronColumn: CGFloat = 14
        /// The teleport chevron's hit area height on a session row.
        static let chevronHitHeight: CGFloat = 34

        // Changes tool (Direction G, Timeline). Inside the well (576 × 334): the header row,
        // then the body; the timeline column takes the full width, or `changesColumnWidth`
        // beside the diff pane (gap, hairline, gap, the pane).
        /// The header row: the session's totals and the With edits pill.
        static let changesHeaderHeight: CGFloat = 26
        /// The spine's x inside the column; titles start at `changesTitleInset`.
        static let changesSpineX: CGFloat = 10
        static let changesTitleInset: CGFloat = 26
        /// A turn's node, the live node's halo, a quiet turn's tick (6 × 1).
        static let changesNode: CGFloat = 8
        static let changesHalo: CGFloat = 14
        static let changesTickWidth: CGFloat = 6
        static let changesTickHeight: CGFloat = 1
        /// The quiet group's three ticks, this far apart.
        static let changesTickGap: CGFloat = 3
        /// One timeline row: an entry's first line, a quiet row, a chip.
        static let changesRowHeight: CGFloat = 20
        /// Between entries, and between an entry's title and its chips.
        static let changesEntryGap: CGFloat = 12
        static let changesTitleGap: CGFloat = 4
        /// A file chip: 20 pt tall, 6 pt inside, 4 pt apart (both ways), the name at most 120 pt.
        static let changesChipHeight: CGFloat = 20
        static let changesChipHPadding: CGFloat = 6
        static let changesChipGap: CGFloat = 4
        static let changesChipMaxWidth: CGFloat = 120
        /// The fade that ends a cut title or prompt instead of an ellipsis.
        static let changesFadeWidth: CGFloat = 24
        /// The timeline column beside the diff pane, and the pane.
        static let changesColumnWidth: CGFloat = 236
        static let changesPaneWidth: CGFloat = 320
        /// Past this column width an entry shows its duration and a quiet group its
        /// "questions and decisions" tail.
        static let changesWideColumn: CGFloat = 300
        /// The live node's halo breathes out to this scale.
        static let changesHaloScale: CGFloat = 1.5
        /// The keyboard cursor's ring around a chip.
        static let changesRing: CGFloat = 1
        /// An entry's title sits this far down its 20 pt first row (13 pt body in 16 pt lines).
        static let changesTitleVPadding: CGFloat = 2

        // Settings page inside the card.
        static let settingsRowHeight: CGFloat = 28
        static let settingsGroupSpacing: CGFloat = 10
        static let settingsLabelSpacing: CGFloat = 4
        static let switchWidth: CGFloat = 28
        static let switchHeight: CGFloat = 16
        static let switchKnobInset: CGFloat = 2
        static let pickerHeight: CGFloat = 22
        static let pickerHPadding: CGFloat = 9
        static let pickerInset: CGFloat = 2
        static let stepperValueWidth: CGFloat = 36
        static let backPillHeight: CGFloat = 22
        static let backPillHPadding: CGFloat = 9

        // Subagent colour squares.
        static let agentSquare: CGFloat = 7
        static let agentSquareSpacing: CGFloat = 3

        // Diff view: a rounded box, two line-number columns (old, new), then the line.
        // Its font, padding and gutter are the Files preview's.
        static let diffLineHeight: CGFloat = 16
        static let diffMaxHeight: CGFloat = 220
        /// One line-number column, wide enough for four digits at the mono size.
        static let diffLineNumberWidth: CGFloat = 30
        /// The minimap down a diff pane's right edge: its width, its gap from the edge, the
        /// room the lines leave for it, the smallest mark and visible-range box.
        static let diffMinimapWidth: CGFloat = 6
        static let diffMinimapInset: CGFloat = 3
        static let diffMinimapReserve: CGFloat = 12
        static let diffMinimapMinMark: CGFloat = 2
        static let diffMinimapMinViewport: CGFloat = 8
        static let diffMinimapViewportOutset: CGFloat = 2
        static let diffMinimapRingLine: CGFloat = 1
        static let groupHeaderTopPadding: CGFloat = 6
        /// Inside a request card the diff takes what is left above the footer, up to this.
        static let requestDiffMaxHeight: CGFloat = 260
        /// ... and never less than this (a short diff is shorter still).
        static let requestDiffMinHeight: CGFloat = 72

        // Sessions tab: one slim sticky header per repository.
        static let repoHeaderHeight: CGFloat = 22

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
        // Markdown preview: padding inside the box, space between blocks, list and quote indents.
        static let markdownPadding: CGFloat = 10
        static let markdownBlockSpacing: CGFloat = 8
        static let markdownLineSpacing: CGFloat = 2
        static let markdownMarkerGap: CGFloat = 6
        static let markdownListIndent: CGFloat = 12
        static let markdownQuoteRule: CGFloat = 2
        static let markdownQuoteGap: CGFloat = 8
        static let markdownCodePadding: CGFloat = 8
        static let markdownCellHPadding: CGFloat = 6
        static let markdownCellVPadding: CGFloat = 3
        static let markdownHeadingTopSpacing: CGFloat = 4

        static let breatheRadius: CGFloat = 6
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
        /// The card's content well: white at this opacity over the black.
        static let well: Double = 0.045
        /// Finished agents keep their colour, dimmed.
        static let agentFinished: Double = 0.45
        /// An unchecked Git file's cells.
        static let gitUncheckedCells: Double = disabled
        /// The commit form's fields while git commits.
        static let gitLocked: Double = 0.6
    }

    // MARK: - Motion

    enum Motion {
        @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        static let reduced = Animation.easeInOut(duration: 0.2)

        // The shape settles without a visible overshoot: every shape spring is damped
        // high (owner, 2026-09-27: the old open bounced once the card got wider and
        // taller). Closing uses the same curves, `closeShare` of the response.
        static let widthResponse: Double = 0.42
        static let heightResponse: Double = 0.48
        static let shapeDamping: Double = 0.9
        static let retargetResponse: Double = 0.4
        static let retargetDamping: Double = 0.94
        /// Closing runs this share of the opening response (30% faster).
        static let closeShare: Double = 0.7
        /// Opening: width leads.
        @MainActor static var width: Animation { reduceMotion ? reduced : .spring(response: widthResponse, dampingFraction: shapeDamping) }
        /// Opening: height follows.
        @MainActor static var height: Animation { reduceMotion ? reduced : .spring(response: heightResponse, dampingFraction: shapeDamping) }
        /// Closing runs backwards, faster.
        @MainActor static var closeWidth: Animation { reduceMotion ? reduced : .spring(response: widthResponse * closeShare, dampingFraction: shapeDamping) }
        @MainActor static var closeHeight: Animation { reduceMotion ? reduced : .spring(response: heightResponse * closeShare, dampingFraction: shapeDamping) }
        /// Same state, new size (another tool, a request's diff): one spring, no axis sequencing.
        @MainActor static var panelRetarget: Animation { reduceMotion ? reduced : .spring(response: retargetResponse, dampingFraction: retargetDamping) }
        /// Gap between the leading axis and the following axis.
        static let axisDelay: Double = 0.06

        static let contentFadeDelay: Double = 0.12
        static let contentFadeDuration: Double = 0.2
        static let contentOutDuration: Double = 0.08
        /// Content fades in and rises this far; no blur anywhere.
        static let contentRise: CGFloat = 10
        /// Card rows follow each other by this much.
        static let rowStagger: Double = 0.04
        /// Rows past this index share its delay, so a long list lands within half a second.
        static let rowStaggerCap = 8
        static var contentIn: Animation { .easeOut(duration: contentFadeDuration).delay(contentFadeDelay) }
        static var contentOut: Animation { .easeIn(duration: contentOutDuration) }
        static func rowIn(_ index: Int) -> Animation {
            .easeOut(duration: contentFadeDuration).delay(contentFadeDelay + rowStagger * Double(index))
        }
        /// Opacity plus a rise of `dy` coming in (opacity only for `dy == 0` or under Reduce
        /// Motion), opacity going out. The one shape every content transition takes.
        @MainActor static func rise(dy: CGFloat, in inAnimation: Animation, out outAnimation: Animation) -> AnyTransition {
            let insertion: AnyTransition = (dy != 0 && !reduceMotion)
                ? AnyTransition.opacity.combined(with: .offset(y: dy))
                : AnyTransition.opacity
            return .asymmetric(
                insertion: insertion.animation(inAnimation),
                removal: AnyTransition.opacity.animation(outAnimation)
            )
        }
        /// Opacity plus a slide of `dx` on both sides, in and out (opacity only for `dx == 0` or
        /// under Reduce Motion). `rise`'s sibling on the x axis.
        @MainActor static func slide(dx: CGFloat, in inAnimation: Animation, out outAnimation: Animation) -> AnyTransition {
            guard dx != 0 && !reduceMotion else { return rise(dy: 0, in: inAnimation, out: outAnimation) }
            let moved = AnyTransition.opacity.combined(with: .offset(x: dx))
            return .asymmetric(insertion: moved.animation(inAnimation), removal: moved.animation(outAnimation))
        }
        /// Content in: opacity plus the rise. `rise: false` for content whose rows rise on
        /// their own (the card).
        @MainActor static func contentTransition(rise: Bool) -> AnyTransition {
            self.rise(dy: rise ? contentRise : 0, in: contentIn, out: contentOut)
        }

        // The strip unfolds from behind the camera: each segment starts `unfoldDistance`
        // toward the centre and transparent, then glides out (critically damped, no
        // overshoot), `unfoldStagger` after the one nearer the camera.
        static let unfoldDistance: CGFloat = 16
        static let unfoldStagger: Double = 0.03
        static let unfoldDuration: Double = 0.28
        static let unfoldDelay: Double = 0.10
        @MainActor static func unfold(_ index: Int) -> Animation {
            reduceMotion
                ? reduced.delay(unfoldDelay)
                : .spring(response: unfoldDuration, dampingFraction: 1).delay(unfoldDelay + unfoldStagger * Double(index))
        }

        // Segments: hover lift, press depress, selection glide.
        static let hoverLift: Animation = .easeOut(duration: 0.15)
        static let pressDuration: Double = 0.12
        static let pressScale: CGFloat = 0.94
        static var press: Animation { .easeOut(duration: pressDuration) }
        @MainActor static var toolSelect: Animation { reduceMotion ? reduced : .spring(response: 0.3, dampingFraction: 0.88) }
        /// Allow pops in (start → overshoot → 1) when it arrives, after the unfold delay.
        static let actionPopStart: CGFloat = 0.92
        static let actionPopOvershoot: CGFloat = 1.08
        static let actionPopDuration: Double = 0.34
        /// Share of the pop spent rising to the overshoot.
        static let actionPopRiseShare: Double = 0.55
        static var actionPopRise: Animation {
            .easeOut(duration: actionPopDuration * actionPopRiseShare).delay(unfoldDelay)
        }
        static var actionPopSettle: Animation {
            .spring(response: actionPopDuration * (1 - actionPopRiseShare), dampingFraction: 0.8)
        }


        // Tool name caption: shows after the mouse rests this long on a tool, follows it to
        // the next tool at once, lingers briefly on leaving (so the gap between tools does
        // not blink it), and holds this long after ⇥ or 1–4.
        static let toolLabelDelay: Double = 0.15
        static let toolLabelLinger: Double = 0.08
        static let toolLabelKeyboardHold: Double = 1.2
        static let toolLabelFadeDuration: Double = 0.12
        /// Reduce Motion: nil, the caption appears and moves without a fade or glide.
        @MainActor static var toolLabelFade: Animation? { reduceMotion ? nil : .easeOut(duration: toolLabelFadeDuration) }

        // Hover: the rim light, the resting name brightening, and the collapsed strip's
        // tools crossfading in all use one pair. The rim waits `rimDelay` first.
        static let rimDelay: Double = 0.25
        static var hoverIn: Animation { .easeOut(duration: 0.18) }
        static var hoverOut: Animation { .easeIn(duration: 0.25) }

        // Attention arrival: the clay bleed (no breath: the shape growing is the signal).
        static let bleedInDuration: Double = 0.3
        /// The bleed has settled to its resting opacity by this long after arrival.
        static let bleedSettledAt: Double = 1
        static var bleedIn: Animation { .easeOut(duration: bleedInDuration) }
        static var bleedSettle: Animation { .easeInOut(duration: bleedSettledAt - bleedInDuration) }

        // Tabs.
        static let tabInDuration: Double = 0.32
        static let tabOutDuration: Double = 0.2
        static var tabIn: Animation { .easeOut(duration: tabInDuration) }
        static var tabOut: Animation { .easeOut(duration: tabOutDuration) }
        /// Inset groups inside a sliding pane move by this share of the pane's offset, on top of it.
        static let tabParallax: CGFloat = 0.4
        /// The pane slides this far toward its new anchor, not the whole width: it re-anchors, it does not page.
        static let paneSlide: CGFloat = 48
        /// A pane sliding by `dx` while it fades, its inset groups a little further (parallax).
        static func slide(_ dx: CGFloat) -> AnyTransition {
            AnyTransition.offset(x: dx)
                .combined(with: .opacity)
                .combined(with: .modifier(active: PaneParallax(offset: dx), identity: PaneParallax(offset: 0)))
        }
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
        static var checkPopRise: Animation { .easeOut(duration: checkPopDuration * checkPopRiseShare) }
        static var checkPopSettle: Animation {
            .spring(response: checkPopDuration * (1 - checkPopRiseShare), dampingFraction: 0.8)
        }
        static var checkDraw: Animation { .easeOut(duration: checkDrawDuration).delay(checkDelay) }
        static var countUp: Animation { .easeOut(duration: countDuration).delay(countDelay) }

        // Teleport fold: height collapses, then the width settles; the terminal comes up part way.
        static let foldHeightDuration: Double = 0.28
        static var foldHeight: Animation { .easeIn(duration: foldHeightDuration) }
        static var foldWidth: Animation { .spring(response: 0.3, dampingFraction: 0.6).delay(foldHeightDuration) }
        static let teleportActivateAt: Double = 0.15
        /// The fold flag clears after this long.
        static let foldTotal: Double = 0.9

        static let tap = Animation.easeOut(duration: 0.12)

        // A request card's diff: the card grows with the same springs as the shape
        // (height follows after the axis delay), and the diff rises in.
        @MainActor static func requestDiff(expanding: Bool) -> Animation {
            expanding ? height.delay(axisDelay) : closeHeight
        }
        static let requestDiffRevealDuration: Double = 0.2
        /// Opacity plus the content rise; Reduce Motion crossfades.
        @MainActor static var requestDiffTransition: AnyTransition {
            rise(dy: contentRise, in: .easeOut(duration: requestDiffRevealDuration), out: contentOut)
        }

        // Git branch picker: the target pill morphs into the repository pill in place, the
        // rest of the header slides right, the panes drop away, the picker's header rises and
        // its rows rise one by one (`RiseIn`, capped). Closing is a plain fade and the reverse.
        static let pickerPillResponse: Double = 0.32
        static let pickerPillDamping: Double = 0.86
        /// The pill's frame and crossfade.
        @MainActor static var pickerPill: Animation {
            reduceMotion ? reduced : .spring(response: pickerPillResponse, dampingFraction: pickerPillDamping)
        }
        /// The picker and the content trading places.
        @MainActor static var pickerSwap: Animation { pickerPill }
        /// The branch, status and Push slide this far right on the way out and back from there.
        static let pickerHeaderShift: CGFloat = 12
        /// The list and diff drop this far as they fade.
        static let pickerPaneDrop: CGFloat = 6
        @MainActor static var pickerHeaderTransition: AnyTransition {
            reduceMotion
                ? rise(dy: 0, in: reduced, out: reduced)
                : slide(dx: pickerHeaderShift, in: contentIn, out: contentOut)
        }
        /// The panes: out with a drop, back with the content rise.
        @MainActor static var pickerPanesTransition: AnyTransition { paneSwapTransition }
        /// Content trading places in a pane: out with a 6 pt drop and a 0.08 s fade, in with
        /// the content rise at 120 ms. The picker's panes, the Git diff pane's content and its
        /// push confirm. Reduce Motion: a 0.2 s crossfade.
        @MainActor static var paneSwapTransition: AnyTransition {
            if reduceMotion { return rise(dy: 0, in: reduced, out: reduced) }
            return .asymmetric(
                insertion: AnyTransition.opacity.combined(with: .offset(y: contentRise)).animation(contentIn),
                removal: AnyTransition.opacity.combined(with: .offset(y: pickerPaneDrop)).animation(contentOut)
            )
        }
        /// The picker's header and filter: the content rise in, a fade out.
        @MainActor static var pickerHeadTransition: AnyTransition {
            reduceMotion ? rise(dy: 0, in: reduced, out: reduced) : contentTransition(rise: true)
        }
        // Git stage (Direction F): the stage swaps between the diff, the commit form and the
        // confirm, its content dropping away and the next rising in (`paneSwapTransition`),
        // while the dock's summary box travels from the rail's foot to the top of the form
        // (`matchedGeometryEffect`). The sync pill stays in the header for the confirm. Swap
        // and travel run together on the picker pill's spring.
        @MainActor static var stageSwap: Animation { pickerPill }
        /// The dock's field travelling into the stage and back: the same spring as every
        /// stage swap, so the box and the content it replaces arrive together.
        @MainActor static var dockTravel: Animation { stageSwap }
        /// What travels (the dock's box), both ends: the arriving copy is
        /// whole from the first frame, the departing one gone within `travelDepartShare` of
        /// the spring (about 50 ms), so one box glides. Never `.identity`: that removes the
        /// departing copy at once and the box jumps.
        static let travelDepartShare: Double = 0.25
        @MainActor static var travelTransition: AnyTransition {
            .asymmetric(
                insertion: .modifier(active: TravelFade(progress: 0, share: 0), identity: TravelFade(progress: 1, share: 0)),
                removal: .modifier(active: TravelFade(progress: 0, share: travelDepartShare), identity: TravelFade(progress: 1, share: travelDepartShare))
            )
        }
        /// P: the question rises in once the diff has dropped away, the "⏎ or Push again" hint
        /// and Cancel after it, while the header's pill pops in place.
        static let confirmQuestionDelay: Double = 0.12
        static let confirmCancelDelay: Double = 0.18
        @MainActor static func confirmRise(delay: Double) -> AnyTransition {
            if reduceMotion { return rise(dy: 0, in: reduced, out: reduced) }
            return .asymmetric(
                insertion: AnyTransition.opacity.combined(with: .offset(y: contentRise))
                    .animation(.easeOut(duration: contentFadeDuration).delay(delay)),
                removal: AnyTransition.opacity.combined(with: .offset(y: pickerPaneDrop)).animation(contentOut)
            )
        }
        /// The form's parts wait for the summary box to land (its spring is about 0.32 s): the
        /// description (`index` 0), the co-author row (1), the bottom row (2), then rise.
        static let stageRiseDelays: [Double] = [0.18, 0.22, 0.26]
        /// The form's parts after the summary box, on `stageRiseDelays`; out at once with the
        /// pane swap's drop, so esc feels instant.
        @MainActor static func stageRise(_ index: Int) -> AnyTransition {
            if reduceMotion { return rise(dy: 0, in: reduced, out: reduced) }
            let delay = stageRiseDelays[min(max(index, 0), stageRiseDelays.count - 1)]
            return .asymmetric(
                insertion: AnyTransition.opacity.combined(with: .offset(y: contentRise))
                    .animation(.easeOut(duration: contentFadeDuration).delay(delay)),
                removal: AnyTransition.opacity.combined(with: .offset(y: pickerPaneDrop)).animation(contentOut)
            )
        }
        /// A rail row leaving (a commit took it) or coming back (an undo): its 20 pt height
        /// to 0 and a fade on the picker pill's spring, 40 ms apart, capped at 8; leaving top
        /// down (`outIndex`), coming back bottom up (`inIndex`).
        @MainActor static func railRowCollapse(outIndex: Int, inIndex: Int) -> AnyTransition {
            let collapsed = AnyTransition.modifier(active: RowCollapse(fraction: 0), identity: RowCollapse(fraction: 1))
            if reduceMotion { return collapsed.animation(reduced) }
            func staggered(_ index: Int) -> Animation {
                pickerPill.delay(rowStagger * Double(min(index, rowStaggerCap)))
            }
            return .asymmetric(insertion: collapsed.animation(staggered(inIndex)), removal: collapsed.animation(staggered(outIndex)))
        }
        /// The rows closing the gap a leaving row left.
        @MainActor static var railRows: Animation { pickerPill }
        /// ⌘B: the rail springs between its width and the checkbox column; names and cells fade.
        @MainActor static var railFold: Animation { pickerPill }
        static let railFadeDuration: Double = 0.08
        @MainActor static var railFade: Animation { reduceMotion ? reduced : .easeOut(duration: railFadeDuration) }
        /// A checkbox ticking: the check draws itself as a stroke.
        static let checkStrokeDuration: Double = 0.09
        @MainActor static var checkStroke: Animation { reduceMotion ? reduced : .easeOut(duration: checkStrokeDuration) }
        /// Unticking: the box's fill shrinks to `Size.gitUntickScale` and fades.
        static let checkUntickDuration: Double = 0.08
        @MainActor static var checkUntick: Animation { reduceMotion ? reduced : .easeIn(duration: checkUntickDuration) }
        /// The row's name and cells dimming or coming back as its box changes.
        static let checkDimDuration: Double = 0.12
        @MainActor static var checkDim: Animation { reduceMotion ? reduced : .easeInOut(duration: checkDimDuration) }
        /// The header's box ticks every row, this far apart top down, capped at `rowStaggerCap`.
        static let checkStagger: Double = 0.02
        /// How long a header tick keeps the rows staggered.
        static let checkStaggerWindow: Double = 0.3
        /// One horizontal shake (a failed sync's pill, an invalid co-author): ±3 pt, two
        /// half-cycles of 60 ms. Reduce Motion: none.
        static let pillShakeDistance: CGFloat = 3
        static let pillShakeHalf: Double = 0.06
        static var pillShake: Animation { .easeInOut(duration: pillShakeHalf) }
        /// A count changing (the rail header's, the sync pill's): the digits roll
        /// (`.numericText()`) and the pill pops (`PopIn`'s curve, without its delay).
        @MainActor static var countPop: Animation { reduceMotion ? reduced : .spring(response: pickerPillResponse, dampingFraction: pickerPillDamping) }
        @MainActor static var countPopRise: Animation { reduceMotion ? reduced : .easeOut(duration: actionPopDuration * actionPopRiseShare) }
        /// The rows' block: nothing coming in (each row rises on its own), a fade going out.
        @MainActor static var pickerRowsTransition: AnyTransition {
            .asymmetric(insertion: .identity, removal: AnyTransition.opacity.animation(reduceMotion ? reduced : contentOut))
        }

        // Files tab.
        /// Folder disclosure: the chevron turns and the children rise in, one `rowStagger` apart.
        static let disclosureDuration: Double = 0.2
        /// Reduce Motion: the chevron snaps (the rows still crossfade).
        @MainActor static var disclosure: Animation? { reduceMotion ? nil : .easeOut(duration: disclosureDuration) }
        @MainActor static func childIn(_ index: Int) -> Animation {
            let stagger = rowStagger * Double(min(index, Theme.Limits.maxStaggeredChildren))
            return reduceMotion ? reduced : .easeOut(duration: disclosureDuration).delay(stagger)
        }
        /// Tree rows entering or leaving: opacity plus the content rise, downward from their
        /// folder (opacity only under Reduce Motion).
        @MainActor static func childTransition(_ index: Int) -> AnyTransition {
            rise(dy: -contentRise, in: childIn(index), out: .easeOut(duration: disclosureDuration))
        }
        /// The preview pane crossfades between files.
        static let previewFadeDuration: Double = 0.2
        static var previewFade: Animation { .easeInOut(duration: previewFadeDuration) }
        /// Rows leaving and joining as the filter changes.
        @MainActor static var filterRows: Animation { reduceMotion ? reduced : .easeOut(duration: disclosureDuration) }
        static let chevronOpenDegrees: Double = 90
        // Changes tool (Direction G, Timeline).
        /// The live node's halo: scale 1 → `Size.changesHaloScale`, opacity to 0, 1.6 s,
        /// repeating. Reduce Motion: nil, a static halo.
        static let changesBreathDuration: Double = 1.6
        @MainActor static var changesBreath: Animation? {
            reduceMotion ? nil : .easeInOut(duration: changesBreathDuration).repeatForever(autoreverses: false)
        }
        /// The column's width (the pane opening, esc, ⌘B), entries sliding to make room or
        /// close a gap, the cursor ring gliding between chips: the picker pill's spring.
        @MainActor static var changesLayout: Animation { pickerPill }
        /// A timeline row (an entry, a quiet group, an unfolded quiet turn) coming or going:
        /// in with the content rise, out with the pane swap's drop, `index` × 40 ms apart
        /// (capped at 8). Reduce Motion: a crossfade.
        @MainActor static func changesRowTransition(_ index: Int) -> AnyTransition {
            if reduceMotion { return rise(dy: 0, in: reduced, out: reduced) }
            let stagger = rowStagger * Double(min(index, rowStaggerCap))
            return .asymmetric(
                insertion: AnyTransition.opacity.combined(with: .offset(y: contentRise))
                    .animation(.easeOut(duration: contentFadeDuration).delay(stagger)),
                removal: AnyTransition.opacity.combined(with: .offset(y: pickerPaneDrop))
                    .animation(contentOut.delay(stagger))
            )
        }
        /// A chip landing in a turn: from `actionPopStart` and transparent, on the count pop's spring.
        @MainActor static var changesChipTransition: AnyTransition {
            if reduceMotion { return AnyTransition.opacity.animation(reduced) }
            return AnyTransition.scale(scale: actionPopStart).combined(with: .opacity).animation(countPop)
        }
        /// The diff pane: its header rises at `contentFadeDelay`, the diff one `rowStagger`
        /// later (`RiseIn` 0 and 1); esc drops it 6 pt and fades it in 0.08 s.
        @MainActor static var changesPaneTransition: AnyTransition {
            if reduceMotion { return AnyTransition.opacity.animation(reduced) }
            return .asymmetric(
                insertion: .identity,
                removal: AnyTransition.opacity.combined(with: .offset(y: pickerPaneDrop)).animation(contentOut)
            )
        }
        /// A chip's hover fill, and the cursor turning from a chip's ring to a row's fill.
        static let changesHoverDuration: Double = 0.12
        @MainActor static var changesHover: Animation { reduceMotion ? reduced : .easeOut(duration: changesHoverDuration) }

        /// ⌘B: the tree folds away or comes back with the same spring as a same-state resize.
        @MainActor static var treeCollapse: Animation { panelRetarget }
        static let ringStartDegrees: Double = -90




        static let pulseDuration: Double = 1.4
        static let pulseScale: CGFloat = 1.9
        static let pulseStartScale: CGFloat = 1.0
        static var pulse: Animation { .easeOut(duration: pulseDuration).repeatForever(autoreverses: false) }

        static let breatheDuration: Double = 1.6
        static var breathe: Animation { .easeInOut(duration: breatheDuration).repeatForever(autoreverses: true) }

    }


    // MARK: - Timing (product timeouts and windows, not animation)

    enum Timing {
        /// A blocking request waits this long; the socket replies "none" at the same moment.
        static let permissionDeadline: Double = 58
        /// A plan waits this long (reading takes longer); the hook waits 299 s, its entry's timeout is 305 s.
        static let planDeadline: Double = 298
        /// The deadline of a blocking request: a plan's, or every other request's.
        static func replyDeadline(plan: Bool) -> Double { plan ? planDeadline : permissionDeadline }
        /// After a new request arrives, ⏎ / ⌫ / A / E are ignored this long (typing in the
        /// terminal must not answer it). Clicks are never delayed.
        static let requestKeyGuard: Double = 0.4
        /// A session that got a hook envelope this recently is driven by hooks; the transcript
        /// watcher does not override its state.
        static let hookDrivenWindow: Double = 10 * 60
        /// Sessions with no activity for this long leave the list.
        static let sessionIdleCutoff: Double = 2 * 3600
        /// A session counts as live (keeps the wings up) when active this recently.
        static let liveSessionWindow: Double = 10 * 60
        /// A hook agent and a transcript agent of the same type starting this close together are the same agent.
        static let agentMatchWindow: Double = 15
        /// `.needsYou` without a pending request lasts at most this long.
        static let needsYouLifetime: Double = 90
        /// Transcript writes this soon after a needs-you notification belong to it, not to new activity.
        static let needsYouActivityGrace: Double = 2
        /// Limits reported this recently read "updated 3m ago"; older ones "as of 2:14 PM".
        static let limitsRelativeWindow: Double = 3600
        /// The Usage footer's "updated 3m ago" refreshes this often.
        static let limitsFootnoteTick: Double = 30
        /// A reset closer than this reads "resets in 1h 52m"; further out, "resets Thu 3:40 PM".
        static let resetRelativeWindow: Double = 24 * 3600
        /// A transcript turn that started this long before the hook's prompt still counts as that turn.
        static let turnMatchSlack: Double = 5
        /// Default peek length; the owner sets the real one in Settings.
        static let peekLifetime: Double = 4
        static let peekSecondsRange: ClosedRange<Double> = 2...8
        static let peekSecondsStep: Double = 1
        /// Inline hints ("No terminal found", "Copied") show this long.
        static let hintDuration: Double = 2
        /// Hover to open: rest this long on the shape to open, leave the card this long to close.
        static let hoverOpenDelay: Double = 0.25
        static let hoverCloseDelay: Double = 0.40
        /// Clocks and countdowns (and every Reduce Motion countdown) step this often.
        static let clockTick: Double = 1
        /// The Git tool re-reads the worktree this often while it shows.
        static let gitRefreshInterval: Double = 5
        /// "Pushed 3 commits", "Committed 3 files" stay this long, then the tool re-reads.
        static let gitResultHold: Double = 3
        /// A read command (status, diff, log), a push or pull, a fetch, or a commit (its hooks
        /// may run) is stopped after this long.
        static let gitReadTimeout: Double = 10
        static let gitSyncTimeout: Double = 90
        static let gitFetchTimeout: Double = 30
        static let gitCommitTimeout: Double = 60
        /// The tool fetches the target's remote quietly when it opens, at most this often.
        static let gitAutoFetchInterval: Double = 300
        /// After a timed-out process (git, claude) is sent SIGTERM, this long before SIGKILL.
        static let processKillGrace: Double = 2
        /// Plan usage (`claude -p /usage`) runs this often while Settings allows it.
        static let planUsageInterval: Double = 900
        /// Plan usage younger than this is not refreshed unless forced (R).
        static let planUsageStaleAfter: Double = 300
        /// A `claude -p /usage` run is stopped after this long.
        static let planUsageTimeout: Double = 20
        /// The first plan usage run waits this long after launch.
        static let planUsageLaunchDelay: Double = 5
        /// Asking the login shell where `claude` is gives up after this long.
        static let claudeLookupTimeout: Double = 5
        /// Shell changes kept on disk per session (they survive a relaunch) are dropped after this long unused.
        static let shellChangesKeep: Double = 7 * 24 * 3600
    }

    // MARK: - Limits (counts)

    enum Limits {
        /// Diff lines kept per file (FileChange.patch), from transcripts, hooks and git alike.
        static let patchLines: Int = 400
        /// The commit card lists at most this many files, then "N more".
        static let commitMaxFileRows: Int = 5
        /// The permission card lists at most this many of the rules Always would add, then "+N more".
        static let alwaysRuleLines: Int = 3
        /// File previews kept in memory for flipping back and forth.
        static let maxCachedPreviews: Int = 8
        /// A snippet shorter than this opens inline by default.
        static let inlineSnippetMaxLines: Int = 8
        static let diffCellCount: Int = 5
        /// ↑↓ move a request card's diff by this many lines.
        static let requestDiffScrollLines: Int = 4
        /// A plan card renders at most this many lines of the plan, then "… N more lines".
        static let planMaxLines: Int = 600
        /// ↑↓ move a plan card's Markdown by this many blocks.
        static let planScrollBlocks: Int = 2
        /// A plan read from its file (`planFilePath`) when the hook sent no text.
        static let planFileBytes: Int = 1024 * 1024
        static let maxQuestionOptions: Int = 3
        /// Children beyond this index rise in together, so a big folder never trickles in.
        static let maxStaggeredChildren: Int = 12
        static let maxStatusAgents: Int = 3
        /// The Git tool: commits read per snapshot (only the newest is used: undo and the dock's
        /// receipt need its sha and whether it is pushed), untracked files diffed, bytes read per command.
        static let gitRecentCommits: Int = 1
        static let gitUntrackedDiffs: Int = 20
        static let gitOutputBytes: Int = 2_000_000
        /// The branch picker lists this many local branches, newest commit first (and every
        /// checked-out one besides); its filter field appears past this many rows.
        static let gitPickerBranches: Int = 30
        static let gitPickerFilterMin: Int = 8
        /// Files whose length is counted for the minimap, per read.
        static let gitLineCountFiles: Int = 60
        /// The commit summary shows its length past the first and turns red past the second.
        static let gitSummaryIdeal: Int = 50
        static let gitSummaryMax: Int = 72
        /// "Undid "…"" keeps this many characters of the subject.
        static let gitUndoSubject: Int = 40
        /// A commit hook's line in "A commit hook said no · …" keeps this many characters.
        static let gitHookLine: Int = 80
        /// Co-author suggestions: the "recent" row shows this many, from this many distinct
        /// names found in the trailers of the last `gitCoauthorLog` commits.
        static let gitCoauthorSuggestions: Int = 6
        static let gitCoauthorHistory: Int = 12
        static let gitCoauthorLog: Int = 100
        /// The Git footer adds "⇥ next tool" only while it has at most this many hints.
        static let gitFooterHints: Int = 5
        /// Word highlights skip a line pair with more tokens than this on either side.
        static let wordDiffMaxTokens: Int = 200
        /// The Changes pane counts a file's lines on disk (for the minimap) up to this size.
        static let changesLineCountBytes: Int = 4 * 1024 * 1024
        /// A limit bar turns clay at this percent.
        static let limitWarnPercent: Double = 90
        /// The plan usage run's transcript starts over (a new session id) past this size.
        static let planUsageTranscriptBytes: Int = 1_000_000
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
        static let treeChevronSize: CGFloat = 8
        static let toolBadgeSize: CGFloat = 8.5
        static let actionSize: CGFloat = 12

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
        /// One character of `monoSmall`, for the width of a line that never wraps.
        static let monoSmallAdvance: CGFloat = ("0" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: monoSmallSize, weight: .regular),
        ]).width

        static let tiny = Font.system(size: tinySize).monospacedDigit()

        static let keycap = Font.system(size: keycapSize, weight: .medium).monospacedDigit()
        static let chevron = Font.system(size: chevronSize, weight: .semibold)
        static let treeChevron = Font.system(size: treeChevronSize, weight: .semibold)
        static let badge = Font.system(size: tinySize, design: .monospaced)
        static let groupHeader = Font.system(size: captionSize, weight: .semibold).monospacedDigit()
        static let toolBadge = Font.system(size: toolBadgeSize, weight: .semibold).monospacedDigit()
        static let action = Font.system(size: actionSize, weight: .semibold).monospacedDigit()
        static let toolLabel = Font.system(size: tinySize, weight: .medium)

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
        static let diff = "plusminus"
        static let back = "chevron.left"
        static let filter = "line.3.horizontal.decrease"
        /// The Files tool's collapse-the-tree pill.
        static let sidebar = "sidebar.left"

        // The Git tool (the strip's own icons are drawn: ToolShapes in Glyphs.swift).
        /// Before "worktree seadevil" on a branch picker row.
        static let gitWorktree = "macwindow"
        /// The dock's field, before the summary or its prompt.
        static let gitPen = "pencil.line"
    }

    // MARK: - Key labels for keycaps

    enum Keys {
        static let enter = "⏎"
        static let delete = "⌫"
        static let option = "⌥"
        static let space = "space"
        static let tab = "⇥"
        static let escape = "esc"
        static let always = "A"
        static let edit = "E"
        static let settings = "⌘,"
        static let quit = "⌘Q"
        static let copy = "Y"
        static let diff = "D"
        static let optionEnter = "⌥⏎"
        static let up = "↑"
        static let down = "↓"
        static let left = "←"
        static let right = "→"
        static let slash = "/"
        static let plus = "+"
        /// Files: collapse or bring back the tree.
        static let toggleTree = "⌘B"
        /// Files: a Markdown file's Preview · Code switch.
        static let markdownMode = "P"
        /// Git: the sync pill (publish, pull, push, fetch); the first three ask first.
        static let push = "P"
        /// Git: open the commit form.
        static let commit = "C"
        /// Git: undo the newest unpushed commit.
        static let undo = "U"
        /// Git: put the cursor's file in or out of the commit.
        static let toggle = space
        /// Git: commit from the description.
        static let commandEnter = "⌘⏎"
        /// Git: the commit form's co-author pill (a label, no key).
        static let coauthor = "@"
        /// Git: the branch picker.
        static let worktree = "W"
        /// Git: the picker's repository dropdown.
        static let repository = "R"
        /// Usage: run `claude -p /usage` now.
        static let refresh = "R"
    }

    // MARK: - Glyph characters used in text

    enum Glyphs {
        static let minus = "\u{2212}"
        static let separator = " · "
        static let approx = "\u{2248} "
        static let ellipsis = "\u{2026}"
        /// After the Git tool's pills: "notchcode › seadevil ▾".
        static let pickerChevron = "\u{25BE}"
        /// Between the repository and the place in the Git target pill.
        static let pathChevron = "\u{203A}"
        /// "↑3", "↑2 of main": commits ahead.
        static let ahead = "\u{2191}"
        // A diff line's prefix.
        static let diffAdded = "+"
        static let diffRemoved = minus
        static let diffContext = " "
        /// "~$1.42": an estimated cost.
        static let estimate = "~"
        static let emDash = "\u{2014}"
        /// A Markdown bullet list item's marker.
        static let bullet = "\u{2022}"
        /// After a Changes file row's name when a Bash command changed the file.
        static let shellTag = "shell"
        /// Removes a Git co-author chip.
        static let remove = "\u{00D7}"
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
