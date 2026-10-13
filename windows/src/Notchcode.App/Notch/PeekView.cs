// PeekView.cs
// Port of Sources/notchcode/Notch/PeekView.swift.
// One line when something completes: a finished turn ("Done · ponyfish", its files and ±
// totals), a finished subagent, or (opt-in) a single file edit. A thin white line at the
// bottom shrinks over the peek's lifetime. Done: the check circle pops and draws on, and the
// ± counts count up. After the peek, the notch settles into Resting (AppState's mode rule).

using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class PeekView : StateView
{
    private readonly Peek peek;
    private readonly HStack right = new() { Spacing = Theme.Size.SpaceS };

    public PeekView(AppState state, Peek peek, Size bodySize) : base(state)
    {
        this.peek = peek;
        Width = bodySize.Width;
        Height = bodySize.Height;
        Children.Add(new WingRow(state.Layout, bodySize.Width, Left(), right));
        BuildRight();

        var line = new Rectangle
        {
            Fill = Theme.Brushes.Ink,
            Height = Theme.Size.PeekLine,
            Width = bodySize.Width,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            IsHitTestVisible = false,
        };
        Children.Add(line);
        Loaded += (_, _) =>
        {
            var shrink = new DoubleAnimation(bodySize.Width, 0, new Duration(TimeSpan.FromSeconds(state.Prefs.PeekSeconds)));
            line.BeginAnimation(WidthProperty, shrink);
        };
        this.OnTap(() => state.TapPeek(peek));
    }

    protected override void Update()
    {
        // The agent peek names its session, which may be renamed while it shows.
        if (peek.Kind == PeekKind.Agent) BuildRight();
    }

    private UIElement Left()
    {
        var row = new HStack { Spacing = Theme.Size.WingSpacing };
        switch (peek.Kind)
        {
            case PeekKind.Edit:
                row.Children.Add(new CircleGlyph(Theme.Symbols.Diff, Theme.Colors.Green).Fixed());
                row.Children.Add(Ui.Text(peek.Title, Theme.Fonts.MonoCaption, Theme.Brushes.Ink, Truncation.Middle));
                break;
            case PeekKind.Done:
                row.Children.Add(new DoneCheckGlyph().Fixed());
                row.Children.Add(Ui.Text(peek.Title, Theme.Fonts.CaptionMedium, Theme.Brushes.Ink, Truncation.Middle));
                break;
            default:
                row.Children.Add(new AgentSquare(peek.ColorIndex ?? 0).Fixed());
                row.Children.Add(Ui.Text(peek.Title, Theme.Fonts.CaptionMedium, Theme.Brushes.Ink));
                break;
        }
        return row;
    }

    private void BuildRight()
    {
        right.Children.Clear();
        switch (peek.Kind)
        {
            case PeekKind.Edit:
                if (peek.Added is int a) right.Children.Add(new CountPill(a, Format.Added, Theme.Brushes.Green, Theme.Brushes.GreenFill).Fixed());
                if (peek.Removed is int r) right.Children.Add(new CountPill(r, Format.Removed, Theme.Brushes.Red, Theme.Brushes.RedFill).Fixed());
                if (peek.Detail is { } detail) right.Children.Add(Ui.Text(detail, Theme.Fonts.Caption, Theme.Brushes.InkTertiary));
                break;
            case PeekKind.Done:
                if (peek.Detail is { } d) right.Children.Add(Ui.Text(d, Theme.Fonts.Caption, Theme.Brushes.InkSecondary));
                if (peek.Added is int added)
                    right.Children.Add(new CountPill(added, Format.Added, Theme.Brushes.Green, Theme.Brushes.GreenFill, countsUp: true).Fixed());
                if (peek.Removed is int removed)
                    right.Children.Add(new CountPill(removed, Format.Removed, Theme.Brushes.Red, Theme.Brushes.RedFill, countsUp: true).Fixed());
                break;
            default:
                right.Children.Add(Ui.Text(State.Session(peek.SessionId)?.DisplayFull ?? "", Theme.Fonts.Caption,
                    Theme.Brushes.InkSecondary, Truncation.Middle));
                break;
        }
    }
}
