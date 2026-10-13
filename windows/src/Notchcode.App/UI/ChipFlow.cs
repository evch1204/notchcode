// ChipFlow.cs
// Port of Sources/notchcode/UI/ChipFlow.swift: a flow layout. Chips go left to right at their
// natural width, wrapping to a new row when the next one would not fit. A chip wider than the
// whole row is offered the row's width, so its flexible part (a file name) truncates instead
// of overflowing.

using System.Windows;
using System.Windows.Controls;

namespace Notchcode.UI;

public sealed class ChipFlow : Panel
{
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(ChipFlow),
        new FrameworkPropertyMetadata(Theme.Size.ChangesChipGap, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty RowSpacingProperty = DependencyProperty.Register(
        nameof(RowSpacing), typeof(double), typeof(ChipFlow),
        new FrameworkPropertyMetadata(Theme.Size.ChangesChipGap, FrameworkPropertyMetadataOptions.AffectsMeasure));

    /// Between chips in a row.
    public double Spacing
    {
        get => (double)GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    /// Between rows.
    public double RowSpacing
    {
        get => (double)GetValue(RowSpacingProperty);
        set => SetValue(RowSpacingProperty, value);
    }

    private sealed class Row
    {
        public List<(int Index, Size Size)> Items { get; } = [];
        public double Width;
        public double Height;
    }

    private List<Row> Arrange(double limit)
    {
        var rows = new List<Row>();
        var row = new Row();
        for (int index = 0; index < InternalChildren.Count; index++)
        {
            var child = InternalChildren[index];
            if (child.Visibility == Visibility.Collapsed) continue;
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (size.Width > limit)
            {
                child.Measure(new Size(limit, double.PositiveInfinity));
                size = new Size(Math.Min(child.DesiredSize.Width, limit), child.DesiredSize.Height);
            }
            double needed = row.Items.Count == 0 ? size.Width : row.Width + Spacing + size.Width;
            if (row.Items.Count > 0 && needed > limit)
            {
                rows.Add(row);
                row = new Row();
            }
            row.Width = row.Items.Count == 0 ? size.Width : row.Width + Spacing + size.Width;
            row.Height = Math.Max(row.Height, size.Height);
            row.Items.Add((index, size));
        }
        if (row.Items.Count > 0) rows.Add(row);
        return rows;
    }

    protected override Size MeasureOverride(Size available)
    {
        var rows = Arrange(available.Width);
        double width = rows.Count == 0 ? 0 : rows.Max(r => r.Width);
        double height = rows.Sum(r => r.Height) + RowSpacing * Math.Max(0, rows.Count - 1);
        return new Size(double.IsInfinity(available.Width) ? width : available.Width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double y = 0;
        foreach (var row in Arrange(finalSize.Width))
        {
            double x = 0;
            foreach (var (index, size) in row.Items)
            {
                InternalChildren[index].Arrange(new Rect(x, y, size.Width, size.Height));
                x += size.Width + Spacing;
            }
            y += row.Height + RowSpacing;
        }
        return finalSize;
    }
}
