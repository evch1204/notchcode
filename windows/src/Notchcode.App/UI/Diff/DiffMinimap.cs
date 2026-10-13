// DiffMinimap.cs
// Port of Sources/notchcode/UI/Diff/DiffMinimap.swift.
// The minimap of where a diff's changes sit in the whole file: its model (the marks, and
// which rows of the diff sit where) and the slim track the reviewer diff lays down its
// right edge.

using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Notchcode.UI;

namespace Notchcode.UI.Diff;

// MARK: - Minimap

/// Where a diff's changes sit in the whole file, as fractions of its length, and which rows
/// of the diff sit where. Lines are placed by their new-file number (a removed line where
/// it used to be, just before the next new line); a deleted file by its old numbers.
public sealed record DiffMinimapModel
{
    public readonly record struct Mark(double Start, double Length, bool Added);

    /// Each diff row's line in the file (1-based).
    public IReadOnlyList<int> Anchors { get; }
    /// Lines in the whole file.
    public int Total { get; }
    public IReadOnlyList<Mark> Marks { get; }

    public DiffMinimapModel(IReadOnlyList<DiffLine> lines, int? fileLines)
    {
        bool usesOld = !lines.Any(l => l.Kind is DiffLineKind.Added or DiffLineKind.Context);
        var anchors = new List<int>();
        int next = 1;
        foreach (var line in lines)
        {
            int anchor;
            if (line.Kind == DiffLineKind.Hunk)
            {
                // "@@ -187,8 +196,37 @@": the hunk starts at its new (or old) start line.
                int start = HunkStart(line.Text, usesOld) ?? next;
                anchor = start;
                next = start;
            }
            else if (usesOld)
            {
                anchor = line.OldLine ?? next;
            }
            else if (line.Kind is DiffLineKind.Added or DiffLineKind.Context)
            {
                anchor = line.NewLine ?? next;
                next = anchor + 1;
            }
            else
            {
                anchor = next;
            }
            anchors.Add(Math.Max(1, anchor));
        }
        Anchors = anchors;
        int total = Math.Max(1, Math.Max(fileLines ?? 0, anchors.Count == 0 ? 1 : anchors.Max()));
        Total = total;

        var marks = new List<Mark>();
        int index = 0;
        while (index < lines.Count)
        {
            var kind = lines[index].Kind;
            if (kind is not (DiffLineKind.Added or DiffLineKind.Removed)) { index++; continue; }
            int end = index;
            while (end < lines.Count && lines[end].Kind == kind) end++;
            int first = anchors[index];
            int span = usesOld || kind == DiffLineKind.Added ? Math.Max(1, anchors[end - 1] - first + 1) : end - index;
            marks.Add(new Mark((double)(first - 1) / total, (double)span / total, kind == DiffLineKind.Added));
            index = end;
        }
        Marks = marks;
    }

    /// The start line after "-" (old) or "+" (new) in a hunk header.
    private static int? HunkStart(string text, bool old)
    {
        int at = text.IndexOf(old ? '-' : '+');
        if (at < 0) return null;
        var digits = new string(text.Skip(at + 1).TakeWhile(char.IsDigit).ToArray());
        return int.TryParse(digits, out var n) ? n : null;
    }

    /// The fraction of the file where a row sits.
    public double Fraction(int row)
    {
        if (row < 0 || row >= Anchors.Count) return row <= 0 ? 0 : 1;
        return (double)(Anchors[row] - 1) / Total;
    }

    /// The first row at or after a point in the file (the last row past the end).
    public int Row(double fraction)
    {
        int line = (int)Math.Floor(fraction * Total) + 1;
        for (int i = 0; i < Anchors.Count; i++) if (Anchors[i] >= line) return i;
        return Math.Max(0, Anchors.Count - 1);
    }
}

/// The minimap: a slim track, green and red marks where lines were added and removed,
/// and a ringed box over what the pane shows. A click jumps there; a drag scrubs.
public sealed class DiffMinimap : FrameworkElement
{
    private readonly DiffMinimapModel model;
    private readonly Action<int> onJump;
    private (int Lower, int Upper) visibleRows;

    public DiffMinimap(DiffMinimapModel model, (int Lower, int Upper) visibleRows, Action<int> onJump)
    {
        this.model = model;
        this.visibleRows = visibleRows;
        this.onJump = onJump;
        Width = Theme.Size.DiffMinimapWidth;
        ToolTip = "Where the changes are in the file";
        Cursor = Cursors.Hand;
        MouseLeftButtonDown += (_, e) => { CaptureMouse(); Jump(e.GetPosition(this).Y); e.Handled = true; };
        MouseMove += (_, e) => { if (IsMouseCaptured) Jump(e.GetPosition(this).Y); };
        MouseLeftButtonUp += (_, e) => { ReleaseMouseCapture(); e.Handled = true; };
    }

    /// The rows at the top and bottom of the pane.
    public (int Lower, int Upper) VisibleRows
    {
        get => visibleRows;
        set { if (visibleRows == value) return; visibleRows = value; InvalidateVisual(); }
    }

    private void Jump(double y)
    {
        double fraction = Math.Clamp(y / Math.Max(1, ActualHeight), 0, 1);
        onJump(model.Row(fraction));
    }

    protected override void OnRender(DrawingContext dc)
    {
        double width = ActualWidth, height = ActualHeight;
        if (height <= 0) return;
        // The whole box takes the mouse.
        dc.DrawRectangle(Kit.HitFill, null, new Rect(0, 0, width, height));
        dc.DrawRoundedRectangle(Theme.Brushes.DiffMinimapTrack, null, new Rect(0, 0, width, height), Theme.Radius.DiffMinimap, Theme.Radius.DiffMinimap);
        foreach (var mark in model.Marks)
        {
            double h = Math.Max(Theme.Size.DiffMinimapMinMark, mark.Length * height);
            double y = Math.Min(height - Theme.Size.DiffMinimapMinMark, mark.Start * height);
            double r = Theme.Radius.DiffMinimap / 2;
            dc.DrawRoundedRectangle(mark.Added ? Theme.Brushes.Green : Theme.Brushes.Red, null, new Rect(0, y, width, h), r, r);
        }
        // The viewport: a ringed box over the rows on screen, a little wider than the track.
        double top = model.Fraction(visibleRows.Lower) * height;
        double bottom = (model.Fraction(visibleRows.Upper) + 1.0 / model.Total) * height;
        double boxHeight = Math.Max(Theme.Size.DiffMinimapMinViewport, bottom - top);
        double boxY = Math.Min(Math.Max(0, height - boxHeight), top);
        double outset = Theme.Size.DiffMinimapViewportOutset;
        double line = Theme.Size.DiffMinimapRingLine;
        var rect = new Rect(-outset + line / 2, boxY + line / 2, width + 2 * outset - line, boxHeight - line);
        var pen = new Pen(Theme.Brushes.DiffMinimapRing, line);
        pen.Freeze();
        dc.DrawRoundedRectangle(Theme.Brushes.DiffMinimapViewport, pen, rect, Theme.Radius.DiffMinimapViewport, Theme.Radius.DiffMinimapViewport);
    }
}
