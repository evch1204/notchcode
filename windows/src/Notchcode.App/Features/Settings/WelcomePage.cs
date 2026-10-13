// WelcomePage.cs
// The first run (root PLAN.md, "Distribution and first run"; no Swift twin yet, the macOS
// plan's build order step 3). Not connected → the card opens by itself on a Welcome page:
// "Connect to Claude Code" (⏎, white), "Open at login" (on), one caption saying what Connect
// touches and that Disconnect puts it back, esc for later. One press does the hooks, the
// status line and the login item together; the page turns into "Connected · start a Claude
// Code session" and closes. Seen once (a marker file beside the preferences); Settings keeps
// the same controls. On Windows "Open at login" is the `OpenAtLogin` preference (a HKCU Run
// value, App/LoginItem.cs).

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Shapes;
using System.Windows.Threading;
using Notchcode.ClaudeCode;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Settings;

/// Whether the Welcome page is up, and the once-only marker.
public static class Welcome
{
    private static string Marker => System.IO.Path.Combine(NotchcodePaths.SupportDirectory, "welcome-seen");

    /// The Settings page shows the Welcome page instead of its groups.
    public static bool Showing { get; private set; }

    public static bool Seen
    {
        get
        {
            try { return File.Exists(Marker); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return true; }
        }
    }

    /// At launch (not in the demo): when the welcome was never shown and Claude Code is not
    /// connected, the card opens by itself on it. Marked seen at once, so it never comes back.
    public static bool OpenIfFirstRun(AppState state)
    {
        // A blocking request takes the card first; the welcome waits for the next launch.
        if (Seen || state.CurrentPending is not null || HooksInstaller.Status() != HooksInstallerStatus.NotConnected) return false;
        MarkSeen();
        Showing = true;
        state.OpenSettings();
        return true;
    }

    /// The harness shows the page without touching the marker.
    internal static void ShowForPreview(bool showing) => Showing = showing;

    internal static void Finish() => Showing = false;

    private static void MarkSeen()
    {
        try
        {
            Directory.CreateDirectory(NotchcodePaths.SupportDirectory);
            File.WriteAllText(Marker, DateTime.UtcNow.ToString("O"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// "Welcome to notchcode", the Connect pill (⏎), Open at login, the caption, "esc later".
public sealed class WelcomePage : Grid
{
    private readonly AppState state;
    private readonly ColumnStack column = new() { Spacing = Theme.Size.SettingsGroupSpacing };
    private Window? window;
    private bool connected;
    private string? error;

    public WelcomePage(AppState state)
    {
        this.state = state;
        Children.Add(column);
        Render();
        Loaded += (_, _) =>
        {
            window = Window.GetWindow(this);
            // ⏎ is not a Settings key, so the card leaves it unhandled and it bubbles here.
            if (window is not null) window.KeyDown += OnKeyDown;
        };
        Unloaded += (_, _) =>
        {
            if (window is not null) window.KeyDown -= OnKeyDown;
            window = null;
            bool later = !connected;
            Welcome.Finish();
            // esc (or any way off the page) is "later": the card closes rather than landing
            // on a tool the owner did not ask for.
            if (later) Dispatcher.BeginInvoke(() => { if (state.IsCardOpen) state.CloseCard(); });
        };
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Handled || connected || e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.None) return;
        e.Handled = true;
        Connect();
    }

    private void Render()
    {
        column.Children.Clear();
        var title = Kit.Text("Welcome to notchcode", Theme.Fonts.Hero, Theme.Brushes.Ink, TextTrimming.None);
        title.HorizontalAlignment = HorizontalAlignment.Left;
        var lead = Kit.Wrapped("Claude Code's permissions, plans, commits and finished turns, in the notch.",
            Theme.Fonts.Body, Theme.Brushes.InkSecondary);
        lead.TextTrimming = TextTrimming.None;
        column.Children.Add(new ColumnStack(Theme.Size.SpaceS, title, lead));

        if (connected)
        {
            var dot = new Ellipse { Width = Theme.Size.Dot, Height = Theme.Size.Dot, Fill = Theme.Brushes.SettingsConnected, VerticalAlignment = VerticalAlignment.Center };
            var done = new RowStack(Theme.Size.SpaceM, dot,
                Kit.Text("Connected" + Theme.Glyphs.Separator + "start a Claude Code session", Theme.Fonts.Body, Theme.Brushes.Ink))
            { MinHeight = Theme.Size.SettingsRowHeight };
            var box = new InsetGroup(done);
            column.Children.Add(box);
            Transitions.Insert(box, Theme.Motion.PaneSwapTransition);
            return;
        }

        var connect = new SmallPill(new RowStack(Theme.Size.ActionKeyGap,
                Kit.Text("Connect to Claude Code", Theme.Fonts.CaptionMedium, Theme.Brushes.PrimaryText, TextTrimming.None),
                new Keycap(Theme.Keys.Enter, onLight: true)),
            Connect, primary: true);
        var connectRow = new RowStack(Theme.Size.SpaceM,
            new Ellipse { Width = Theme.Size.Dot, Height = Theme.Size.Dot, Fill = Theme.Brushes.SettingsDisconnected, VerticalAlignment = VerticalAlignment.Center },
            Kit.Flex(Kit.Text("Not connected", Theme.Fonts.Body, Theme.Brushes.Ink)),
            connect)
        { MinHeight = Theme.Size.SettingsRowHeight };
        var login = SettingsPage.Row("Open at login", SettingsPage.Switch(state.Prefs.OpenAtLogin,
            v => state.Prefs = state.Prefs with { OpenAtLogin = v }));
        var caption = Kit.Wrapped(
            "Connect adds notchcode's hooks and status line to " + HookInstallPaths.Default.SettingsFile
            + " beside your own, after a backup. Disconnect in Settings takes out only ours.",
            Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        caption.TextTrimming = TextTrimming.None;
        caption.Margin = new Thickness(0, 0, 0, Theme.Size.SettingsLabelSpacing);
        var group = new ColumnStack(0, connectRow, login, caption);
        if (error is not null)
        {
            var failed = Kit.Wrapped(error, Theme.Fonts.Caption, Theme.Brushes.SettingsError);
            failed.TextTrimming = TextTrimming.None;
            group.Children.Add(failed);
        }
        column.Children.Add(new InsetGroup(group));

        column.Children.Add(new RowStack(Theme.Size.SpaceS,
            new InlineKeycap(Theme.Keys.Escape),
            Kit.Text("later" + Theme.Glyphs.Separator + "Settings keeps the same controls", Theme.Fonts.Caption, Theme.Brushes.InkTertiary))
        { HorizontalAlignment = HorizontalAlignment.Left });
    }

    /// One press: the hooks and the status line (HooksInstaller), and the login item (the
    /// `OpenAtLogin` preference, already set by its switch). Then the page says so and closes.
    private void Connect()
    {
        if (connected) return;
        try
        {
            HooksInstaller.Connect();
            connected = HooksInstaller.Status() == HooksInstallerStatus.Connected;
            error = connected ? null : "Partly connected" + Theme.Glyphs.Separator + "open Settings to finish";
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        Render();
        if (!connected) return;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Theme.Timing.WelcomeConnectedHold) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Welcome.Finish();
            if (state.IsCardOpen) state.CloseCard();
        };
        timer.Start();
    }
}
