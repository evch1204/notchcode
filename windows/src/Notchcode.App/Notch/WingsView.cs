// WingsView.cs
// Port of Sources/notchcode/Notch/WingsView.swift.
// The collapsed state, readable in one glance. Left: a state glyph and the focused session's
// worktree name. Right: the agent count while that session runs subagents, else a state word
// only for Needs you and Done, then "+1 session" for each other live session. No clock here.
// Nothing is drawn over the camera. Hover (click-to-open owners): the right wing crossfades to
// the tools, and the left wing names the tool under the mouse.

using System.Windows;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

public sealed class WingsView : StateView
{
    private readonly HoverToolsNameWing leftWing;
    private readonly HoverToolsWing rightWing;
    private string glyphKey = "";
    private string leftKey = "";
    private string rightKey = "";
    private StateGlyph? glyph;

    public WingsView(AppState state, Size bodySize) : base(state)
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
        var shown = session is null ? SessionState.Idle : State.ShownState(session);

        // Left: the glyph is kept while the state holds, so the spark's pulse runs on.
        if (glyphKey != shown.ToString() || glyph is null)
        {
            glyphKey = shown.ToString();
            glyph = new StateGlyph(shown);
            leftKey = "";
        }
        string name = session.DisplayOrApp();
        if (leftKey != name)
        {
            leftKey = name;
            if (glyph.Parent is System.Windows.Controls.Panel old) old.Children.Remove(glyph);
            leftWing.SetContent(new HStack(Theme.Size.WingSpacing,
                glyph.Fixed(),
                Ui.Text(name, Theme.Fonts.CaptionMedium, Theme.Brushes.WingsName, Truncation.Middle)));
        }

        // Right: the agent count when subagents run, else a state word only when it says
        // something the glyph does not (Needs you, Done), then "+N" for other live sessions.
        int agents = State.Prefs.ShowAgentsInWings && session is not null ? State.RunningAgents(session.Id).Count : 0;
        int others = State.OtherLiveSessionCount(session);
        bool showWord = agents == 0 && shown is SessionState.NeedsYou or SessionState.Done;
        string key = $"{agents}|{showWord}|{shown}|{session?.Verb}|{others}";
        if (key == rightKey) return;
        rightKey = key;
        var row = new HStack { Spacing = Theme.Size.WingSpacing };
        if (agents > 0)
            row.Children.Add(Ui.Text(Format.Agents(agents), Theme.Fonts.CaptionMedium, Theme.Brushes.WingsCountText).Priority(2));
        else if (showWord)
            row.Children.Add(Ui.Text(Format.StateText(shown, session?.Verb), Theme.Fonts.CaptionMedium, Theme.Brushes.StateText(shown)).Priority(2));
        if (others > 0)
            row.Children.Add(Ui.Text(Format.OtherSessions(others), Theme.Fonts.Caption, Theme.Brushes.WingsCountText)
                .Priority(1).Help(Format.OtherSessionsHelp(others)));
        rightWing.SetContent(row);
    }
}
