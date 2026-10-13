// Theme.PanesB.cs
// Wave 1d's additions to the Theme (Theme.cs is never edited by a wave-1 agent): the few sizes
// the Git tool, the request cards and the diff views need on Windows that SF Symbols and
// AppKit gave the Swift app for free, plus the app's version for About.

namespace Notchcode.UI;

public static partial class Theme
{
    /// The version About shows when the assembly carries none of its own (the csproj sets no
    /// `<Version>` yet, so the SDK stamps "1.0.0"). Keep in step with the first Release.
    public const string AppVersion = "0.1.0";

    public static partial class Timing
    {
        /// The Welcome page's "Connected · start a Claude Code session" holds this long, then
        /// the card closes.
        public const double WelcomeConnectedHold = 2.5;
    }

    public static partial class Size
    {
        /// A drawn glyph standing in for an SF Symbol at `Fonts.tinySize` (the filter's lines,
        /// the Ctrl B pill's sidebar): SF Symbols draw a little larger than their point size.
        public const double TinySymbol = Fonts.TinySize + 2;
        /// The teleport link's arrow beside a caption (SF's arrow.up.right at the caption size).
        public const double CaptionSymbol = Fonts.CaptionSize - 2;
        /// A WPF TextBox insets its text this far on each side inside its template; the commit
        /// form's fields take it off so their text lines up with the prompts and the dock.
        public const double TextBoxInset = 2;
        /// `.contentTransition(.numericText())`: how far a rolling count's old and new text
        /// travel, as a share of the font size (the old rolls out as the new rolls in).
        public const double CountRollShare = 0.7;
    }
}
