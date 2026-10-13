// AttentionView.cs
// Port of Sources/notchcode/Notch/AttentionView.swift.
// Two rows, clay. Row 1 in the wings: Needs you · session · countdown; a click opens the card
// with the request in the well. Row 2 below the notch: what Claude wants on the left ("Allow
// Bash?" and the command), and the answers on the right as toolbar segments (Deny · Always ·
// Allow, or Skip · Edit · Commit), the countdown draining along Allow. One press answers
// without opening anything.

using System.Windows;
using System.Windows.Controls;
using Notchcode.Features.Requests;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class AttentionView : Grid
{
    public AttentionView(AppState state, PendingRequest request, Size bodySize)
    {
        Width = bodySize.Width;
        Height = bodySize.Height;
        VerticalAlignment = VerticalAlignment.Top;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(state.Layout.NotchHeight) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.AttentionExtraHeight) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var left = new HStack(Theme.Size.WingSpacing,
            new BreathingTriangle().Fixed(),
            Ui.Text("Needs you", Theme.Fonts.CaptionMedium, Theme.Brushes.AttentionText).Fixed());
        var right = new HStack(Theme.Size.WingSpacing,
            Ui.Text(state.Session(request.SessionId)?.DisplayFull ?? "", Theme.Fonts.Caption, Theme.Brushes.InkSecondary, Truncation.Middle),
            new DeadlineCountdown(request).Fixed());
        var row1 = new WingRow(state.Layout, bodySize.Width, left, right)
            .Help($"Open the card ({Theme.Keys.Option} {Theme.Keys.Space})");
        row1.OnTap(() => state.OpenCard());
        Children.Add(row1);

        // Row 2: never fixed-size on the left, so a long tool name cannot push Allow out of the clip.
        var what = new HStack(Theme.Size.SpaceM,
            Ui.Text(request.Headline, Theme.Fonts.BodySemibold, Theme.Brushes.Ink, Truncation.Middle).Priority(1),
            // The doorbell: one line, cut at the end so the command reads from its start.
            Ui.Text(request.Summary, Theme.Fonts.MonoCaption, Theme.Brushes.InkSecondary, Truncation.Tail));
        what.HorizontalAlignment = HorizontalAlignment.Left;
        var whatBox = new Border { Child = what }.OnTap(() => state.OpenCard());

        var actions = new ActionStrip(state, request, allKeys: true) { HorizontalAlignment = HorizontalAlignment.Right };
        var row2 = new Grid { Margin = new Thickness(Theme.Size.SidePadding, 0, Theme.Size.SidePadding, 0) };
        row2.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row2.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        whatBox.Margin = new Thickness(0, 0, Theme.Size.SpaceM, 0);
        SetColumn(actions, 1);
        row2.Children.Add(whatBox);
        row2.Children.Add(actions);
        SetRow(row2, 1);
        Children.Add(row2);
    }
}
