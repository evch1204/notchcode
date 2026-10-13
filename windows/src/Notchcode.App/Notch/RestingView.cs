// RestingView.cs
// Port of Sources/notchcode/Notch/RestingView.swift.
// Sessions exist but none works or needs the owner. Left: a static dot in the session's
// colour (green done, grey idle) and the worktree name at 60%. Right: "+N" only when other
// sessions exist. Nothing moves. Hover brightens the name (the root view lights the rim)
// and, for click-to-open owners, swaps the right wing for the tools (the left wing names the
// one under the mouse); a click opens the card.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Shapes;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class RestingView : StateView
{
    private readonly HoverToolsNameWing leftWing;
    private readonly HoverToolsWing rightWing;
    private string leftKey = "";
    private string rightKey = "";
    private TextLine? name;
    private bool? hovering;

    public RestingView(AppState state, Size bodySize) : base(state)
    {
        Width = bodySize.Width;
        Height = bodySize.Height;
        leftWing = new HoverToolsNameWing(state, new HStack());
        rightWing = new HoverToolsWing(state, bodySize.Width, new HStack());
        Children.Add(new WingRow(state.Layout, bodySize.Width, leftWing, rightWing));
        this.OnTap(state.ToggleFromNotchTap);
    }

    protected override void Update()
    {
        var session = State.PrimarySession;
        string key = $"{session?.State}|{session.DisplayOrApp()}";
        if (key != leftKey)
        {
            leftKey = key;
            var dot = new Grid { Width = Theme.Size.Glyph, Height = Theme.Size.Glyph };
            dot.Children.Add(new Ellipse
            {
                Width = Theme.Size.Dot,
                Height = Theme.Size.Dot,
                Fill = session?.State == SessionState.Done ? Theme.Brushes.RestingDone : Theme.Brushes.RestingIdle,
            });
            name = Ui.Text(session.DisplayOrApp(), Theme.Fonts.CaptionMedium, Theme.Brushes.WingsName, Truncation.Middle);
            name.Opacity = State.Hovering ? Theme.Opacity.RestingHover : Theme.Opacity.Resting;
            hovering = State.Hovering;
            leftWing.SetContent(new HStack(Theme.Size.WingSpacing, dot.Fixed(), name));
        }
        if (name is not null && hovering != State.Hovering)
        {
            hovering = State.Hovering;
            Transitions.Animate(name, OpacityProperty, State.Hovering ? Theme.Motion.HoverIn : Theme.Motion.HoverOut,
                State.Hovering ? Theme.Opacity.RestingHover : Theme.Opacity.Resting);
        }

        int others = State.OtherSessionCount(session);
        string right = others.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (right == rightKey) return;
        rightKey = right;
        var row = new HStack();
        if (others > 0)
            row.Children.Add(Ui.Text(Format.OtherSessions(others), Theme.Fonts.Caption, Theme.Brushes.WingsCountText)
                .Help(Format.OtherSessionsHelp(others)));
        rightWing.SetContent(row);
    }
}
