// Theme.Shell.cs
// Tokens the Windows shell needs that Theme.swift has no twin for: the window's mouse poll
// and topmost re-assert, the tray icon, the placeholder panes. Added by wave 1b; Theme.cs
// itself is never edited.

using System.Windows.Media;

namespace Notchcode.UI;

public static partial class Theme
{
    public static partial class Timing
    {
        /// The window reads the cursor this often to decide whether it takes the mouse (the
        /// macOS global mouse-moved monitor), and to start the hover dwell.
        public const double MousePoll = 1.0 / 60;
        /// Another topmost window (a game overlay, a video) can rise above the notch; it is
        /// put back on top this often.
        public const double TopmostReassert = 3;
        /// `--debug-keys`: the wait before the first name, and between names.
        public const double DebugKeysStart = 3;
        public const double DebugKeysGap = 1.2;
    }

    public static partial class Size
    {
        /// The tray icon, drawn at runtime: the large and the small icon, in pixels.
        public const int TrayIconLarge = 32;
        public const int TrayIconSmall = 16;
        /// The notch drawn inside the tray icon's box: its width and height as shares of the box.
        public const double TrayNotchWidthShare = 0.92;
        public const double TrayNotchHeightShare = 0.5;
        /// Its outline, so the black shape reads on a dark taskbar.
        public const double TrayNotchStroke = 1;
    }

    public static partial class Colors
    {
        /// The tray icon's outline around the black notch.
        public static readonly Color TrayNotchStroke = Ink.WithOpacity(0.55);
        /// A placeholder pane's caption (wave 1b, until the real panes land).
        public static readonly Color PlaceholderText = InkTertiary;
    }

    public static partial class Fonts
    {
        /// The key symbols inside a keycap (⏎ ⌫ ⇥ ↑ ↓ ← → ⌘ ⌥). Segoe UI Variable has only the
        /// arrows, and WPF's fallback draws the rest faint and small; Segoe UI Symbol has all
        /// of them. Two points larger than the keycap's letters and bold (simulated: the font has one weight),
        /// so its thin strokes read as SF Pro's symbols do on the Mac.
        public static readonly FontFamily KeySymbolFamily = new("Segoe UI Symbol");
        public const double KeycapSymbolSize = KeycapSize + 2;
        public static readonly FontSpec KeycapSymbol = new(KeySymbolFamily, KeycapSymbolSize, System.Windows.FontWeights.Bold, Tabular: false);

        /// Whether `c` is drawn with `KeycapSymbol` rather than the keycap's text font.
        public static bool IsKeySymbol(char c) => c is >= '←' and <= '⇿' or >= '⌀' and <= '⏿';
    }

    public static partial class Brushes
    {
        public static readonly SolidColorBrush TrayNotchStroke = Brush(Colors.TrayNotchStroke);
        public static readonly SolidColorBrush PlaceholderText = Brush(Colors.PlaceholderText);
        /// Fully transparent but hit-testable (WPF skips a null background when hit testing).
        public static readonly SolidColorBrush HitTarget = Brush(System.Windows.Media.Colors.Transparent);
    }
}
