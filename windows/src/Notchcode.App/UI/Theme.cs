// Theme.cs
// Every colour, radius, size, spring, duration, font, glyph and key label the
// app draws with. Views never use literal colours or numbers; they read them here.
// Ported member for member from Sources/notchcode/UI/Theme.swift (same names in
// PascalCase, same values, same comments). Sizes are device-independent pixels, 1:1 with
// the macOS points. Numbers are `const` so a size may name one declared further down
// (gitRailHeaderHeight = treeRowHeight) without reading it as 0.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Notchcode.Core;

namespace Notchcode.UI;

public static partial class Theme
{
    /// sRGB colour from a 0xRRGGBB literal. Used only inside Theme.
    public static Color Hex(uint hex, double opacity = 1) => Color.FromArgb(
        (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255),
        (byte)((hex >> 16) & 0xFF),
        (byte)((hex >> 8) & 0xFF),
        (byte)(hex & 0xFF));

    /// SwiftUI's `.opacity(x)` on a colour: its alpha multiplied by `opacity`.
    public static Color WithOpacity(this Color color, double opacity) =>
        Color.FromArgb((byte)Math.Round(color.A * Math.Clamp(opacity, 0, 1)), color.R, color.G, color.B);

    /// A frozen brush of `color`.
    public static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    // MARK: - Colours

    public static partial class Colors
    {
        /// The notch itself. Pure black so the closed state matches the hardware.
        public static readonly Color Notch = Hex(0x000000);

        // Base colours. Everything below is one of these, or one of these at an opacity.
        public static readonly Color Ink = Hex(0xFFFFFF);
        public static readonly Color Clay = Hex(0xD97757);
        public static readonly Color Green = Hex(0x30D158);
        public static readonly Color Red = Hex(0xFF6961);
        public static readonly Color Blue = Hex(0x64B5FF);
        public static readonly Color Purple = Hex(0xC77DFF);
        public static readonly Color Yellow = Hex(0xFFD60A);
        public static readonly Color Cyan = Hex(0x5AC8FA);

        public static readonly Color InkSecondary = Ink.WithOpacity(0.62);
        public static readonly Color InkTertiary = Ink.WithOpacity(0.42);
        public static readonly Color Inset = Ink.WithOpacity(0.07);
        public static readonly Color Hairline = Ink.WithOpacity(0.10);
        public static readonly Color Track = Ink.WithOpacity(0.12);
        /// The quiet white fill shared by keycaps, neutral actions and the selected row.
        public static readonly Color QuietFill = Ink.WithOpacity(0.10);
        public static readonly Color Selection = QuietFill;
        public static readonly Color KeycapFill = QuietFill;
        public static readonly Color KeycapFillOnLight = Hex(0x000000).WithOpacity(0.10);
        public static readonly Color KeycapTextOnLight = Hex(0x000000).WithOpacity(0.62);
        public static readonly Color CellEmpty = Ink.WithOpacity(0.14);

        // The toolbar strip (the open card, and the collapsed strip on hover).
        /// A tool segment at rest draws nothing; hover lifts it, selection fills it.
        public static readonly Color SegmentHover = Ink.WithOpacity(0.09);
        public static readonly Color SegmentPressed = Ink.WithOpacity(0.05);
        public static readonly Color ToolSelected = Ink.WithOpacity(0.16);
        public static readonly Color SegmentIcon = Ink.WithOpacity(0.66);
        public static readonly Color SegmentIconSelected = Ink;
        /// Keyboard focus ring that rides the selected tool while the card has the keys.
        public static readonly Color ToolFocusRing = Ink.WithOpacity(0.38);
        /// The short bar under the selected tool where the well hangs from the strip.
        public static readonly Color Bridge = Ink.WithOpacity(0.30);
        /// Hairline between the strip and the well.
        public static readonly Color StripDivider = Ink.WithOpacity(0.09);
        /// The thin vertical rule between the four tools and the gear.
        public static readonly Color ToolGroupRule = Ink.WithOpacity(0.14);
        /// Small numeric badge on the Sessions tool.
        public static readonly Color ToolBadgeFill = Ink.WithOpacity(0.14);
        public static readonly Color ToolBadgeText = Ink.WithOpacity(0.8);
        /// The card's content well: a lighter inset under the strip.
        public static readonly Color Well = Ink.WithOpacity(Opacity.Well);
        public static readonly Color WellStroke = Ink.WithOpacity(0.06);
        /// The tool name caption under the strip: an opaque dark pill so it reads over the well.
        public static readonly Color ToolLabelFill = Hex(0x262626);
        public static readonly Color ToolLabelStroke = Ink.WithOpacity(0.10);
        public static readonly Color ToolLabelText = InkSecondary;

        /// Primary action: white fill, black text.
        public static readonly Color PrimaryFill = Hex(0xFFFFFF);
        public static readonly Color PrimaryText = Hex(0x000000);
        public static readonly Color GhostFill = QuietFill;

        // Action segments (Deny · Always · Allow, Skip · Edit · Commit).
        public static readonly Color AllowFill = PrimaryFill;
        public static readonly Color AllowText = PrimaryText;
        /// The countdown draining along Allow's bottom edge.
        public static readonly Color AllowBar = PrimaryText.WithOpacity(0.35);
        public static readonly Color DenyFill = Red.WithOpacity(0.16);
        public static readonly Color DenyText = Red;
        public static readonly Color NeutralActionFill = QuietFill;
        public static readonly Color NeutralActionText = Ink;

        /// An action segment's fill, text and countdown bar, by its role.
        public static (Color Fill, Color Text, Color Bar) Action(ActionRole role) => role switch
        {
            ActionRole.Allow => (AllowFill, AllowText, AllowBar),
            ActionRole.Deny => (DenyFill, DenyText, InkSecondary),
            _ => (NeutralActionFill, NeutralActionText, InkSecondary),
        };

        /// "Needs you": Claude's clay. The triangle glyph, the two-row shape and the words
        /// "Needs you" tell it apart from the working spark, which is clay too.
        public static readonly Color Attention = Clay;
        public static readonly Color AttentionText = Hex(0xF0A080);
        public static readonly Color AttentionHighlight = Clay.WithOpacity(0.14);
        public static readonly Color AttentionGlow = Clay.WithOpacity(0.60);
        public static readonly Color AttentionGlowDim = Clay.WithOpacity(0.15);
        public static readonly Color GreenFill = Green.WithOpacity(0.18);
        public static readonly Color RedFill = Red.WithOpacity(0.18);

        public static readonly Color DiffAddedBackground = Green.WithOpacity(0.10);
        public static readonly Color DiffRemovedBackground = Red.WithOpacity(0.10);
        /// The words that differ inside a paired removed and added line.
        public static readonly Color DiffAddedWord = Green.WithOpacity(0.34);
        public static readonly Color DiffRemovedWord = Red.WithOpacity(0.34);
        public static readonly Color DiffHunk = Blue;
        /// The diff's minimap: its track, the change marks (green, red), the visible range.
        public static readonly Color DiffMinimapTrack = Ink.WithOpacity(0.05);
        public static readonly Color DiffMinimapViewport = Ink.WithOpacity(0.10);
        public static readonly Color DiffMinimapRing = ToolFocusRing;

        /// Only the card and attention states carry a shadow.
        public static readonly Color Shadow = Hex(0x000000).WithOpacity(0.45);

        // Token breakdown in the Usage tab.
        public static readonly Color TokenCacheRead = Blue;
        public static readonly Color TokenInput = Purple;
        public static readonly Color TokenOutput = Clay;
        public static readonly Color TokenCacheWrite = Green;
        /// Limit bars in the Usage tool and the footer meter; context uses clay.
        public static readonly Color LimitBar = Ink;
        /// A limit bar at or past `Limits.limitWarnPercent`.
        public static readonly Color LimitBarHigh = Clay;
        public static readonly Color ContextBar = Clay;

        /// Collapsed wings: the session name and the "+N sessions" count.
        public static readonly Color WingsName = Ink;
        public static readonly Color WingsCountText = InkTertiary;
        /// State glyphs in the wings: green check when done, dim dot when idle.
        public static readonly Color DoneGlyph = Green;
        public static readonly Color IdleGlyph = Ink.WithOpacity(0.28);
        /// Running subagent lanes.
        public static readonly Color LaneLine = Ink.WithOpacity(0.14);
        public static readonly Color DoneChipFill = Ink.WithOpacity(0.08);
        /// One colour per subagent, cycled by the agent's index within its session.
        public static readonly IReadOnlyList<Color> AgentPalette = new[]
        {
            Clay,
            Blue,
            Purple,
            Green,
            Yellow,
            Cyan,
        };
        public static Color Agent(int index) =>
            AgentPalette[((index % AgentPalette.Count) + AgentPalette.Count) % AgentPalette.Count];

        // Settings page inside the card.
        public static readonly Color SettingsError = Red;
        public static readonly Color SettingsConnected = Green;
        public static readonly Color SettingsPartial = Attention;
        public static readonly Color SettingsDisconnected = InkTertiary;
        public static readonly Color SwitchOn = Green;
        public static readonly Color SwitchOff = Ink.WithOpacity(0.18);
        public static readonly Color SwitchKnob = Hex(0xFFFFFF);
        public static readonly Color PickerTrack = Ink.WithOpacity(0.07);
        public static readonly Color PickerSelected = Ink.WithOpacity(0.18);

        // Diff view.
        public static readonly Color DiffLineNumber = InkTertiary;
        public static readonly Color DiffText = InkSecondary;
        /// The selected file row in Changes and Files (keyboard cursor).
        public static readonly Color RowCursor = Ink.WithOpacity(0.06);

        // Changes tool (Direction G, Timeline).
        /// The spine down the timeline's left edge.
        public static readonly Color ChangesSpine = Hairline;
        /// A turn with files: a filled node on the spine.
        public static readonly Color ChangesNode = Ink;
        /// The live turn's node and its breathing halo.
        public static readonly Color ChangesNodeLive = Clay;
        public static readonly Color ChangesHalo = Clay.WithOpacity(0.25);
        /// A quiet turn's tick, and the three stacked ticks of a quiet group.
        public static readonly Color ChangesTick = InkTertiary;
        /// A file chip; the selected one, and the hovered one, a step brighter.
        /// (A property: `filterFill` is declared further down.)
        public static Color ChangesChipFill => FilterFill;
        public static readonly Color ChangesChipSelected = QuietFill;
        /// The keyboard cursor's ring around a chip.
        public static readonly Color ChangesChipRing = InkSecondary;

        // Files tab.
        /// The file whose preview is showing.
        public static readonly Color TreeOpened = QuietFill;
        public static readonly Color TreeFolder = InkSecondary;
        public static readonly Color TreeFile = Ink;
        public static readonly Color TreeChevron = InkTertiary;
        public static readonly Color FilterFill = Ink.WithOpacity(0.07);
        public static readonly Color FilterPlaceholder = InkTertiary;
        public static readonly Color PaneDivider = Hairline;
        public static readonly Color BadgeFill = Ink.WithOpacity(0.07);
        public static readonly Color PreviewLineNumber = InkTertiary;
        public static readonly Color PreviewText = InkSecondary;
        public static readonly Color PreviewAddedBackground = Green.WithOpacity(0.12);
        public static readonly Color PreviewRemovedMark = Red;
        public static readonly Color PreviewAddedNumber = Green;
        // Markdown preview in the Files tool.
        public static readonly Color MarkdownText = InkSecondary;
        public static readonly Color MarkdownHeading = Ink;
        public static readonly Color MarkdownMarker = InkTertiary;
        public static readonly Color MarkdownLink = Blue;
        public static readonly Color MarkdownCodeFill = Inset;
        public static readonly Color MarkdownQuoteRule = Track;
        public static readonly Color MarkdownRule = Hairline;
        public static readonly Color MarkdownTableHeader = Inset;

        // Sessions tab group header. It sticks over the well, so it carries the well's
        // colour flattened onto the black (the well's white opacity as a grey).
        public static readonly Color GroupHeaderBackground = Color.FromArgb(
            255,
            (byte)Math.Round(Opacity.Well * 255),
            (byte)Math.Round(Opacity.Well * 255),
            (byte)Math.Round(Opacity.Well * 255));
        public static readonly Color GroupHeaderName = InkSecondary;
        public static readonly Color GroupHeaderCount = InkTertiary;

        // Git tool.
        public static readonly Color GitBranch = Ink;
        public static readonly Color GitStatus = InkSecondary;
        public static readonly Color GitPushed = Green;
        public static readonly Color GitError = Red;
        public static readonly Color GitSection = GroupHeaderName;
        /// The target pill ("notchcode › seadevil ▾"): the repository dim, the place in ink.
        public static readonly Color GitTargetRepo = InkTertiary;
        public static readonly Color GitTargetPlace = Ink;
        public static readonly Color GitTargetNote = InkTertiary;
        /// The file kind badge (M, A, D) in the diff pane's header.
        public static readonly Color GitKindText = InkSecondary;
        public static readonly Color GitKindFill = BadgeFill;
        /// The branch picker: the repository pill's folder, the rows, the filter's lit match.
        public static readonly Color GitPickerPath = InkTertiary;
        public static readonly Color GitPickerBranch = Ink;
        public static readonly Color GitPickerPlace = InkSecondary;
        public static readonly Color GitPickerNowhere = InkTertiary;
        public static readonly Color GitPickerCount = InkSecondary;
        public static readonly Color GitPickerClean = InkTertiary;
        public static readonly Color GitPickerCursorStroke = Hairline;
        public static readonly Color GitFilterMatch = Ink.WithOpacity(0.14);
        /// The repository dropdown over the rows: the well's colour flattened (as the
        /// Sessions group header), the inset on top, a hairline edge.
        public static readonly Color GitRepoMenuBase = GroupHeaderBackground;
        public static readonly Color GitRepoMenuFill = Inset;
        public static readonly Color GitRepoMenuStroke = Hairline;
        public static readonly Color GitRepoMenuName = Ink;
        public static readonly Color GitRepoMenuOther = InkSecondary;
        /// The commit checkboxes: a tertiary edge, white when on with a dark mark (the white
        /// pill's keycap text); an unchecked file's name dims.
        public static readonly Color GitCheckStroke = InkTertiary;
        public static readonly Color GitCheckFill = Ink;
        public static readonly Color GitCheckMark = KeycapTextOnLight;
        public static readonly Color GitUnchecked = InkTertiary;
        /// The ring on the commit form's focused field.
        public static readonly Color GitFieldFocusRing = Ink.WithOpacity(0.24);
        /// The dock after a commit: "Committed · …" with Undo, quiet (it is not a field).
        public static readonly Color GitReceiptFill = QuietFill;
        /// The rail's checked-files totals ("+38 −6") and the dock's pen.
        public static readonly Color GitRailTotals = InkTertiary;
        /// The commit form's co-author chips and the ring on the suggestion ⏎ adds.
        public static readonly Color GitCoauthorChipFill = QuietFill;
        public static readonly Color GitCoauthorChipText = InkSecondary;
        public static readonly Color GitSuggestionRing = InkSecondary;

        /// A session's permission mode, as a word in its Sessions row and the open card's status
        /// line: bypass in clay (the dangerous one), plan in blue, the rest tertiary.
        public static Color PermissionMode(string? raw) => raw switch
        {
            "bypassPermissions" => Clay,
            "plan" => Blue,
            _ => InkTertiary,
        };

        /// Hover rim light (Motion board M7): the crescent under the bottom edge of the closed
        /// and resting shape (50% white), and its glow (12%). Both sit outside the black.
        public static readonly Color Rim = Ink.WithOpacity(0.5);
        public static readonly Color RimGlow = Ink.WithOpacity(0.12);
        /// Clay bleed below the shape when attention arrives (scaled by the bleed opacity).
        public static readonly Color AttentionBleed = Clay.WithOpacity(0.35);
        /// The resting dot: green when the session finished, grey when idle.
        public static readonly Color RestingDone = Green;
        public static readonly Color RestingIdle = InkTertiary;

        /// A state's glyph and dot colour.
        public static Color StateGlyph(SessionState state) => state switch
        {
            SessionState.Working => Clay,
            SessionState.NeedsYou => Attention,
            SessionState.Done => DoneGlyph,
            _ => IdleGlyph,
        };

        /// A state's word ("Needs you", "Editing", "Done", "Idle").
        public static Color StateText(SessionState state) => state switch
        {
            SessionState.NeedsYou => AttentionText,
            SessionState.Working => Clay,
            SessionState.Done => Green,
            _ => InkTertiary,
        };
    }

    // MARK: - Brushes (every colour above as a frozen SolidColorBrush, same names)

    public static partial class Brushes
    {
        public static readonly SolidColorBrush Notch = Brush(Colors.Notch);
        public static readonly SolidColorBrush Ink = Brush(Colors.Ink);
        public static readonly SolidColorBrush Clay = Brush(Colors.Clay);
        public static readonly SolidColorBrush Green = Brush(Colors.Green);
        public static readonly SolidColorBrush Red = Brush(Colors.Red);
        public static readonly SolidColorBrush Blue = Brush(Colors.Blue);
        public static readonly SolidColorBrush Purple = Brush(Colors.Purple);
        public static readonly SolidColorBrush Yellow = Brush(Colors.Yellow);
        public static readonly SolidColorBrush Cyan = Brush(Colors.Cyan);
        public static readonly SolidColorBrush InkSecondary = Brush(Colors.InkSecondary);
        public static readonly SolidColorBrush InkTertiary = Brush(Colors.InkTertiary);
        public static readonly SolidColorBrush Inset = Brush(Colors.Inset);
        public static readonly SolidColorBrush Hairline = Brush(Colors.Hairline);
        public static readonly SolidColorBrush Track = Brush(Colors.Track);
        public static readonly SolidColorBrush QuietFill = Brush(Colors.QuietFill);
        public static readonly SolidColorBrush Selection = Brush(Colors.Selection);
        public static readonly SolidColorBrush KeycapFill = Brush(Colors.KeycapFill);
        public static readonly SolidColorBrush KeycapFillOnLight = Brush(Colors.KeycapFillOnLight);
        public static readonly SolidColorBrush KeycapTextOnLight = Brush(Colors.KeycapTextOnLight);
        public static readonly SolidColorBrush CellEmpty = Brush(Colors.CellEmpty);
        public static readonly SolidColorBrush SegmentHover = Brush(Colors.SegmentHover);
        public static readonly SolidColorBrush SegmentPressed = Brush(Colors.SegmentPressed);
        public static readonly SolidColorBrush ToolSelected = Brush(Colors.ToolSelected);
        public static readonly SolidColorBrush SegmentIcon = Brush(Colors.SegmentIcon);
        public static readonly SolidColorBrush SegmentIconSelected = Brush(Colors.SegmentIconSelected);
        public static readonly SolidColorBrush ToolFocusRing = Brush(Colors.ToolFocusRing);
        public static readonly SolidColorBrush Bridge = Brush(Colors.Bridge);
        public static readonly SolidColorBrush StripDivider = Brush(Colors.StripDivider);
        public static readonly SolidColorBrush ToolGroupRule = Brush(Colors.ToolGroupRule);
        public static readonly SolidColorBrush ToolBadgeFill = Brush(Colors.ToolBadgeFill);
        public static readonly SolidColorBrush ToolBadgeText = Brush(Colors.ToolBadgeText);
        public static readonly SolidColorBrush Well = Brush(Colors.Well);
        public static readonly SolidColorBrush WellStroke = Brush(Colors.WellStroke);
        public static readonly SolidColorBrush ToolLabelFill = Brush(Colors.ToolLabelFill);
        public static readonly SolidColorBrush ToolLabelStroke = Brush(Colors.ToolLabelStroke);
        public static readonly SolidColorBrush ToolLabelText = Brush(Colors.ToolLabelText);
        public static readonly SolidColorBrush PrimaryFill = Brush(Colors.PrimaryFill);
        public static readonly SolidColorBrush PrimaryText = Brush(Colors.PrimaryText);
        public static readonly SolidColorBrush GhostFill = Brush(Colors.GhostFill);
        public static readonly SolidColorBrush AllowFill = Brush(Colors.AllowFill);
        public static readonly SolidColorBrush AllowText = Brush(Colors.AllowText);
        public static readonly SolidColorBrush AllowBar = Brush(Colors.AllowBar);
        public static readonly SolidColorBrush DenyFill = Brush(Colors.DenyFill);
        public static readonly SolidColorBrush DenyText = Brush(Colors.DenyText);
        public static readonly SolidColorBrush NeutralActionFill = Brush(Colors.NeutralActionFill);
        public static readonly SolidColorBrush NeutralActionText = Brush(Colors.NeutralActionText);
        public static readonly SolidColorBrush Attention = Brush(Colors.Attention);
        public static readonly SolidColorBrush AttentionText = Brush(Colors.AttentionText);
        public static readonly SolidColorBrush AttentionHighlight = Brush(Colors.AttentionHighlight);
        public static readonly SolidColorBrush AttentionGlow = Brush(Colors.AttentionGlow);
        public static readonly SolidColorBrush AttentionGlowDim = Brush(Colors.AttentionGlowDim);
        public static readonly SolidColorBrush GreenFill = Brush(Colors.GreenFill);
        public static readonly SolidColorBrush RedFill = Brush(Colors.RedFill);
        public static readonly SolidColorBrush DiffAddedBackground = Brush(Colors.DiffAddedBackground);
        public static readonly SolidColorBrush DiffRemovedBackground = Brush(Colors.DiffRemovedBackground);
        public static readonly SolidColorBrush DiffAddedWord = Brush(Colors.DiffAddedWord);
        public static readonly SolidColorBrush DiffRemovedWord = Brush(Colors.DiffRemovedWord);
        public static readonly SolidColorBrush DiffHunk = Brush(Colors.DiffHunk);
        public static readonly SolidColorBrush DiffMinimapTrack = Brush(Colors.DiffMinimapTrack);
        public static readonly SolidColorBrush DiffMinimapViewport = Brush(Colors.DiffMinimapViewport);
        public static readonly SolidColorBrush DiffMinimapRing = Brush(Colors.DiffMinimapRing);
        public static readonly SolidColorBrush Shadow = Brush(Colors.Shadow);
        public static readonly SolidColorBrush TokenCacheRead = Brush(Colors.TokenCacheRead);
        public static readonly SolidColorBrush TokenInput = Brush(Colors.TokenInput);
        public static readonly SolidColorBrush TokenOutput = Brush(Colors.TokenOutput);
        public static readonly SolidColorBrush TokenCacheWrite = Brush(Colors.TokenCacheWrite);
        public static readonly SolidColorBrush LimitBar = Brush(Colors.LimitBar);
        public static readonly SolidColorBrush LimitBarHigh = Brush(Colors.LimitBarHigh);
        public static readonly SolidColorBrush ContextBar = Brush(Colors.ContextBar);
        public static readonly SolidColorBrush WingsName = Brush(Colors.WingsName);
        public static readonly SolidColorBrush WingsCountText = Brush(Colors.WingsCountText);
        public static readonly SolidColorBrush DoneGlyph = Brush(Colors.DoneGlyph);
        public static readonly SolidColorBrush IdleGlyph = Brush(Colors.IdleGlyph);
        public static readonly SolidColorBrush LaneLine = Brush(Colors.LaneLine);
        public static readonly SolidColorBrush DoneChipFill = Brush(Colors.DoneChipFill);
        public static readonly SolidColorBrush SettingsError = Brush(Colors.SettingsError);
        public static readonly SolidColorBrush SettingsConnected = Brush(Colors.SettingsConnected);
        public static readonly SolidColorBrush SettingsPartial = Brush(Colors.SettingsPartial);
        public static readonly SolidColorBrush SettingsDisconnected = Brush(Colors.SettingsDisconnected);
        public static readonly SolidColorBrush SwitchOn = Brush(Colors.SwitchOn);
        public static readonly SolidColorBrush SwitchOff = Brush(Colors.SwitchOff);
        public static readonly SolidColorBrush SwitchKnob = Brush(Colors.SwitchKnob);
        public static readonly SolidColorBrush PickerTrack = Brush(Colors.PickerTrack);
        public static readonly SolidColorBrush PickerSelected = Brush(Colors.PickerSelected);
        public static readonly SolidColorBrush DiffLineNumber = Brush(Colors.DiffLineNumber);
        public static readonly SolidColorBrush DiffText = Brush(Colors.DiffText);
        public static readonly SolidColorBrush RowCursor = Brush(Colors.RowCursor);
        public static readonly SolidColorBrush ChangesSpine = Brush(Colors.ChangesSpine);
        public static readonly SolidColorBrush ChangesNode = Brush(Colors.ChangesNode);
        public static readonly SolidColorBrush ChangesNodeLive = Brush(Colors.ChangesNodeLive);
        public static readonly SolidColorBrush ChangesHalo = Brush(Colors.ChangesHalo);
        public static readonly SolidColorBrush ChangesTick = Brush(Colors.ChangesTick);
        public static readonly SolidColorBrush ChangesChipFill = Brush(Colors.ChangesChipFill);
        public static readonly SolidColorBrush ChangesChipSelected = Brush(Colors.ChangesChipSelected);
        public static readonly SolidColorBrush ChangesChipRing = Brush(Colors.ChangesChipRing);
        public static readonly SolidColorBrush TreeOpened = Brush(Colors.TreeOpened);
        public static readonly SolidColorBrush TreeFolder = Brush(Colors.TreeFolder);
        public static readonly SolidColorBrush TreeFile = Brush(Colors.TreeFile);
        public static readonly SolidColorBrush TreeChevron = Brush(Colors.TreeChevron);
        public static readonly SolidColorBrush FilterFill = Brush(Colors.FilterFill);
        public static readonly SolidColorBrush FilterPlaceholder = Brush(Colors.FilterPlaceholder);
        public static readonly SolidColorBrush PaneDivider = Brush(Colors.PaneDivider);
        public static readonly SolidColorBrush BadgeFill = Brush(Colors.BadgeFill);
        public static readonly SolidColorBrush PreviewLineNumber = Brush(Colors.PreviewLineNumber);
        public static readonly SolidColorBrush PreviewText = Brush(Colors.PreviewText);
        public static readonly SolidColorBrush PreviewAddedBackground = Brush(Colors.PreviewAddedBackground);
        public static readonly SolidColorBrush PreviewRemovedMark = Brush(Colors.PreviewRemovedMark);
        public static readonly SolidColorBrush PreviewAddedNumber = Brush(Colors.PreviewAddedNumber);
        public static readonly SolidColorBrush MarkdownText = Brush(Colors.MarkdownText);
        public static readonly SolidColorBrush MarkdownHeading = Brush(Colors.MarkdownHeading);
        public static readonly SolidColorBrush MarkdownMarker = Brush(Colors.MarkdownMarker);
        public static readonly SolidColorBrush MarkdownLink = Brush(Colors.MarkdownLink);
        public static readonly SolidColorBrush MarkdownCodeFill = Brush(Colors.MarkdownCodeFill);
        public static readonly SolidColorBrush MarkdownQuoteRule = Brush(Colors.MarkdownQuoteRule);
        public static readonly SolidColorBrush MarkdownRule = Brush(Colors.MarkdownRule);
        public static readonly SolidColorBrush MarkdownTableHeader = Brush(Colors.MarkdownTableHeader);
        public static readonly SolidColorBrush GroupHeaderBackground = Brush(Colors.GroupHeaderBackground);
        public static readonly SolidColorBrush GroupHeaderName = Brush(Colors.GroupHeaderName);
        public static readonly SolidColorBrush GroupHeaderCount = Brush(Colors.GroupHeaderCount);
        public static readonly SolidColorBrush GitBranch = Brush(Colors.GitBranch);
        public static readonly SolidColorBrush GitStatus = Brush(Colors.GitStatus);
        public static readonly SolidColorBrush GitPushed = Brush(Colors.GitPushed);
        public static readonly SolidColorBrush GitError = Brush(Colors.GitError);
        public static readonly SolidColorBrush GitSection = Brush(Colors.GitSection);
        public static readonly SolidColorBrush GitTargetRepo = Brush(Colors.GitTargetRepo);
        public static readonly SolidColorBrush GitTargetPlace = Brush(Colors.GitTargetPlace);
        public static readonly SolidColorBrush GitTargetNote = Brush(Colors.GitTargetNote);
        public static readonly SolidColorBrush GitKindText = Brush(Colors.GitKindText);
        public static readonly SolidColorBrush GitKindFill = Brush(Colors.GitKindFill);
        public static readonly SolidColorBrush GitPickerPath = Brush(Colors.GitPickerPath);
        public static readonly SolidColorBrush GitPickerBranch = Brush(Colors.GitPickerBranch);
        public static readonly SolidColorBrush GitPickerPlace = Brush(Colors.GitPickerPlace);
        public static readonly SolidColorBrush GitPickerNowhere = Brush(Colors.GitPickerNowhere);
        public static readonly SolidColorBrush GitPickerCount = Brush(Colors.GitPickerCount);
        public static readonly SolidColorBrush GitPickerClean = Brush(Colors.GitPickerClean);
        public static readonly SolidColorBrush GitPickerCursorStroke = Brush(Colors.GitPickerCursorStroke);
        public static readonly SolidColorBrush GitFilterMatch = Brush(Colors.GitFilterMatch);
        public static readonly SolidColorBrush GitRepoMenuBase = Brush(Colors.GitRepoMenuBase);
        public static readonly SolidColorBrush GitRepoMenuFill = Brush(Colors.GitRepoMenuFill);
        public static readonly SolidColorBrush GitRepoMenuStroke = Brush(Colors.GitRepoMenuStroke);
        public static readonly SolidColorBrush GitRepoMenuName = Brush(Colors.GitRepoMenuName);
        public static readonly SolidColorBrush GitRepoMenuOther = Brush(Colors.GitRepoMenuOther);
        public static readonly SolidColorBrush GitCheckStroke = Brush(Colors.GitCheckStroke);
        public static readonly SolidColorBrush GitCheckFill = Brush(Colors.GitCheckFill);
        public static readonly SolidColorBrush GitCheckMark = Brush(Colors.GitCheckMark);
        public static readonly SolidColorBrush GitUnchecked = Brush(Colors.GitUnchecked);
        public static readonly SolidColorBrush GitFieldFocusRing = Brush(Colors.GitFieldFocusRing);
        public static readonly SolidColorBrush GitReceiptFill = Brush(Colors.GitReceiptFill);
        public static readonly SolidColorBrush GitRailTotals = Brush(Colors.GitRailTotals);
        public static readonly SolidColorBrush GitCoauthorChipFill = Brush(Colors.GitCoauthorChipFill);
        public static readonly SolidColorBrush GitCoauthorChipText = Brush(Colors.GitCoauthorChipText);
        public static readonly SolidColorBrush GitSuggestionRing = Brush(Colors.GitSuggestionRing);
        public static readonly SolidColorBrush Rim = Brush(Colors.Rim);
        public static readonly SolidColorBrush RimGlow = Brush(Colors.RimGlow);
        public static readonly SolidColorBrush AttentionBleed = Brush(Colors.AttentionBleed);
        public static readonly SolidColorBrush RestingDone = Brush(Colors.RestingDone);
        public static readonly SolidColorBrush RestingIdle = Brush(Colors.RestingIdle);

        /// An action segment's fill, text and countdown bar, by its role.
        public static (SolidColorBrush Fill, SolidColorBrush Text, SolidColorBrush Bar) Action(ActionRole role) => role switch
        {
            ActionRole.Allow => (AllowFill, AllowText, AllowBar),
            ActionRole.Deny => (DenyFill, DenyText, InkSecondary),
            _ => (NeutralActionFill, NeutralActionText, InkSecondary),
        };

        /// One brush per subagent, cycled by the agent's index within its session.
        public static readonly IReadOnlyList<SolidColorBrush> AgentPalette = new[] { Clay, Blue, Purple, Green, Yellow, Cyan };
        public static SolidColorBrush Agent(int index) =>
            AgentPalette[((index % AgentPalette.Count) + AgentPalette.Count) % AgentPalette.Count];

        /// A session's permission mode word: bypass in clay, plan in blue, the rest tertiary.
        public static SolidColorBrush PermissionMode(string? raw) => raw switch
        {
            "bypassPermissions" => Clay,
            "plan" => Blue,
            _ => InkTertiary,
        };

        /// A state's glyph and dot brush.
        public static SolidColorBrush StateGlyph(SessionState state) => state switch
        {
            SessionState.Working => Clay,
            SessionState.NeedsYou => Attention,
            SessionState.Done => DoneGlyph,
            _ => IdleGlyph,
        };

        /// A state's word brush.
        public static SolidColorBrush StateText(SessionState state) => state switch
        {
            SessionState.NeedsYou => AttentionText,
            SessionState.Working => Clay,
            SessionState.Done => Green,
            _ => InkTertiary,
        };
    }

    // MARK: - Radii

    public static partial class Radius
    {
        // Convex bottom corners of the shape, per state.
        public const double ClosedBottom = 10;
        public const double WingsBottom = 14;
        public const double RestingBottom = 14;
        public const double PeekBottom = 14;
        public const double AttentionBottom = 18;
        public const double CardBottom = 26;

        // Concave "ears" where the shape meets the top edge of the screen.
        public const double ClosedTop = 10;
        public const double WingsTop = 12;
        public const double PeekTop = 12;
        public const double RestingTop = 12;
        public const double AttentionTop = 14;
        public const double CardTop = 18;

        public const double Inset = 12;
        public const double Tile = 14;
        public const double Row = 10;
        public const double Keycap = 4;
        public const double Chip = 6;
        /// The Git tool's commit checkboxes.
        public const double GitCheckbox = 3;
        public const double DiffCell = 1;
        public const double DiffMinimap = 2;
        public const double DiffMinimapViewport = 3;
        public const double AgentSquare = 1.5;
        public const double Snippet = 8;

        // The toolbar strip.
        /// Tool and action segments.
        public const double Segment = 6;
        /// Concentric with the segment it rings.
        public const double ToolFocus = Segment + Size.ToolFocusOutset;
        public const double Bridge = 1;
        public const double ToolBadge = 4;
        public const double ToolLabel = 5;
        /// The card's content well.
        public const double Well = 14;
    }

    // MARK: - Sizes and spacing

    public static partial class Size
    {
        /// `CardTab.browsable.count` (Sessions, Changes, Files, Git, Usage). CardTab lives in
        /// State, which the Theme does not reference.
        private const int BrowsableToolCount = 5;

        // Fallback when the screen has no notch (external display). On Windows: always.
        public const double FallbackNotchWidth = 180;
        public const double FallbackNotchHeight = 32;

        // The panel is a fixed box; the shape draws at its top centre.
        public const double PanelWidth = 900;
        public const double PanelHeight = 504;
        /// Extra points above the shape counted as "inside" for mouse pass-through.
        public const double HitSlop = 2;

        // Shape body sizes per state (ears are added outside these widths).
        public const double WingsWidth = 470;
        public const double RestingWidth = 420;
        public const double PeekWidth = 580;
        /// Attention and the card share one width, so the three action segments fit the
        /// right wing with room. The panel holds the outer size plus ears and shadow.
        public const double AttentionWidth = 640;
        public const double AttentionExtraHeight = 40;
        public const double CardWidth = AttentionWidth;
        /// Minimum wing width on each side, used when the notch is wider than expected.
        public const double MinWing = 100;

        // Card content height below the strip, per tool. The card re-targets its height
        // with one spring when the tool changes, so each tool gets the room it needs.
        public const double SessionsCardHeight = 400;
        public const double ChangesCardHeight = 424;
        public const double FilesCardHeight = 440;
        public const double UsageCardHeight = 420;
        public const double GitCardHeight = 424;
        /// The Git tool: the header row (branch, status, the sync pill).
        public const double GitHeaderHeight = 26;
        public const double GitPushingGlyph = 10;
        /// The rail: its header row ("Uncommitted · 4"), and its width folded (⌘B), the
        /// checkbox column only.
        public const double GitRailHeaderHeight = TreeRowHeight;
        public const double GitRailFolded = 22;
        /// The stage's header row (the ⌘B pill, then the file, "Commit to main", or nothing).
        public const double GitStageHeaderHeight = TreeRowHeight;
        /// The dock at the rail's foot: the summary field's box, the same height as the form's.
        public const double GitDockHeight = GitFieldHeight;
        /// Between the dock's box and the Undo pill inside it ((26 − 22) / 2).
        public const double GitDockPillInset = (GitFieldHeight - ActionHeight) / 2;
        /// The confirm's question sits with its centre at this share of the stage's height.
        public const double GitConfirmCentre = 0.4;
        /// Co-author chips: their padding, the "recent" suggestion row, the ring on the first.
        public const double GitChipVPadding = 2;
        public const double GitChipHPadding = 6;
        public const double GitChipGap = 4;
        public const double GitSuggestionRowHeight = 20;
        public const double GitSuggestionRing = 1;
        /// The green check before "Nothing to commit · up to date" in the empty diff pane.
        public const double GitCleanCircle = 22;
        /// The target pill never takes more than this; the place truncates in the middle.
        public const double GitTargetMaxWidth = 220;
        /// The push confirm's question wraps at this width, two lines at most.
        public const double GitConfirmMaxWidth = 360;
        /// The file kind badge (M, A, D) in the diff pane's header.
        public const double GitKindWidth = 14;
        /// The branch picker: two-line rows, the worktree glyph before "worktree seadevil",
        /// the repository dropdown.
        public const double GitBranchRowHeight = 40;
        public const double GitBranchRowHPadding = 10;
        public const double GitBranchLineGap = 1;
        public const double GitPlaceGlyph = 9;
        public const double GitRepoMenuWidth = 300;
        public const double GitRepoMenuRowHeight = 26;
        public const double GitRepoMenuPadding = 4;
        public const double GitPickerPathMaxWidth = 260;
        /// The commit checkboxes and their gap to the file name.
        public const double GitCheckbox = 12;
        public const double GitCheckboxGap = 6;
        /// The mark inside a checkbox: the drawn check's box and stroke, the mixed state's dash.
        public const double GitCheckMark = 8;
        public const double GitCheckLine = 1.6;
        public const double GitCheckDash = 6;
        public const double GitCheckboxStroke = 1;
        /// Unticking: the box's fill shrinks to this scale as it fades.
        public const double GitUntickScale = 0.6;
        /// The commit form: the summary box, its side padding, the description's least height,
        /// and the text view's own inset that its "Description" prompt lines up with.
        public const double GitFieldHeight = 26;
        public const double GitFieldHPadding = 8;
        public const double GitFieldVPadding = 6;
        public const double GitDescriptionMinHeight = 60;
        public const double GitDescriptionTextInset = 5;
        /// The commit form's focus ring.
        public const double GitFieldFocusStroke = 1;
        public const double CardFooterHeight = 20;
        public const double RequestCardHeight = 310;
        /// A permission or commit card with its diff open. Keeps the panel clear of the notch row plus shadow.
        public const double RequestCardHeightExpanded = 440;
        /// A plan request: the rendered plan takes the room a diff takes.
        public const double PlanCardHeight = 440;
        public const double CommitCardHeight = 356;
        public const double QuestionCardHeight = 296;
        public const double SettingsCardHeight = 424;

        public const double SidePadding = 16;
        public const double WingInnerGap = 10;
        /// Room inside a wing's clip so glyph rings and glows are never cut at the outer edge.
        public const double WingEdgeInset = 6;

        // Spacing scale.
        public const double SpaceXS = 2;
        public const double SpaceS = 4;
        public const double SpaceM = 8;
        public const double SpaceL = 12;

        // Wings.
        public const double Glyph = 13;
        public const double WingSpacing = 5;
        public const double Dot = 6;

        // Rings and lines.
        public const double RingLine = 1.5;
        public const double CountdownRing = 14;
        public const double CountdownRingLarge = 20;
        public const double CountdownLine = 2;
        public const double PeekLine = 3;
        public const double PeekCircle = 18;
        public const double IconCircle = 28;
        /// Symbol size relative to its circle.
        public const double GlyphInCircle = 0.5;
        public const double FooterMinScale = 0.9;
        public const double Hairline = 0.5;

        // Keycaps and pills.
        public const double KeycapMin = 16;
        public const double KeycapHPadding = 4;
        public const double SmallPillHPadding = 6;
        public const double SmallPillHeight = 16;
        public const double ChipHPadding = 6;
        public const double ChipHeight = 18;

        // Bars and tiles.
        public const double BarHeight = 4;
        public const double FooterBarWidth = 64;
        public const double LegendDot = 6;
        public const double InsetPadding = 10;
        /// Padding inside the card's content well.
        public const double WellPadding = 8;

        // The toolbar strip: tool segments.
        public const double ToolWidth = 36;
        public const double GearWidth = 26;
        public const double ToolHeight = 22;
        public const double ToolGap = 2;
        /// The stroked outlines span about three quarters of their box, so 15 pt reads like the 11 pt symbols did.
        public const double ToolIcon = 15;
        /// A tool icon's stroke as a share of its size: the canvas draws 2.4 in a 24 box.
        public const double ToolStrokeRatio = 2.4 / 24;
        /// The gear's stroke, a little finer: 2.2 in the canvas's 24 box.
        public const double GearStrokeRatio = 2.2 / 24;
        /// The collapsed strip's tools on hover: narrower, so all five fit the resting wing.
        public const double CompactToolWidth = 20;
        public const double CompactToolGap = 1;
        /// The collapsed strip's five tools side by side. The resting and wings shapes widen
        /// past `restingWidth` / `wingsWidth` to keep this whole (NotchLayout).
        public static double CompactToolsWidth
        {
            get
            {
                double tools = BrowsableToolCount;
                return tools * CompactToolWidth + (tools - 1) * CompactToolGap;
            }
        }
        public const double ToolGroupGap = 6;
        public const double ToolGroupRuleHeight = 12;
        public const double ToolRuleWidth = 1;
        /// The focus ring sits this far outside the tool segment.
        public const double ToolFocusOutset = 2;
        public const double ToolFocusLine = 1;
        public const double BridgeWidth = 14;
        public const double BridgeHeight = 2;
        /// The open strip's right wing: the tools, the rule with its padding, the gear,
        /// and the gaps between them. The card widens past `cardWidth` to keep this whole.
        public static double StripToolsWidth
        {
            get
            {
                double tools = BrowsableToolCount;
                double rule = ToolRuleWidth + 2 * ToolGroupGap;
                return tools * ToolWidth + (tools + 1) * ToolGap + rule + GearWidth;
            }
        }
        /// Room left free on the camera side of the tools, so the first tool's focus ring
        /// (outset plus its line) is never cut by the wing's clip.
        public const double StripToolsSlack = ToolFocusOutset + ToolFocusLine;
        public const double ToolBadgeHeight = 11;
        public const double ToolBadgeHPadding = 3;
        public const double ToolBadgeOffset = 4;
        // The tool name caption: a small pill hung just under the strip (open card), or
        // the collapsed strip's left wing (there is no room below it inside the black).
        public const double ToolLabelHeight = 16;
        public const double ToolLabelHPadding = 6;
        /// Gap between the strip's hairline and the top of the pill.
        public const double ToolLabelDrop = 3;
        // Action segments.
        public const double ActionHeight = 22;
        public const double ActionHPadding = 6;
        public const double ActionGap = 3;
        public const double ActionKeyGap = 3;
        public const double CountdownBar = 2;
        public const double CountdownBarInset = 5;
        /// The open card's status segment (left wing).
        public const double StatusSpacing = 8;
        /// The narrowest left wing the status segment gets: what the four-tool card gave it
        /// on a 179 pt notch ((640 − 179) / 2 − 26). The card widens to keep it.
        public const double StatusMinWidth = 204;

        // Usage tab: one fixed page, never scrolls. The limits row takes what the others leave.
        public const double UsageRowSpacing = 10;
        public const double UsageTileSpacing = 8;
        public const double UsageLineSpacing = 4;
        public const double UsageLegendSpacing = 10;
        /// The context bar.
        public const double TokenBarHeight = 8;
        /// The context row: its line, the bar, the legend.
        public const double UsageContextRowHeight = 66;
        /// This session, Today and This week.
        public const double UsageSessionRowHeight = 76;
        /// What's using your limits: two lines.
        public const double UsageBehaviorsRowHeight = 44;
        /// This session's four-part token bar.
        public const double UsageMiniBarHeight = 6;
        /// Top and bottom padding inside the session and behaviour tiles, so their lines fit the fixed heights.
        public const double UsageCompactPadding = 6;
        public const double UsageFootnoteHeight = 14;
        /// Height of a tool's pane inside the well: the card minus the bridge row, the two
        /// gaps around the well, the footer, the bottom padding and the well's own padding.
        public static double TabPaneHeight(double cardHeight) =>
            cardHeight - BridgeHeight - 2 * SpaceM - CardFooterHeight - SidePadding - 2 * WellPadding;
        /// The limit tiles: the pane minus the other rows and the four gaps.
        public static double UsageLimitsRowHeight =>
            TabPaneHeight(UsageCardHeight) - UsageContextRowHeight - UsageSessionRowHeight
                - UsageBehaviorsRowHeight - UsageFootnoteHeight - 4 * UsageRowSpacing;

        // Hover rim light, the Motion board M7: the CSS `inset 0 -2px 0 0 white/50%` mirrored
        // outward (the shape shifted 2 pt down minus the shape: a 2 pt band under the flat
        // bottom edge that thins to nothing up each corner) and its `0 2px 12px white/12%`
        // glow behind the black. 2 px per pt.
        public const double RimLine = 2;
        /// The glow: the whole shape dropped 2 pt and blurred 6 pt (the board's 12 px blur).
        public const double RimGlowDrop = 2;
        public const double RimGlowRadius = 6;

        // Clay bleed below the attention shape. Wider than the whole shape so both wings
        // carry it, centred below the bottom edge so nothing relies on the camera area.
        public const double BleedWidthFactor = 1.1;
        public const double BleedHeight = 44;
        public const double BleedBlur = 22;
        /// How far below the shape's bottom edge the bleed's centre sits.
        public const double BleedDrop = 6;

        // Done peek check, drawn in a unit square inside the peek circle.
        public const double CheckLine = 1.8;
        public const double CheckInset = 0.28;

        // The five cells in a changed-file row.
        public const double DiffCellWidth = 4;
        public const double DiffCellHeight = 7;
        public const double DiffCellSpacing = 1;
        /// Every list row (Sessions, request rows) pads by these.
        public const double RowVPadding = 6;
        public const double RowHPadding = 8;

        // Sessions tab: agent lanes under a session row.
        public const double LaneIndent = 22;
        public const double LaneVPadding = 3;
        public const double LaneLineWidth = 1;
        /// Chevron plus its gap, so lane clocks line up with the row clock.
        public const double ChevronColumn = 14;
        /// The teleport chevron's hit area height on a session row.
        public const double ChevronHitHeight = 34;

        // Changes tool (Direction G, Timeline). Inside the well (576 × 334): the header row,
        // then the body; the timeline column takes the full width, or `changesColumnWidth`
        // beside the diff pane (gap, hairline, gap, the pane).
        /// The header row: the session's totals and the With edits pill.
        public const double ChangesHeaderHeight = 26;
        /// The spine's x inside the column; titles start at `changesTitleInset`.
        public const double ChangesSpineX = 10;
        public const double ChangesTitleInset = 26;
        /// A turn's node, the live node's halo, a quiet turn's tick (6 × 1).
        public const double ChangesNode = 8;
        public const double ChangesHalo = 14;
        public const double ChangesTickWidth = 6;
        public const double ChangesTickHeight = 1;
        /// The quiet group's three ticks, this far apart.
        public const double ChangesTickGap = 3;
        /// One timeline row: an entry's first line, a quiet row, a chip.
        public const double ChangesRowHeight = 20;
        /// Between entries, and between an entry's title and its chips.
        public const double ChangesEntryGap = 12;
        public const double ChangesTitleGap = 4;
        /// A file chip: 20 pt tall, 6 pt inside, 4 pt apart (both ways), the name at most 120 pt.
        public const double ChangesChipHeight = 20;
        public const double ChangesChipHPadding = 6;
        public const double ChangesChipGap = 4;
        public const double ChangesChipMaxWidth = 120;
        /// The fade that ends a cut title or prompt instead of an ellipsis.
        public const double ChangesFadeWidth = 24;
        /// The timeline column beside the diff pane, and the pane.
        public const double ChangesColumnWidth = 236;
        public const double ChangesPaneWidth = 320;
        /// Past this column width an entry shows its duration and a quiet group its
        /// "questions and decisions" tail.
        public const double ChangesWideColumn = 300;
        /// The live node's halo breathes out to this scale.
        public const double ChangesHaloScale = 1.5;
        /// The keyboard cursor's ring around a chip.
        public const double ChangesRing = 1;
        /// An entry's title sits this far down its 20 pt first row (13 pt body in 16 pt lines).
        public const double ChangesTitleVPadding = 2;

        // Settings page inside the card.
        public const double SettingsRowHeight = 28;
        public const double SettingsGroupSpacing = 10;
        public const double SettingsLabelSpacing = 4;
        public const double SwitchWidth = 28;
        public const double SwitchHeight = 16;
        public const double SwitchKnobInset = 2;
        public const double PickerHeight = 22;
        public const double PickerHPadding = 9;
        public const double PickerInset = 2;
        public const double StepperValueWidth = 36;
        public const double BackPillHeight = 22;
        public const double BackPillHPadding = 9;

        // Subagent colour squares.
        public const double AgentSquare = 7;
        public const double AgentSquareSpacing = 3;

        // Diff view: a rounded box, two line-number columns (old, new), then the line.
        // Its font, padding and gutter are the Files preview's.
        public const double DiffLineHeight = 16;
        public const double DiffMaxHeight = 220;
        /// One line-number column, wide enough for four digits at the mono size.
        public const double DiffLineNumberWidth = 30;
        /// The minimap down a diff pane's right edge: its width, its gap from the edge, the
        /// room the lines leave for it, the smallest mark and visible-range box.
        public const double DiffMinimapWidth = 6;
        public const double DiffMinimapInset = 3;
        public const double DiffMinimapReserve = 12;
        public const double DiffMinimapMinMark = 2;
        public const double DiffMinimapMinViewport = 8;
        public const double DiffMinimapViewportOutset = 2;
        public const double DiffMinimapRingLine = 1;
        public const double GroupHeaderTopPadding = 6;
        /// Inside a request card the diff takes what is left above the footer, up to this.
        public const double RequestDiffMaxHeight = 260;
        /// ... and never less than this (a short diff is shorter still).
        public const double RequestDiffMinHeight = 72;

        // Sessions tab: one slim sticky header per repository.
        public const double RepoHeaderHeight = 22;

        // Files tab: the tree on the left, the preview on the right.
        /// The tree column's share of the card's content width.
        public const double FileTreeShare = 0.4;
        public const double FilesColumnGap = 10;
        public const double FilterHeight = 22;
        public const double FilterHPadding = 8;
        public const double TreeRowHeight = 20;
        public const double TreeIndent = 12;
        public const double TreeChevronWidth = 10;
        public const double TreeRowHPadding = 6;
        public const double BadgeHPadding = 4;
        public const double BadgeHeight = 14;
        public const double PreviewLineHeight = 16;
        public const double PreviewNumberWidth = 34;
        public const double PreviewGutterSpacing = 8;
        public const double PreviewHPadding = 6;
        public const double PreviewVPadding = 4;
        public const double RemovedMarkWidth = 2;
        // Markdown preview: padding inside the box, space between blocks, list and quote indents.
        public const double MarkdownPadding = 10;
        public const double MarkdownBlockSpacing = 8;
        public const double MarkdownLineSpacing = 2;
        public const double MarkdownMarkerGap = 6;
        public const double MarkdownListIndent = 12;
        public const double MarkdownQuoteRule = 2;
        public const double MarkdownQuoteGap = 8;
        public const double MarkdownCodePadding = 8;
        public const double MarkdownCellHPadding = 6;
        public const double MarkdownCellVPadding = 3;
        public const double MarkdownHeadingTopSpacing = 4;

        public const double BreatheRadius = 6;
        public const double ShadowRadius = 18;
        public const double ShadowY = 8;
    }

    // MARK: - Opacity

    public static partial class Opacity
    {
        public const double Pressed = 0.7;
        /// Controls that do nothing right now (peek length while peeks are off).
        public const double Disabled = 0.4;
        public const double PulseStart = 0.8;
        /// The resting state's worktree name; hover brings it to full.
        public const double Resting = 0.6;
        public const double RestingHover = 1;
        /// Clay bleed: peak on arrival, then where it settles.
        public const double BleedPeak = 1;
        public const double BleedRest = 0.4;
        /// Fill behind a symbol in a tinted circle.
        public const double GlyphCircle = 0.2;
        /// The card's content well: white at this opacity over the black.
        public const double Well = 0.045;
        /// Finished agents keep their colour, dimmed.
        public const double AgentFinished = 0.45;
        /// An unchecked Git file's cells.
        public const double GitUncheckedCells = Disabled;
        /// The commit form's fields while git commits.
        public const double GitLocked = 0.6;
    }

    // MARK: - Motion

    public static partial class Motion
    {
        /// Tests and the demo force Reduce Motion on or off; null follows Windows.
        public static bool? ReduceMotionOverride { get; set; }

        /// "Show animations in Windows" off (Settings › Accessibility › Visual effects).
        public static bool ReduceMotion => ReduceMotionOverride ?? !SystemParameters.ClientAreaAnimation;

        public static readonly MotionSpec Reduced = MotionSpec.EaseInOut(0.2);

        // The shape settles without a visible overshoot: every shape spring is damped
        // high (owner, 2026-09-27: the old open bounced once the card got wider and
        // taller). Closing uses the same curves, `closeShare` of the response.
        public const double WidthResponse = 0.42;
        public const double HeightResponse = 0.48;
        public const double ShapeDamping = 0.9;
        public const double RetargetResponse = 0.4;
        public const double RetargetDamping = 0.94;
        /// Closing runs this share of the opening response (30% faster).
        public const double CloseShare = 0.7;
        /// Opening: width leads.
        public static MotionSpec Width => ReduceMotion ? Reduced : MotionSpec.Spring(WidthResponse, ShapeDamping);
        /// Opening: height follows.
        public static MotionSpec Height => ReduceMotion ? Reduced : MotionSpec.Spring(HeightResponse, ShapeDamping);
        /// Closing runs backwards, faster.
        public static MotionSpec CloseWidth => ReduceMotion ? Reduced : MotionSpec.Spring(WidthResponse * CloseShare, ShapeDamping);
        public static MotionSpec CloseHeight => ReduceMotion ? Reduced : MotionSpec.Spring(HeightResponse * CloseShare, ShapeDamping);
        /// Same state, new size (another tool, a request's diff): one spring, no axis sequencing.
        public static MotionSpec PanelRetarget => ReduceMotion ? Reduced : MotionSpec.Spring(RetargetResponse, RetargetDamping);
        /// Gap between the leading axis and the following axis.
        public const double AxisDelay = 0.06;

        public const double ContentFadeDelay = 0.12;
        public const double ContentFadeDuration = 0.2;
        public const double ContentOutDuration = 0.08;
        /// Content fades in and rises this far; no blur anywhere.
        public const double ContentRise = 10;
        /// Card rows follow each other by this much.
        public const double RowStagger = 0.04;
        /// Rows past this index share its delay, so a long list lands within half a second.
        public const int RowStaggerCap = 8;
        public static MotionSpec ContentIn => MotionSpec.EaseOut(ContentFadeDuration).WithDelay(ContentFadeDelay);
        public static MotionSpec ContentOut => MotionSpec.EaseIn(ContentOutDuration);
        public static MotionSpec RowIn(int index) =>
            MotionSpec.EaseOut(ContentFadeDuration).WithDelay(ContentFadeDelay + RowStagger * index);
        /// Opacity plus a rise of `dy` coming in (opacity only for `dy == 0` or under Reduce
        /// Motion), opacity going out. The one shape every content transition takes.
        public static TransitionSpec Rise(double dy, MotionSpec @in, MotionSpec @out) => new()
        {
            In = @in,
            Out = @out,
            InDy = dy != 0 && !ReduceMotion ? dy : 0,
        };
        /// Opacity plus a slide of `dx` on both sides, in and out (opacity only for `dx == 0` or
        /// under Reduce Motion). `rise`'s sibling on the x axis.
        public static TransitionSpec Slide(double dx, MotionSpec @in, MotionSpec @out)
        {
            if (dx == 0 || ReduceMotion) return Rise(0, @in, @out);
            return new() { In = @in, Out = @out, InDx = dx, OutDx = dx };
        }
        /// Content in: opacity plus the rise. `rise: false` for content whose rows rise on
        /// their own (the card).
        public static TransitionSpec ContentTransition(bool rise) =>
            Rise(rise ? ContentRise : 0, ContentIn, ContentOut);

        // The strip unfolds from behind the camera: each segment starts `unfoldDistance`
        // toward the centre and transparent, then glides out (critically damped, no
        // overshoot), `unfoldStagger` after the one nearer the camera.
        public const double UnfoldDistance = 16;
        public const double UnfoldStagger = 0.03;
        public const double UnfoldDuration = 0.28;
        public const double UnfoldDelay = 0.10;
        public static MotionSpec Unfold(int index) =>
            ReduceMotion
                ? Reduced.WithDelay(UnfoldDelay)
                : MotionSpec.Spring(UnfoldDuration, 1).WithDelay(UnfoldDelay + UnfoldStagger * index);

        // Segments: hover lift, press depress, selection glide.
        public static readonly MotionSpec HoverLift = MotionSpec.EaseOut(0.15);
        public const double PressDuration = 0.12;
        public const double PressScale = 0.94;
        public static MotionSpec Press => MotionSpec.EaseOut(PressDuration);
        public static MotionSpec ToolSelect => ReduceMotion ? Reduced : MotionSpec.Spring(0.3, 0.88);
        /// Allow pops in (start → overshoot → 1) when it arrives, after the unfold delay.
        public const double ActionPopStart = 0.92;
        public const double ActionPopOvershoot = 1.08;
        public const double ActionPopDuration = 0.34;
        /// Share of the pop spent rising to the overshoot.
        public const double ActionPopRiseShare = 0.55;
        public static MotionSpec ActionPopRise =>
            MotionSpec.EaseOut(ActionPopDuration * ActionPopRiseShare).WithDelay(UnfoldDelay);
        public static MotionSpec ActionPopSettle =>
            MotionSpec.Spring(ActionPopDuration * (1 - ActionPopRiseShare), 0.8);

        // Tool name caption: shows after the mouse rests this long on a tool, follows it to
        // the next tool at once, lingers briefly on leaving (so the gap between tools does
        // not blink it), and holds this long after ⇥ or 1–4.
        public const double ToolLabelDelay = 0.15;
        public const double ToolLabelLinger = 0.08;
        public const double ToolLabelKeyboardHold = 1.2;
        public const double ToolLabelFadeDuration = 0.12;
        /// Reduce Motion: null, the caption appears and moves without a fade or glide.
        public static MotionSpec? ToolLabelFade => ReduceMotion ? null : MotionSpec.EaseOut(ToolLabelFadeDuration);

        // Hover: the rim light, the resting name brightening, and the collapsed strip's
        // tools crossfading in all use one pair. The rim waits `rimDelay` first.
        public const double RimDelay = 0.25;
        public static MotionSpec HoverIn => MotionSpec.EaseOut(0.18);
        public static MotionSpec HoverOut => MotionSpec.EaseIn(0.25);

        // Attention arrival: the clay bleed (no breath: the shape growing is the signal).
        public const double BleedInDuration = 0.3;
        /// The bleed has settled to its resting opacity by this long after arrival.
        public const double BleedSettledAt = 1;
        public static MotionSpec BleedIn => MotionSpec.EaseOut(BleedInDuration);
        public static MotionSpec BleedSettle => MotionSpec.EaseInOut(BleedSettledAt - BleedInDuration);

        // Tabs.
        public const double TabInDuration = 0.32;
        public const double TabOutDuration = 0.2;
        public static MotionSpec TabIn => MotionSpec.EaseOut(TabInDuration);
        public static MotionSpec TabOut => MotionSpec.EaseOut(TabOutDuration);
        /// Inset groups inside a sliding pane move by this share of the pane's offset, on top of it.
        public const double TabParallax = 0.4;
        /// The pane slides this far toward its new anchor, not the whole width: it re-anchors, it does not page.
        public const double PaneSlide = 48;
        /// A pane sliding by `dx` while it fades, its inset groups a little further (parallax).
        /// (SwiftUI took the curve from the enclosing transaction: `tabIn` in, `tabOut` out.)
        public static TransitionSpec Slide(double dx) => new()
        {
            In = TabIn,
            Out = TabOut,
            InDx = dx,
            OutDx = dx,
            Parallax = true,
        };
        /// Usage bars fill after the pane has landed.
        public const double BarFillDuration = 0.5;
        public static MotionSpec BarFill => MotionSpec.EaseOut(BarFillDuration).WithDelay(TabInDuration);

        // Done peek.
        public const double CheckDelay = 0.15;
        public const double CheckPopDuration = 0.3;
        public const double CheckPopOvershoot = 1.15;
        /// Share of the pop spent rising to the overshoot; the rest springs back to 1.
        public const double CheckPopRiseShare = 0.6;
        public const double CheckDrawDuration = 0.35;
        public const double CountDelay = 0.25;
        public const double CountDuration = 0.6;
        public static MotionSpec CheckPopRise => MotionSpec.EaseOut(CheckPopDuration * CheckPopRiseShare);
        public static MotionSpec CheckPopSettle =>
            MotionSpec.Spring(CheckPopDuration * (1 - CheckPopRiseShare), 0.8);
        public static MotionSpec CheckDraw => MotionSpec.EaseOut(CheckDrawDuration).WithDelay(CheckDelay);
        public static MotionSpec CountUp => MotionSpec.EaseOut(CountDuration).WithDelay(CountDelay);

        // Teleport fold: height collapses, then the width settles; the terminal comes up part way.
        public const double FoldHeightDuration = 0.28;
        public static MotionSpec FoldHeight => MotionSpec.EaseIn(FoldHeightDuration);
        public static MotionSpec FoldWidth => MotionSpec.Spring(0.3, 0.6).WithDelay(FoldHeightDuration);
        public const double TeleportActivateAt = 0.15;
        /// The fold flag clears after this long.
        public const double FoldTotal = 0.9;

        public static readonly MotionSpec Tap = MotionSpec.EaseOut(0.12);

        // A request card's diff: the card grows with the same springs as the shape
        // (height follows after the axis delay), and the diff rises in.
        public static MotionSpec RequestDiff(bool expanding) =>
            expanding ? Height.WithDelay(AxisDelay) : CloseHeight;
        public const double RequestDiffRevealDuration = 0.2;
        /// Opacity plus the content rise; Reduce Motion crossfades.
        public static TransitionSpec RequestDiffTransition =>
            Rise(ContentRise, MotionSpec.EaseOut(RequestDiffRevealDuration), ContentOut);

        // Git branch picker: the target pill morphs into the repository pill in place, the
        // rest of the header slides right, the panes drop away, the picker's header rises and
        // its rows rise one by one (`RiseIn`, capped). Closing is a plain fade and the reverse.
        public const double PickerPillResponse = 0.32;
        public const double PickerPillDamping = 0.86;
        /// The pill's frame and crossfade.
        public static MotionSpec PickerPill =>
            ReduceMotion ? Reduced : MotionSpec.Spring(PickerPillResponse, PickerPillDamping);
        /// The picker and the content trading places.
        public static MotionSpec PickerSwap => PickerPill;
        /// The branch, status and Push slide this far right on the way out and back from there.
        public const double PickerHeaderShift = 12;
        /// The list and diff drop this far as they fade.
        public const double PickerPaneDrop = 6;
        public static TransitionSpec PickerHeaderTransition =>
            ReduceMotion
                ? Rise(0, Reduced, Reduced)
                : Slide(PickerHeaderShift, ContentIn, ContentOut);
        /// The panes: out with a drop, back with the content rise.
        public static TransitionSpec PickerPanesTransition => PaneSwapTransition;
        /// Content trading places in a pane: out with a 6 pt drop and a 0.08 s fade, in with
        /// the content rise at 120 ms. The picker's panes, the Git diff pane's content and its
        /// push confirm. Reduce Motion: a 0.2 s crossfade.
        public static TransitionSpec PaneSwapTransition
        {
            get
            {
                if (ReduceMotion) return Rise(0, Reduced, Reduced);
                return new() { In = ContentIn, InDy = ContentRise, Out = ContentOut, OutDy = PickerPaneDrop };
            }
        }
        /// The picker's header and filter: the content rise in, a fade out.
        public static TransitionSpec PickerHeadTransition =>
            ReduceMotion ? Rise(0, Reduced, Reduced) : ContentTransition(rise: true);
        // Git stage (Direction F): the stage swaps between the diff, the commit form and the
        // confirm, its content dropping away and the next rising in (`paneSwapTransition`),
        // while the dock's summary box travels from the rail's foot to the top of the form
        // (`matchedGeometryEffect`). The sync pill stays in the header for the confirm. Swap
        // and travel run together on the picker pill's spring.
        public static MotionSpec StageSwap => PickerPill;
        /// The dock's field travelling into the stage and back: the same spring as every
        /// stage swap, so the box and the content it replaces arrive together.
        public static MotionSpec DockTravel => StageSwap;
        /// What travels (the dock's box), both ends: the arriving copy is
        /// whole from the first frame, the departing one gone within `travelDepartShare` of
        /// the spring (about 50 ms), so one box glides. Never `.identity`: that removes the
        /// departing copy at once and the box jumps.
        public const double TravelDepartShare = 0.25;
        public static TransitionSpec TravelTransition => new()
        {
            In = DockTravel,
            InFade = false,
            Out = DockTravel,
            OutFadeShare = TravelDepartShare,
        };
        /// P: the question rises in once the diff has dropped away, the "⏎ or Push again" hint
        /// and Cancel after it, while the header's pill pops in place.
        public const double ConfirmQuestionDelay = 0.12;
        public const double ConfirmCancelDelay = 0.18;
        public static TransitionSpec ConfirmRise(double delay)
        {
            if (ReduceMotion) return Rise(0, Reduced, Reduced);
            return new()
            {
                In = MotionSpec.EaseOut(ContentFadeDuration).WithDelay(delay),
                InDy = ContentRise,
                Out = ContentOut,
                OutDy = PickerPaneDrop,
            };
        }
        /// The form's parts wait for the summary box to land (its spring is about 0.32 s): the
        /// description (`index` 0), the co-author row (1), the bottom row (2), then rise.
        public static readonly IReadOnlyList<double> StageRiseDelays = new[] { 0.18, 0.22, 0.26 };
        /// The form's parts after the summary box, on `stageRiseDelays`; out at once with the
        /// pane swap's drop, so esc feels instant.
        public static TransitionSpec StageRise(int index)
        {
            if (ReduceMotion) return Rise(0, Reduced, Reduced);
            double delay = StageRiseDelays[Math.Min(Math.Max(index, 0), StageRiseDelays.Count - 1)];
            return new()
            {
                In = MotionSpec.EaseOut(ContentFadeDuration).WithDelay(delay),
                InDy = ContentRise,
                Out = ContentOut,
                OutDy = PickerPaneDrop,
            };
        }
        /// A rail row leaving (a commit took it) or coming back (an undo): its 20 pt height
        /// to 0 and a fade on the picker pill's spring, 40 ms apart, capped at 8; leaving top
        /// down (`outIndex`), coming back bottom up (`inIndex`).
        public static TransitionSpec RailRowCollapse(int outIndex, int inIndex)
        {
            if (ReduceMotion) return new() { In = Reduced, Out = Reduced, CollapseHeight = Size.TreeRowHeight };
            MotionSpec Staggered(int index) => PickerPill.WithDelay(RowStagger * Math.Min(index, RowStaggerCap));
            return new() { In = Staggered(inIndex), Out = Staggered(outIndex), CollapseHeight = Size.TreeRowHeight };
        }
        /// The rows closing the gap a leaving row left.
        public static MotionSpec RailRows => PickerPill;
        /// ⌘B: the rail springs between its width and the checkbox column; names and cells fade.
        public static MotionSpec RailFold => PickerPill;
        public const double RailFadeDuration = 0.08;
        public static MotionSpec RailFade => ReduceMotion ? Reduced : MotionSpec.EaseOut(RailFadeDuration);
        /// A checkbox ticking: the check draws itself as a stroke.
        public const double CheckStrokeDuration = 0.09;
        public static MotionSpec CheckStroke => ReduceMotion ? Reduced : MotionSpec.EaseOut(CheckStrokeDuration);
        /// Unticking: the box's fill shrinks to `Size.gitUntickScale` and fades.
        public const double CheckUntickDuration = 0.08;
        public static MotionSpec CheckUntick => ReduceMotion ? Reduced : MotionSpec.EaseIn(CheckUntickDuration);
        /// The row's name and cells dimming or coming back as its box changes.
        public const double CheckDimDuration = 0.12;
        public static MotionSpec CheckDim => ReduceMotion ? Reduced : MotionSpec.EaseInOut(CheckDimDuration);
        /// The header's box ticks every row, this far apart top down, capped at `rowStaggerCap`.
        public const double CheckStagger = 0.02;
        /// How long a header tick keeps the rows staggered.
        public const double CheckStaggerWindow = 0.3;
        /// One horizontal shake (a failed sync's pill, an invalid co-author): ±3 pt, two
        /// half-cycles of 60 ms. Reduce Motion: none.
        public const double PillShakeDistance = 3;
        public const double PillShakeHalf = 0.06;
        public static MotionSpec PillShake => MotionSpec.EaseInOut(PillShakeHalf);
        /// A count changing (the rail header's, the sync pill's): the digits roll
        /// (`.numericText()`) and the pill pops (`PopIn`'s curve, without its delay).
        public static MotionSpec CountPop => ReduceMotion ? Reduced : MotionSpec.Spring(PickerPillResponse, PickerPillDamping);
        public static MotionSpec CountPopRise => ReduceMotion ? Reduced : MotionSpec.EaseOut(ActionPopDuration * ActionPopRiseShare);
        /// The rows' block: nothing coming in (each row rises on its own), a fade going out.
        public static TransitionSpec PickerRowsTransition => new() { In = null, Out = ReduceMotion ? Reduced : ContentOut };

        // Files tab.
        /// Folder disclosure: the chevron turns and the children rise in, one `rowStagger` apart.
        public const double DisclosureDuration = 0.2;
        /// Reduce Motion: null, the chevron snaps (the rows still crossfade).
        public static MotionSpec? Disclosure => ReduceMotion ? null : MotionSpec.EaseOut(DisclosureDuration);
        public static MotionSpec ChildIn(int index)
        {
            double stagger = RowStagger * Math.Min(index, Limits.MaxStaggeredChildren);
            return ReduceMotion ? Reduced : MotionSpec.EaseOut(DisclosureDuration).WithDelay(stagger);
        }
        /// Tree rows entering or leaving: opacity plus the content rise, downward from their
        /// folder (opacity only under Reduce Motion).
        public static TransitionSpec ChildTransition(int index) =>
            Rise(-ContentRise, ChildIn(index), MotionSpec.EaseOut(DisclosureDuration));
        /// The preview pane crossfades between files.
        public const double PreviewFadeDuration = 0.2;
        public static MotionSpec PreviewFade => MotionSpec.EaseInOut(PreviewFadeDuration);
        /// Rows leaving and joining as the filter changes.
        public static MotionSpec FilterRows => ReduceMotion ? Reduced : MotionSpec.EaseOut(DisclosureDuration);
        public const double ChevronOpenDegrees = 90;
        // Changes tool (Direction G, Timeline).
        /// The live node's halo: scale 1 → `Size.changesHaloScale`, opacity to 0, 1.6 s,
        /// repeating. Reduce Motion: null, a static halo.
        public const double ChangesBreathDuration = 1.6;
        public static MotionSpec? ChangesBreath =>
            ReduceMotion ? null : MotionSpec.EaseInOut(ChangesBreathDuration).Repeating(autoreverses: false);
        /// The column's width (the pane opening, esc, ⌘B), entries sliding to make room or
        /// close a gap, the cursor ring gliding between chips: the picker pill's spring.
        public static MotionSpec ChangesLayout => PickerPill;
        /// A timeline row (an entry, a quiet group, an unfolded quiet turn) coming or going:
        /// in with the content rise, out with the pane swap's drop, `index` × 40 ms apart
        /// (capped at 8). Reduce Motion: a crossfade.
        public static TransitionSpec ChangesRowTransition(int index)
        {
            if (ReduceMotion) return Rise(0, Reduced, Reduced);
            double stagger = RowStagger * Math.Min(index, RowStaggerCap);
            return new()
            {
                In = MotionSpec.EaseOut(ContentFadeDuration).WithDelay(stagger),
                InDy = ContentRise,
                Out = ContentOut.WithDelay(stagger),
                OutDy = PickerPaneDrop,
            };
        }
        /// A chip landing in a turn: from `actionPopStart` and transparent, on the count pop's spring.
        public static TransitionSpec ChangesChipTransition
        {
            get
            {
                if (ReduceMotion) return TransitionSpec.Opacity(Reduced, Reduced);
                return new() { In = CountPop, Out = CountPop, InScale = ActionPopStart, OutScale = ActionPopStart };
            }
        }
        /// The diff pane: its header rises at `contentFadeDelay`, the diff one `rowStagger`
        /// later (`RiseIn` 0 and 1); esc drops it 6 pt and fades it in 0.08 s.
        public static TransitionSpec ChangesPaneTransition
        {
            get
            {
                if (ReduceMotion) return TransitionSpec.Opacity(Reduced, Reduced);
                return new() { In = null, Out = ContentOut, OutDy = PickerPaneDrop };
            }
        }
        /// A chip's hover fill, and the cursor turning from a chip's ring to a row's fill.
        public const double ChangesHoverDuration = 0.12;
        public static MotionSpec ChangesHover => ReduceMotion ? Reduced : MotionSpec.EaseOut(ChangesHoverDuration);

        /// ⌘B: the tree folds away or comes back with the same spring as a same-state resize.
        public static MotionSpec TreeCollapse => PanelRetarget;
        public const double RingStartDegrees = -90;

        public const double PulseDuration = 1.4;
        public const double PulseScale = 1.9;
        public const double PulseStartScale = 1.0;
        public static MotionSpec Pulse => MotionSpec.EaseOut(PulseDuration).Repeating(autoreverses: false);

        public const double BreatheDuration = 1.6;
        public static MotionSpec Breathe => MotionSpec.EaseInOut(BreatheDuration).Repeating(autoreverses: true);
    }

    // MARK: - Timing (product timeouts and windows, not animation)

    public static partial class Timing
    {
        /// A blocking request waits this long; the pipe replies "none" at the same moment.
        public const double PermissionDeadline = 58;
        /// A plan waits this long (reading takes longer); the hook waits 299 s, its entry's timeout is 305 s.
        public const double PlanDeadline = 298;
        /// The deadline of a blocking request: a plan's, or every other request's.
        public static double ReplyDeadline(bool plan) => plan ? PlanDeadline : PermissionDeadline;
        /// After a new request arrives, ⏎ / ⌫ / A / E are ignored this long (typing in the
        /// terminal must not answer it). Clicks are never delayed.
        public const double RequestKeyGuard = 0.4;
        /// A session that got a hook envelope this recently is driven by hooks; the transcript
        /// watcher does not override its state.
        public const double HookDrivenWindow = 10 * 60;
        /// Sessions with no activity for this long leave the list.
        public const double SessionIdleCutoff = 2 * 3600;
        /// A session counts as live (keeps the wings up) when active this recently.
        public const double LiveSessionWindow = 10 * 60;
        /// A hook agent and a transcript agent of the same type starting this close together are the same agent.
        public const double AgentMatchWindow = 15;
        /// `.needsYou` without a pending request lasts at most this long.
        public const double NeedsYouLifetime = 90;
        /// Transcript writes this soon after a needs-you notification belong to it, not to new activity.
        public const double NeedsYouActivityGrace = 2;
        /// Limits reported this recently read "updated 3m ago"; older ones "as of 2:14 PM".
        public const double LimitsRelativeWindow = 3600;
        /// The Usage footer's "updated 3m ago" refreshes this often.
        public const double LimitsFootnoteTick = 30;
        /// A reset closer than this reads "resets in 1h 52m"; further out, "resets Thu 3:40 PM".
        public const double ResetRelativeWindow = 24 * 3600;
        /// A transcript turn that started this long before the hook's prompt still counts as that turn.
        public const double TurnMatchSlack = 5;
        /// Default peek length; the owner sets the real one in Settings.
        public const double PeekLifetime = 4;
        public static readonly (double Min, double Max) PeekSecondsRange = (2, 8);
        public const double PeekSecondsStep = 1;
        /// Inline hints ("No terminal found", "Copied") show this long.
        public const double HintDuration = 2;
        /// Hover to open: rest this long on the shape to open, leave the card this long to close.
        public const double HoverOpenDelay = 0.25;
        public const double HoverCloseDelay = 0.40;
        /// Clocks and countdowns (and every Reduce Motion countdown) step this often.
        public const double ClockTick = 1;
        /// The Git tool re-reads the worktree this often while it shows.
        public const double GitRefreshInterval = 5;
        /// "Pushed 3 commits", "Committed 3 files" stay this long, then the tool re-reads.
        public const double GitResultHold = 3;
        /// A read command (status, diff, log), a push or pull, a fetch, or a commit (its hooks
        /// may run) is stopped after this long.
        public const double GitReadTimeout = 10;
        public const double GitSyncTimeout = 90;
        public const double GitFetchTimeout = 30;
        public const double GitCommitTimeout = 60;
        /// The tool fetches the target's remote quietly when it opens, at most this often.
        public const double GitAutoFetchInterval = 300;
        /// After a timed-out process (git, claude) is asked to stop, this long before it is killed.
        public const double ProcessKillGrace = 2;
        /// Plan usage (`claude -p /usage`) runs this often while Settings allows it.
        public const double PlanUsageInterval = 900;
        /// Plan usage younger than this is not refreshed unless forced (R).
        public const double PlanUsageStaleAfter = 300;
        /// A `claude -p /usage` run is stopped after this long.
        public const double PlanUsageTimeout = 20;
        /// The first plan usage run waits this long after launch.
        public const double PlanUsageLaunchDelay = 5;
        /// Looking up where `claude` is gives up after this long.
        public const double ClaudeLookupTimeout = 5;
        /// Shell changes kept on disk per session (they survive a relaunch) are dropped after this long unused.
        public const double ShellChangesKeep = 7 * 24 * 3600;
    }

    // MARK: - Limits (counts)

    public static partial class Limits
    {
        /// Diff lines kept per file (FileChange.patch), from transcripts, hooks and git alike.
        public const int PatchLines = 400;
        /// The commit card lists at most this many files, then "N more".
        public const int CommitMaxFileRows = 5;
        /// The permission card lists at most this many of the rules Always would add, then "+N more".
        public const int AlwaysRuleLines = 3;
        /// File previews kept in memory for flipping back and forth.
        public const int MaxCachedPreviews = 8;
        /// A snippet shorter than this opens inline by default.
        public const int InlineSnippetMaxLines = 8;
        public const int DiffCellCount = 5;
        /// ↑↓ move a request card's diff by this many lines.
        public const int RequestDiffScrollLines = 4;
        /// A plan card renders at most this many lines of the plan, then "… N more lines".
        public const int PlanMaxLines = 600;
        /// ↑↓ move a plan card's Markdown by this many blocks.
        public const int PlanScrollBlocks = 2;
        /// A plan read from its file (`planFilePath`) when the hook sent no text.
        public const int PlanFileBytes = 1024 * 1024;
        public const int MaxQuestionOptions = 3;
        /// Children beyond this index rise in together, so a big folder never trickles in.
        public const int MaxStaggeredChildren = 12;
        public const int MaxStatusAgents = 3;
        /// The Git tool: commits read per snapshot (only the newest is used: undo and the dock's
        /// receipt need its sha and whether it is pushed), untracked files diffed, bytes read per command.
        public const int GitRecentCommits = 1;
        public const int GitUntrackedDiffs = 20;
        public const int GitOutputBytes = 2_000_000;
        /// The branch picker lists this many local branches, newest commit first (and every
        /// checked-out one besides); its filter field appears past this many rows.
        public const int GitPickerBranches = 30;
        public const int GitPickerFilterMin = 8;
        /// Files whose length is counted for the minimap, per read.
        public const int GitLineCountFiles = 60;
        /// The commit summary shows its length past the first and turns red past the second.
        public const int GitSummaryIdeal = 50;
        public const int GitSummaryMax = 72;
        /// "Undid "…"" keeps this many characters of the subject.
        public const int GitUndoSubject = 40;
        /// A commit hook's line in "A commit hook said no · …" keeps this many characters.
        public const int GitHookLine = 80;
        /// Co-author suggestions: the "recent" row shows this many, from this many distinct
        /// names found in the trailers of the last `gitCoauthorLog` commits.
        public const int GitCoauthorSuggestions = 6;
        public const int GitCoauthorHistory = 12;
        public const int GitCoauthorLog = 100;
        /// The Git footer adds "⇥ next tool" only while it has at most this many hints.
        public const int GitFooterHints = 5;
        /// Word highlights skip a line pair with more tokens than this on either side.
        public const int WordDiffMaxTokens = 200;
        /// The Changes pane counts a file's lines on disk (for the minimap) up to this size.
        public const int ChangesLineCountBytes = 4 * 1024 * 1024;
        /// A limit bar turns clay at this percent.
        public const double LimitWarnPercent = 90;
        /// The plan usage run's transcript starts over (a new session id) past this size.
        public const int PlanUsageTranscriptBytes = 1_000_000;
    }

    // MARK: - Fonts (Segoe UI Variable and Cascadia Mono, tabular numerals)

    public static partial class Fonts
    {
        /// Text: Segoe UI Variable Text (Windows 11), else Segoe UI. SF Pro's stand-in.
        public static readonly FontFamily TextFamily = new("Segoe UI Variable Text, Segoe UI");
        /// Code and paths: Cascadia Mono (Windows 11), else Consolas. SF Mono's stand-in.
        public static readonly FontFamily MonoFamily = new("Cascadia Mono, Consolas");

        public const double CaptionSize = 12;
        public const double BodySize = 13;
        public const double TitleSize = 16;
        public const double HeroSize = 19;
        public const double KeycapSize = 11;
        public const double MonoSmallSize = 11;
        public const double BigNumberSize = 26;
        public const double TinySize = 10;
        public const double ChevronSize = 9;
        public const double TreeChevronSize = 8;
        public const double ToolBadgeSize = 8.5;
        public const double ActionSize = 12;

        public static readonly FontSpec Caption = Text(CaptionSize, FontWeights.Normal, tabular: true);
        public static readonly FontSpec CaptionMedium = Text(CaptionSize, FontWeights.Medium, tabular: true);
        public static readonly FontSpec CaptionSemibold = Text(CaptionSize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec Body = Text(BodySize, FontWeights.Normal, tabular: true);
        public static readonly FontSpec BodyMedium = Text(BodySize, FontWeights.Medium, tabular: true);
        public static readonly FontSpec BodySemibold = Text(BodySize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec Title = Text(TitleSize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec Hero = Text(HeroSize, FontWeights.SemiBold, tabular: true) with { Tracking = HeroTracking };
        /// Points; WPF has no tracking on a TextBlock, so views that honour it apply it themselves.
        public const double HeroTracking = -0.5;
        public static readonly FontSpec BigNumber = Text(BigNumberSize, FontWeights.SemiBold, tabular: true);

        public static readonly FontSpec Mono = MonoFont(BodySize);
        public static readonly FontSpec MonoCaption = MonoFont(CaptionSize);
        public static readonly FontSpec MonoSmall = MonoFont(MonoSmallSize);
        /// One character of `monoSmall`, for the width of a line that never wraps.
        public static double MonoSmallAdvance => monoSmallAdvance.Value;
        private static readonly Lazy<double> monoSmallAdvance = new(() => MonoSmall.Measure("0"));

        public static readonly FontSpec Tiny = Text(TinySize, FontWeights.Normal, tabular: true);

        public static readonly FontSpec Keycap = Text(KeycapSize, FontWeights.Medium, tabular: true);
        public static readonly FontSpec Chevron = Text(ChevronSize, FontWeights.SemiBold);
        public static readonly FontSpec TreeChevron = Text(TreeChevronSize, FontWeights.SemiBold);
        public static readonly FontSpec Badge = MonoFont(TinySize);
        public static readonly FontSpec GroupHeader = Text(CaptionSize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec ToolBadge = Text(ToolBadgeSize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec Action = Text(ActionSize, FontWeights.SemiBold, tabular: true);
        public static readonly FontSpec ToolLabel = Text(TinySize, FontWeights.Medium);

        public static FontSpec Symbol(double size) => Text(size, FontWeights.SemiBold);

        private static FontSpec Text(double size, FontWeight weight, bool tabular = false) =>
            new(TextFamily, size, weight, tabular);
        private static FontSpec MonoFont(double size) => new(MonoFamily, size, FontWeights.Normal, false);
    }

    // MARK: - Symbols (SF Symbols on macOS; drawn geometry here, see Glyphs.cs)

    public static partial class Symbols
    {
        /// "sparkle".
        public static GlyphSpec Claude => GlyphShapes.Sparkle;
        /// "exclamationmark.triangle.fill".
        public static GlyphSpec Attention => GlyphShapes.AttentionTriangle;
        /// "questionmark".
        public static GlyphSpec Question => GlyphShapes.QuestionMark;
        /// "checkmark".
        public static GlyphSpec Done => GlyphShapes.Checkmark;
        /// "arrow.up.right".
        public static GlyphSpec Teleport => GlyphShapes.ArrowUpRight;
        /// "chevron.right".
        public static GlyphSpec Chevron => GlyphShapes.ChevronRight;
        /// "plusminus".
        public static GlyphSpec Diff => GlyphShapes.PlusMinus;
        /// "chevron.left".
        public static GlyphSpec Back => GlyphShapes.ChevronLeft;
        /// "line.3.horizontal.decrease".
        public static GlyphSpec Filter => GlyphShapes.FilterLines;
        /// The Files tool's collapse-the-tree pill ("sidebar.left").
        public static GlyphSpec Sidebar => GlyphShapes.SidebarLeft;

        // The Git tool (the strip's own icons are drawn: ToolShapes in Glyphs.cs).
        /// Before "worktree seadevil" on a branch picker row ("macwindow").
        public static GlyphSpec GitWorktree => GlyphShapes.Window;
        /// The dock's field, before the summary or its prompt ("pencil.line").
        public static GlyphSpec GitPen => GlyphShapes.PencilLine;
    }

    // MARK: - Key labels for keycaps (⌘ is Ctrl and ⌥ is Alt on Windows)

    public static partial class Keys
    {
        public const string Enter = "⏎";
        public const string Delete = "⌫";
        public const string Option = "Alt";
        public const string Space = "space";
        public const string Tab = "⇥";
        public const string Escape = "esc";
        public const string Always = "A";
        public const string Edit = "E";
        public const string Settings = "Ctrl ,";
        public const string Quit = "Ctrl Q";
        public const string Copy = "Y";
        public const string Diff = "D";
        public const string OptionEnter = "Alt ⏎";
        public const string Up = "↑";
        public const string Down = "↓";
        public const string Left = "←";
        public const string Right = "→";
        public const string Slash = "/";
        public const string Plus = "+";
        /// Files: collapse or bring back the tree.
        public const string ToggleTree = "Ctrl B";
        /// Files: a Markdown file's Preview · Code switch.
        public const string MarkdownMode = "P";
        /// Git: the sync pill (publish, pull, push, fetch); the first three ask first.
        public const string Push = "P";
        /// Git: open the commit form.
        public const string Commit = "C";
        /// Git: undo the newest unpushed commit.
        public const string Undo = "U";
        /// Git: put the cursor's file in or out of the commit.
        public const string Toggle = Space;
        /// Git: commit from the description.
        public const string CommandEnter = "Ctrl ⏎";
        /// Git: the commit form's co-author pill (a label, no key).
        public const string Coauthor = "@";
        /// Git: the branch picker.
        public const string Worktree = "W";
        /// Git: the picker's repository dropdown.
        public const string Repository = "R";
        /// Usage: run `claude -p /usage` now.
        public const string Refresh = "R";
    }

    // MARK: - Glyph characters used in text

    public static partial class Glyphs
    {
        public const string Minus = "−";
        public const string Separator = " · ";
        public const string Approx = "≈ ";
        public const string Ellipsis = "…";
        /// After the Git tool's pills: "notchcode › seadevil ▾".
        public const string PickerChevron = "▾";
        /// Between the repository and the place in the Git target pill.
        public const string PathChevron = "›";
        /// "↑3", "↑2 of main": commits ahead.
        public const string Ahead = "↑";
        // A diff line's prefix.
        public const string DiffAdded = "+";
        public const string DiffRemoved = Minus;
        public const string DiffContext = " ";
        /// "~$1.42": an estimated cost.
        public const string Estimate = "~";
        public const string EmDash = "—";
        /// A Markdown bullet list item's marker.
        public const string Bullet = "•";
        /// After a Changes file row's name when a Bash command changed the file.
        public const string ShellTag = "shell";
        /// Removes a Git co-author chip.
        public const string Remove = "×";
    }

    // MARK: - Drawn glyphs

    public static partial class Shapes
    {
        /// The done check, as points in a unit square (short leg, then long leg).
        public static readonly IReadOnlyList<Point> Check = new[]
        {
            new Point(0.0, 0.55),
            new Point(0.36, 0.9),
            new Point(1.0, 0.12),
        };
    }
}

/// A font: family, size, weight, tabular numerals (SwiftUI's `.monospacedDigit()`), and
/// tracking in points (only the hero number has any).
public sealed record FontSpec(FontFamily Family, double Size, FontWeight Weight, bool Tabular, double Tracking = 0)
{
    public Typeface Typeface => new(Family, FontStyles.Normal, Weight, FontStretches.Normal);

    /// Sets the family, size, weight and numeral alignment on a TextBlock.
    public void Apply(TextBlock text)
    {
        text.FontFamily = Family;
        text.FontSize = Size;
        text.FontWeight = Weight;
        Typography.SetNumeralAlignment(text, Tabular ? FontNumeralAlignment.Tabular : FontNumeralAlignment.Normal);
    }

    /// The same on a control (a TextBox, a Button), inherited by its text.
    public void Apply(Control control)
    {
        control.FontFamily = Family;
        control.FontSize = Size;
        control.FontWeight = Weight;
        Typography.SetNumeralAlignment(control, Tabular ? FontNumeralAlignment.Tabular : FontNumeralAlignment.Normal);
    }

    /// The same on a run inside a TextBlock.
    public void Apply(TextElement element)
    {
        element.FontFamily = Family;
        element.FontSize = Size;
        element.FontWeight = Weight;
        Typography.SetNumeralAlignment(element, Tabular ? FontNumeralAlignment.Tabular : FontNumeralAlignment.Normal);
    }

    /// The width of `text` in this font, in DIPs.
    public double Measure(string text)
    {
        var formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Typeface, Size,
            System.Windows.Media.Brushes.Black, 1.0);
        return formatted.WidthIncludingTrailingWhitespace;
    }
}
