// SettingsPage.xaml.cs
// Port of Sources/notchcode/Features/Settings/SettingsPage.swift.
// Settings as a page inside the card (the gear in the strip, or Ctrl , while the card is
// open). Never a separate window. Compact rows in inset groups, scrollable, "‹ Back" (or
// esc) returns to the tab it came from. Every control writes straight into AppState.Prefs,
// which saves itself.
//
// Windows (windows/PLAN.md): the hotkey row names the live chord ("Alt space", or
// "Ctrl Alt space" when another app owns Alt space); the Opening group carries Open at login
// and the tray icon switch; the notification is a Windows one; an About group shows the
// version; Quit says the app opens again at login or with the next Claude Code session.
//
// First run (root PLAN.md, "Distribution and first run"): while Claude Code is not connected
// the card opens by itself once on the Welcome page (WelcomePage.cs), which this page shows
// in place of the groups.

using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Notchcode.ClaudeCode;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Settings;

public partial class SettingsPage : UserControl
{
    private readonly AppState state;
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: false);
    private HooksInstallerStatus hookStatus = HooksInstallerStatus.NotConnected;
    private string? hookError;
    private bool working;
    private bool pending;
    /// A control on this page made the last change: it already shows it (a switch's knob is
    /// still sliding), so the page is rebuilt only when what it lays out changed.
    private bool selfEdit;
    private string? layoutKey;
    private readonly WelcomePage? welcome;

    public SettingsPage(AppState state)
    {
        this.state = state;
        InitializeComponent();
        if (Welcome.Showing)
        {
            welcome = new WelcomePage(state);
            Root.Children.Add(welcome);
            return;
        }
        var column = new ColumnStack { Spacing = Theme.Size.SpaceM };
        column.Children.Add(Header());
        column.Children.Add(Kit.Flex(scroll));
        Root.Children.Add(column);
        Loaded += (_, _) =>
        {
            state.PropertyChanged += OnStateChanged;
            RefreshStatus();
            Render();
            // Settings always opens at its top, the Connect group first.
            scroll.ScrollToVerticalOffset(0);
        };
        Unloaded += (_, _) => state.PropertyChanged -= OnStateChanged;
        IsVisibleChanged += (_, e) => { if (e.NewValue is true) scroll.ScrollToVerticalOffset(0); };
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppState.Prefs) || pending) return;
        if (selfEdit)
        {
            selfEdit = false;
            if (LayoutKey(state.Prefs) == layoutKey) return;
        }
        pending = true;
        Dispatcher.BeginInvoke(() => { pending = false; Render(); }, DispatcherPriority.Render);
    }

    /// What the page lays out from the preferences: the rows that dim with peeks off, the
    /// hotkey's name. Any other change shows in its own control already.
    private static string LayoutKey(Preferences prefs) => prefs.ShowPeeks + "|" + prefs.HotkeyChord;

    /// Writes a preference from one of this page's controls.
    private void Set(Func<Preferences, Preferences> change)
    {
        selfEdit = true;
        state.Prefs = change(state.Prefs);
    }

    /// Scrolls the page (the harness, and a later deep link to a group).
    public void ScrollTo(double offset) => scroll.ScrollToVerticalOffset(offset);

    /// "‹ Back  esc ········ Settings ········ Ctrl ,".
    private UIElement Header()
    {
        var back = new SmallPill(new RowStack(Theme.Size.SpaceS,
                Theme.Symbols.Back.ToPath(Theme.Fonts.ChevronSize, Theme.Brushes.Ink),
                Kit.Text("Back", Theme.Fonts.CaptionMedium, Theme.Brushes.Ink, TextTrimming.None)),
            state.CloseSettings);
        var title = Kit.Text("Settings", Theme.Fonts.BodySemibold, Theme.Brushes.Ink, TextTrimming.None);
        return new RowStack(Theme.Size.SpaceM, back, new InlineKeycap(Theme.Keys.Escape), Kit.Spacer(Theme.Size.SpaceM), title,
            Kit.Spacer(Theme.Size.SpaceM), new InlineKeycap(Theme.Keys.Settings));
    }

    private void Render()
    {
        var prefs = state.Prefs;
        layoutKey = LayoutKey(prefs);
        double offset = scroll.VerticalOffset;
        var groups = new ColumnStack { Spacing = Theme.Size.SettingsGroupSpacing };
        groups.Children.Add(ConnectGroup());

        groups.Children.Add(Group("When idle",
            Row("Notch", Pills(prefs.IdleStyle, [(IdleStyle.Wings, "Resting row"), (IdleStyle.Closed, "Pure notch")],
                v => Set(p => p with { IdleStyle = v })))));

        groups.Children.Add(Group("When Claude needs you",
            Row("Style", Pills(prefs.AttentionStyle, [(AttentionStyle.TwoRow, "Two rows"), (AttentionStyle.Wings, "Wings only")],
                v => Set(p => p with { AttentionStyle = v }))),
            Row("Also post a Windows notification", Switch(prefs.SystemNotifications, v => Set(p => p with { SystemNotifications = v })))));

        groups.Children.Add(Group("Passive events",
            Row("Peek when a turn or subagent finishes", Switch(prefs.ShowPeeks, v => Set(p => p with { ShowPeeks = v }))),
            Row("Also peek each file edit", Dimmed(Switch(prefs.PeekEdits, v => Set(p => p with { PeekEdits = v })), prefs.ShowPeeks), prefs.ShowPeeks),
            Row("Peek length", new KeycapStepper(prefs.PeekSeconds, Theme.Timing.PeekSecondsRange, Theme.Timing.PeekSecondsStep,
                v => $"{(int)v} s", v => Set(p => p with { PeekSeconds = v }), prefs.ShowPeeks), prefs.ShowPeeks)));

        groups.Children.Add(Group("Opening",
            Row("Open the card on", Pills(prefs.OpenGesture, [(OpenGesture.Click, "Click"), (OpenGesture.Hover, "Hover")],
                v => Set(p => p with { OpenGesture = v }))),
            Row("Open at login", Switch(prefs.OpenAtLogin, v => Set(p => p with { OpenAtLogin = v }))),
            Row("Show the tray icon (Open, Settings, Quit)", Switch(prefs.ShowTrayIcon, v => Set(p => p with { ShowTrayIcon = v })))));

        groups.Children.Add(Group("Keys",
            Row(HotkeyLabel(prefs.HotkeyChord) + " opens the notch from anywhere", Switch(prefs.HotkeyEnabled, v => Set(p => p with { HotkeyEnabled = v }))),
            Row("Show keys beside buttons in the card", Switch(prefs.KeycapsBesideButtons, v => Set(p => p with { KeycapsBesideButtons = v })))));

        groups.Children.Add(Group("Agents",
            Row("Show the running agent count beside the closed notch", Switch(prefs.ShowAgentsInWings, v => Set(p => p with { ShowAgentsInWings = v })))));

        var usageNote = Kit.Wrapped("Runs `claude -p /usage` every 15 minutes with no hooks and no model turn; the Fable week and the limits breakdown come from it. Off, the page shows what the status line and Claude Code's own cache last reported.",
            Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        usageNote.TextTrimming = TextTrimming.None;
        usageNote.Margin = new Thickness(0, 0, 0, Theme.Size.SettingsLabelSpacing);
        groups.Children.Add(Group("Usage",
            Row("Refresh plan limits with the claude command", Switch(prefs.PlanUsageRefresh, v => Set(p => p with { PlanUsageRefresh = v }))),
            usageNote));

        groups.Children.Add(Group("About",
            Row("notchcode", Kit.Text(Version, Theme.Fonts.MonoSmall, Theme.Brushes.InkSecondary, TextTrimming.None))));

        var quit = new SmallPill("Quit", state.Quit) { ToolTip = Theme.Keys.Quit + " while the card is open" };
        groups.Children.Add(Group("Quit",
            Row("Quit notchcode. It opens again at login, or with your next Claude Code session.", quit)));

        scroll.Content = groups;
        scroll.ScrollToVerticalOffset(offset);
    }

    /// "Alt space", or "Ctrl Alt space" when Alt+Space was taken at launch (prefs.HotkeyChord).
    public static string HotkeyLabel(string chord) => chord == "ctrl-alt-space"
        ? "Ctrl " + Theme.Keys.Option + " " + Theme.Keys.Space
        : Theme.Keys.Option + " " + Theme.Keys.Space;

    /// The app's version ("0.1.0"): the assembly's informational version without its build
    /// metadata, or `Theme.AppVersion` while the project stamps none of its own (the SDK's
    /// default "1.0.0").
    public static string Version
    {
        get
        {
            var info = typeof(SettingsPage).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                       ?? typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "";
            int plus = info.IndexOf('+');
            var text = plus >= 0 ? info[..plus] : info;
            return text.Length == 0 || text == "1.0.0" ? Theme.AppVersion : text;
        }
    }

    // MARK: Connect

    private UIElement ConnectGroup()
    {
        var dot = new Ellipse { Width = Theme.Size.Dot, Height = Theme.Size.Dot, Fill = StatusColor, VerticalAlignment = VerticalAlignment.Center };
        var text = Kit.Text(StatusText, Theme.Fonts.Body, Theme.Brushes.Ink);
        var button = new SmallPill(ConnectButtonTitle, ToggleConnection, primary: hookStatus != HooksInstallerStatus.Connected) { Enabled = !working };
        var row = new RowStack(Theme.Size.SpaceM, dot, Kit.Flex(text), button) { MinHeight = Theme.Size.SettingsRowHeight };
        var path = new TrimText(HookInstallPaths.Default.SettingsFile, Theme.Fonts.MonoSmall, Theme.Brushes.InkTertiary, TrimMode.Middle);
        var caption = Kit.Wrapped("Adds our hooks beside your own. Your other hooks are never changed. New Claude Code sessions pick this up; running ones keep their old hooks.",
            Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        caption.TextTrimming = TextTrimming.None;
        var backup = Kit.Wrapped(BackupCaption, Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        backup.TextTrimming = TextTrimming.None;
        var notes = new ColumnStack(Theme.Size.SettingsLabelSpacing, path, caption, backup);
        if (hookError is not null)
        {
            var error = Kit.Wrapped(hookError, Theme.Fonts.Caption, Theme.Brushes.SettingsError);
            error.TextTrimming = TextTrimming.None;
            notes.Children.Add(error);
        }
        return Group("Connect", row, notes);
    }

    /// Where the backup goes and what Disconnect takes out.
    public static string BackupCaption =>
        $"A copy of settings.json is saved beside it first (settings.json.notchcode-backup-{Theme.Glyphs.Ellipsis}, the newest {HooksInstaller.KeptBackups} kept); Disconnect takes out only our entries.";

    private string StatusText => hookStatus switch
    {
        HooksInstallerStatus.Connected => "Connected to Claude Code",
        HooksInstallerStatus.Partial => "Partly connected",
        HooksInstallerStatus.Stale => "Reconnect" + Theme.Glyphs.Separator + "the hooks are out of date",
        _ => "Not connected",
    };

    private string ConnectButtonTitle => hookStatus switch
    {
        HooksInstallerStatus.Connected => "Disconnect",
        HooksInstallerStatus.Stale => "Reconnect",
        _ => "Connect",
    };

    private Brush StatusColor => hookStatus switch
    {
        HooksInstallerStatus.Connected => Theme.Brushes.SettingsConnected,
        HooksInstallerStatus.NotConnected => Theme.Brushes.SettingsDisconnected,
        _ => Theme.Brushes.SettingsPartial,
    };

    private void RefreshStatus() => hookStatus = StatusPreview ?? HooksInstaller.Status();

    /// The harness shows each Connect state without reading or touching settings.json.
    internal static HooksInstallerStatus? StatusPreview { get; set; }

    private void ToggleConnection()
    {
        working = true;
        try
        {
            // "Partly connected" connects the rest; stale ("Reconnect") rewrites ours to the bin copies.
            if (hookStatus == HooksInstallerStatus.Connected) HooksInstaller.Disconnect();
            else HooksInstaller.Connect();
            hookError = null;
        }
        catch (Exception e)
        {
            hookError = e.Message;
        }
        finally
        {
            working = false;
            RefreshStatus();
            Render();
        }
    }

    // MARK: - Settings building blocks

    /// A caption title over an inset group of rows.
    internal static UIElement Group(string title, params UIElement[] rows)
    {
        var label = Kit.Text(title, Theme.Fonts.CaptionMedium, Theme.Brushes.InkTertiary);
        label.Margin = new Thickness(Theme.Size.InsetPadding, 0, 0, 0);
        label.HorizontalAlignment = HorizontalAlignment.Left;
        var inner = new ColumnStack(0, rows);
        return new ColumnStack(Theme.Size.SettingsLabelSpacing, label, new InsetGroup(inner));
    }

    /// Label on the left, control on the right.
    internal static UIElement Row(string label, UIElement control, bool enabled = true)
    {
        var text = Kit.Text(label, Theme.Fonts.Body, enabled ? Theme.Brushes.Ink : Theme.Brushes.InkTertiary);
        return new RowStack(Theme.Size.SpaceM, Kit.Flex(text), Kit.Priority(control, 1)) { MinHeight = Theme.Size.SettingsRowHeight };
    }

    private static UIElement Pills<T>(T selection, (T, string)[] options, Action<T> select) where T : notnull
        => new SegmentedPills<T>(selection, options, select);

    internal static UIElement Switch(bool isOn, Action<bool> set) => new SmallSwitch(isOn, set);

    /// A control that does nothing right now (peek edits while peeks are off).
    private static UIElement Dimmed(UIElement control, bool enabled)
    {
        control.Opacity = enabled ? 1 : Theme.Opacity.Disabled;
        control.IsEnabled = enabled;
        return control;
    }
}
