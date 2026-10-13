// ReviewerDiff.cs
// Port of Sources/notchcode/UI/Diff/ReviewerDiff.swift.
// The reviewer diff shared by the Git tool's stage and the Changes tool's diff pane: every
// line whole (it scrolls sideways), both line numbers, changed words tinted, hunk headers in
// blue, the minimap down the right edge. And the M / A / D badge their headers put after a
// file's name.

using System.Windows;
using System.Windows.Controls;
using Notchcode.UI;

namespace Notchcode.UI.Diff;

/// The reviewer diff, in the Git tool's stage and the Changes tool's pane alike: every line
/// whole (the pane scrolls sideways as the Files preview does), both line numbers, the
/// changed words tinted, the minimap on the right edge outside the scrolling content. Tracks
/// the top row for the minimap's visible range; a minimap press scrolls it. Callers make a
/// new one per file, so both start over with each file.
public sealed class ReviewerDiff : Grid
{
    private readonly IReadOnlyList<DiffLine> lines;
    private readonly WideLinesScroll scroll;
    private readonly DiffMinimap? minimap;
    /// The diff row at the top of the pane, and how many rows the pane shows.
    private int topRow;
    private int visibleCount;

    /// `fileLines`: the file's line count, for the minimap's scale; null draws the diff rows only.
    public ReviewerDiff(FileChange file, IReadOnlyList<DiffLine> lines, int? fileLines)
    {
        this.lines = lines;
        // Worked out once per diff, not on every scroll step.
        var words = WordDiff.Marks(lines).ToDictionary(p => p.Key, p => (IReadOnlyList<(int Start, int End)>)p.Value.Select(r => (r.Lower, r.Upper)).ToList());
        scroll = new WideLinesScroll(
            lines.Select(l => l.Prefix() + l.Text).ToList(),
            gutter: 2 * (Theme.Size.DiffLineNumberWidth + Theme.Size.PreviewGutterSpacing),
            rows: contentWidth => lines.Select((line, index) =>
                (UIElement)CodeLineRow.For(line, words.TryGetValue(index, out var w) ? w : null, minWidth: contentWidth)),
            reserve: Theme.Size.DiffMinimapReserve,
            footer: file.PatchTruncated ? TruncatedNote(file, lines) : null)
        {
            OnScroll = offset =>
            {
                int row = (int)Math.Round((offset - Theme.Size.PreviewVPadding) / Theme.Size.DiffLineHeight);
                int clamped = Math.Max(0, Math.Min(Math.Max(0, lines.Count - 1), row));
                if (clamped != topRow) { topRow = clamped; UpdateMinimap(); }
            },
            OnHeight = height =>
            {
                visibleCount = (int)(height / Theme.Size.DiffLineHeight);
                UpdateMinimap();
            },
        };
        minimap = new DiffMinimap(new DiffMinimapModel(lines, fileLines), VisibleRange, row =>
        {
            int target = Math.Max(0, row - visibleCount / 2);
            scroll.ScrollToRow(target);
        })
        {
            Margin = new Thickness(0, Theme.Size.DiffMinimapInset, Theme.Size.DiffMinimapInset, Theme.Size.DiffMinimapInset),
        };
        scroll.Accessory = minimap;
        Children.Add(scroll);
    }

    private void UpdateMinimap()
    {
        if (minimap is not null) minimap.VisibleRows = VisibleRange;
    }

    private (int, int) VisibleRange
    {
        get
        {
            int last = Math.Max(0, lines.Count - 1);
            int top = Math.Min(topRow, last);
            return (top, Math.Max(top, Math.Min(last, top + Math.Max(1, visibleCount) - 1)));
        }
    }

    /// "… 212 more lines in the editor" when the patch left lines out.
    private static string TruncatedNote(FileChange file, IReadOnlyList<DiffLine> lines)
    {
        int shown = lines.Count(l => l.Kind is DiffLineKind.Added or DiffLineKind.Removed);
        int missing = Math.Max(0, file.Added + file.Removed - shown);
        return Format.MoreLines(missing) + " in the editor";
    }
}

/// "M", "A", "R" or "D" in a small badge after the file's name.
public sealed class FileKindBadge : Border
{
    public FileKindBadge(string kind)
    {
        var letter = kind switch { "new" => "A", "renamed" => "R", "deleted" => "D", _ => "M" };
        var text = Kit.Text(letter, Theme.Fonts.Badge, Theme.Brushes.GitKindText, TextTrimming.None);
        text.HorizontalAlignment = HorizontalAlignment.Center;
        Child = text;
        MinWidth = Theme.Size.GitKindWidth + Theme.Size.BadgeHPadding;
        Padding = new Thickness(Theme.Size.BadgeHPadding / 2, 0, Theme.Size.BadgeHPadding / 2, 0);
        Height = Theme.Size.BadgeHeight;
        CornerRadius = new CornerRadius(Theme.Radius.Keycap);
        Background = Theme.Brushes.GitKindFill;
        VerticalAlignment = VerticalAlignment.Center;
        ToolTip = kind switch { "new" => "added", "renamed" => "renamed", "deleted" => "deleted", _ => "modified" };
    }
}
