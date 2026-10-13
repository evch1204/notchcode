// Theme.PanesA.cs
// Tokens the Sessions, Changes, Files and Usage panes need that Theme.swift does not name
// (wave 1c). Kept apart from Theme.cs so the ported file stays member for member; wave 2 may
// fold them in. Every value is from the root PLAN (Motion table) or a WPF-only stand-in for
// what SwiftUI did on its own (line heights).

using System.Windows.Media;

namespace Notchcode.UI;

public static partial class Theme
{
    public static partial class Colors
    {
        /// The running lane shimmer: an 8% white sweep (PLAN Motion, "Running lane shimmer").
        public static readonly Color LaneShimmer = Ink.WithOpacity(0.08);
    }

    public static partial class Brushes
    {
        public static readonly SolidColorBrush LaneShimmer = Brush(Colors.LaneShimmer);
    }

    public static partial class Size
    {
        /// The shimmer band's width as it sweeps across a running lane.
        public const double LaneShimmerWidth = 90;

        // SwiftUI sized a line from the font; WPF lines are set to these so a text block that
        // is cut after N lines (FadeText) cuts on a line boundary. 13 pt body in 16 pt lines.
        public const double BodyLineHeight = 16;
        public const double CaptionLineHeight = 15;
        /// The rendered Markdown's prose: the body size plus `markdownLineSpacing`.
        public const double MarkdownLineHeight = BodyLineHeight + MarkdownLineSpacing;

        // The Usage page's fixed rows hold their lines only at SF's tighter line heights;
        // Segoe UI's default leading is taller, so the Usage tiles set these.
        public const double UsageCaptionLineHeight = 14;
        public const double UsageValueLineHeight = 16;
        public const double UsageBigNumberLineHeight = 30;
        public const double UsageTinyLineHeight = 13;
    }

    public static partial class Motion
    {
        /// The running lane shimmer: one 8% white sweep every 2.4 s, linear, repeating.
        /// Reduce Motion: none (PLAN Motion table).
        public const double LaneShimmerDuration = 2.4;
        public static MotionSpec? LaneShimmer =>
            ReduceMotion ? null : MotionSpec.Linear(LaneShimmerDuration).Repeating(autoreverses: false);

        /// The session cursor's row fill gliding from row to row: the selection spring.
        public static MotionSpec SessionCursor => ToolSelect;
    }
}
