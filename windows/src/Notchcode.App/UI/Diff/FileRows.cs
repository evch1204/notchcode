// FileRows.cs
// Port of Sources/notchcode/UI/Diff/FileRows.swift.
// The expandable file row that owns a diff, shared by the Changes tool and the commit
// card: its label (name, cells, counts), the disclosure chevron, the cursor fill a list
// row carries, and the file's name label. And DiffRowItem, one file row in the Git rail.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Notchcode.UI;

namespace Notchcode.UI.Diff;

/// One expandable file row in the Git tool's rail. `Key` is stable across reloads.
public sealed record DiffRowItem(string Key, FileChange File)
{
    public string Id => Key;
}

/// A changed-file row that opens to its diff under it: the commit card lists its files with
/// it. The caller says what a click does, whether the row is open and under the cursor, and
/// draws the diff.
public sealed class FileDiffRow : ColumnStack
{
    /// `disabledWithoutDiff`: the commit card's rows without a diff take no clicks; the
    /// Changes rows still move the cursor.
    public FileDiffRow(FileChange file, bool open, bool isCursor, Action action, Func<UIElement> diff,
                       double spacing = Theme.Size.SpaceXS, bool disabledWithoutDiff = false)
    {
        Spacing = spacing;
        bool hasDiff = file.DiffLines().Count > 0;
        var label = new FileRowLabel(file, open, hasDiff, isCursor);
        if (!(disabledWithoutDiff && !hasDiff)) Kit.OnClick(label, action);
        Children.Add(label);
        if (open)
        {
            var d = diff();
            // Takes the room left above the footer (SwiftUI's negative layout priority).
            Kit.Priority(d, -1);
            Children.Add(d);
        }
    }
}

/// "▸ NotchView.swift            ▮▮▮▮▮  +12 −12": the row a diff opens under, with a
/// Sessions row's padding, radius and cursor fill. The name truncates in the middle; the
/// cells and counts always keep their room at the right.
public sealed class FileRowLabel : Border
{
    public FileRowLabel(FileChange file, bool open, bool hasDiff, bool isCursor)
    {
        var chevron = new RowChevron(open) { Opacity = hasDiff ? 1 : 0 };
        var name = new RowStack(Theme.Size.SpaceM, new PathLabel(file.Path));
        if (file.Kind == "shell")
        {
            // Changed by a Bash command: its diff is against HEAD, not the edit alone.
            var tag = Kit.Text(Theme.Glyphs.ShellTag, Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None);
            tag.ToolTip = "changed by a shell command" + Theme.Glyphs.Separator + "diff against HEAD";
            name.Children.Add(tag);
        }
        var counts = new RowStack(Theme.Size.SpaceM, new DiffCells(file.Added, file.Removed), new DiffCounts(file.Added, file.Removed));
        Child = new RowStack(Theme.Size.SpaceM, chevron, Kit.Flex(name), Kit.Priority(counts, 1));
        RowCursor.Fill(this, isCursor);
    }
}

/// The disclosure chevron at the front of a turn or file row: a Sessions chevron, turned
/// down while open. Its frame plus the row gap is one `chevronColumn`, so a file row
/// indented by that column puts its chevron under the turn's title. `animated: false` leaves
/// the turn to whatever toggles it.
public sealed class RowChevron : Grid
{
    public RowChevron(bool open, double? width = Theme.Size.ChevronColumn - Theme.Size.SpaceM, Brush? color = null,
                      double size = Theme.Fonts.ChevronSize, bool animated = true)
    {
        var glyph = Theme.Symbols.Chevron.ToPath(size, color ?? Theme.Brushes.InkTertiary);
        glyph.RenderTransformOrigin = new Point(0.5, 0.5);
        var rotate = new RotateTransform(open ? Theme.Motion.ChevronOpenDegrees : 0);
        glyph.RenderTransform = rotate;
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(glyph);
        if (width is { } w) Width = w;
        VerticalAlignment = VerticalAlignment.Center;
        _ = animated;
    }
}

/// A list row's padding, and the keyboard cursor's fill behind it: the same as a Sessions row.
public static class RowCursor
{
    public static void Fill(Border row, bool isCursor)
    {
        row.Padding = new Thickness(Theme.Size.RowHPadding, Theme.Size.RowVPadding, Theme.Size.RowHPadding, Theme.Size.RowVPadding);
        row.CornerRadius = new CornerRadius(Theme.Radius.Row);
        row.Background = isCursor ? Theme.Brushes.RowCursor : Kit.HitFill;
    }
}

/// "Theme.swift": a changed file's name only, in ink, truncated in the middle when long,
/// with the full path on hover. Used wherever a changed file is a row: the Changes tool,
/// the commit card's file list, the Files preview header, the Git rail.
public sealed class PathLabel : Border
{
    private readonly TrimText text;

    public PathLabel(string path, Brush? color = null)
    {
        text = new TrimText(Format.FileName(path), Theme.Fonts.MonoCaption, color ?? Theme.Brushes.Ink, TrimMode.Middle);
        Child = text;
        ToolTip = path;
        VerticalAlignment = VerticalAlignment.Center;
    }

    public Brush Foreground
    {
        get => text.Foreground;
        set => text.Foreground = value;
    }
}
