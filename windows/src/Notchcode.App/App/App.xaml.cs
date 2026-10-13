// App.xaml.cs
// Port of Sources/notchcode/App/AppDelegate.swift (the app half; the panel half is
// Notch/NotchWindow.cs). Builds the state and the notch window, copies the hook exe, starts
// the pipe server, registers the hotkey (when the owner wants it), the keyboard, the tray
// icon and the login item, then reads transcripts, or runs the demo with `--demo`.
// One instance per user: a second launch exits at once.

using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Notchcode.ClaudeCode;
using Notchcode.Demo;
using Notchcode.Features.Changes;
using Notchcode.Features.Files;
using Notchcode.Features.Git;
using Notchcode.Features.Requests;
using Notchcode.Features.Settings;
using Notchcode.Features.Sessions;
using Notchcode.Features.Usage;
using Notchcode.Notch;
using Notchcode.State;
using Notchcode.Transport;
using Notchcode.UI;

namespace Notchcode.App;

public partial class App : Application
{
    /// `--demo`: sample sessions walk every state; real transcripts and git are not read.
    public static bool DemoMode { get; private set; }

    private Mutex? instance;
    private AppState? state;
    private NotchWindow? window;
    private PipeServer? server;
    private TranscriptWatcher? watcher;
    private HotKey? hotKey;
    private KeyboardController? keyboard;
    private TrayIcon? tray;
    private DemoScript? demo;
    private Preferences? lastPrefs;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // `--connect`, `--disconnect`, `--hooks-status`: the installer runs and the app leaves.
        if (HooksInstaller.HandleCommandLine(e.Args) is { } code)
        {
            Shutdown(code);
            return;
        }
        DemoMode = e.Args.Any(a => string.Equals(a, "--demo", StringComparison.OrdinalIgnoreCase));

        // One notch per user: a second launch (the hook's `launch`, a double click) leaves.
        instance = new Mutex(true, @"Local\notchcode-" + Environment.UserName, out bool first);
        if (!first)
        {
            instance.Dispose();
            instance = null;
            Shutdown(0);
            return;
        }

        var state = new AppState();
        this.state = state;
        lastPrefs = state.Prefs;

        RegisterPanes();
        window = new NotchWindow(state);
        window.Show();

        // Hooks name the copy in %LOCALAPPDATA%\notchcode\bin; refresh it from this build
        // before any hook can reach the pipe. Writes only when the bytes differ.
        try { HooksInstaller.InstallScripts(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or HooksInstallerException) { DebugLog.Write("InstallScripts failed: " + ex.Message); }

        // The notch still works without the pipe (demo, UI); hooks just get no reply.
        server = new PipeServer(state);
        try { server.Start(); }
        catch (Exception ex) when (ex is PipeServerException or IOException) { DebugLog.Write("pipe server failed: " + ex.Message); }

        UpdateHotKey(state.Prefs.HotkeyEnabled);

        keyboard = new KeyboardController(window, key => state.HandleKey(key));
        keyboard.Install();

        tray = new TrayIcon(
            open: () => { if (!state.IsCardOpen) state.ToggleFromNotchTap(); },
            settings: state.OpenSettings,
            quit: state.Quit);
        tray.Visible = state.Prefs.ShowTrayIcon;
        SystemNotifier.Attach(tray);

        LoginItem.Apply(state.Prefs.OpenAtLogin);

        state.PropertyChanged += OnStateChanged;

        if (DemoMode)
        {
            demo = new DemoScript(state);
            demo.Start();
        }
        else
        {
            // Sessions from the last hours, read straight from %USERPROFILE%\.claude\projects.
            watcher = new TranscriptWatcher(state);
            watcher.Start();
            // Plan limits from Claude Code's usage cache, refreshed by `claude -p /usage`.
            state.StartPlanUsage();
            // First run, not connected: the card opens by itself on the Welcome page (PLAN, first run).
            Dispatcher.BeginInvoke(() => Welcome.OpenIfFirstRun(state), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }
        RunDebugKeys(e.Args);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        demo?.Stop();
        server?.Stop();
        watcher?.Stop();
        keyboard?.Remove();
        hotKey?.Dispose();
        tray?.Dispose();
        if (instance is not null)
        {
            instance.ReleaseMutex();
            instance.Dispose();
        }
        base.OnExit(e);
    }

    /// The well's panes, one factory per tool and one host for the request cards (CardPanes.cs).
    private static void RegisterPanes()
    {
        CardPanes.Register(CardPaneKind.Sessions, (s, _) => new SessionsTab(s));
        CardPanes.Register(CardPaneKind.Changes, (s, _) => new ChangesTab(s));
        CardPanes.Register(CardPaneKind.Files, (s, _) => new FilesTab(s));
        CardPanes.Register(CardPaneKind.Usage, (s, _) => new UsageTab(s));
        CardPanes.Register(CardPaneKind.Git, (s, _) => new GitTab(s));
        CardPanes.Register(CardPaneKind.Settings, (s, _) => new SettingsPage(s));
        // One host for the permission, commit, plan and question cards: it picks from CardContent.
        foreach (var kind in new[] { CardPaneKind.Permission, CardPaneKind.Commit, CardPaneKind.Plan, CardPaneKind.Question })
            CardPanes.Register(kind, (s, _) => new RequestCardHost(s));
    }

    // MARK: Preferences

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppState.Prefs) || state is null) return;
        var prefs = state.Prefs;
        var old = lastPrefs;
        lastPrefs = prefs;
        if (old?.HotkeyEnabled != prefs.HotkeyEnabled) UpdateHotKey(prefs.HotkeyEnabled);
        if (old?.ShowTrayIcon != prefs.ShowTrayIcon && tray is not null) tray.Visible = prefs.ShowTrayIcon;
        if (old?.OpenAtLogin != prefs.OpenAtLogin) LoginItem.Apply(prefs.OpenAtLogin);
    }

    /// Registers Alt+Space (or Ctrl+Alt+Space) while the owner wants a hotkey, and records
    /// which chord is live for Settings.
    private void UpdateHotKey(bool enabled)
    {
        if (state is null) return;
        if (!enabled)
        {
            hotKey?.Dispose();
            hotKey = null;
            return;
        }
        if (hotKey is not null) return;
        var s = state;
        hotKey = new HotKey(s.ToggleFromNotchTap);
        if (hotKey.Chord is { } chord && chord != s.Prefs.HotkeyChord)
        {
            lastPrefs = s.Prefs with { HotkeyChord = chord };
            s.Prefs = lastPrefs;
        }
    }

    // MARK: --debug-keys

    /// `--debug-keys open,c,1.5,esc`: after three seconds, each name in turn, 1.2 s apart.
    /// "open" opens the card on the Git tool ("open:changes" on another); a number sleeps that
    /// many seconds; "snap:<name>" renders the window to %LOCALAPPDATA%\notchcode\snapshots\
    /// <name>.png; "hover" / "unhover" set the hover; anything else is a key (esc, enter,
    /// cmdenter, cmdb, space, up, down, tab, c, p, u, w, r, /, y, a, delete, 1 to 5).
    private async void RunDebugKeys(string[] args)
    {
        int index = Array.FindIndex(args, a => a == "--debug-keys");
        if (index < 0 || index + 1 >= args.Length || state is null) return;
        var names = args[index + 1].Split(',', StringSplitOptions.RemoveEmptyEntries);
        await Task.Delay(TimeSpan.FromSeconds(Theme.Timing.DebugKeysStart));
        foreach (var name in names)
        {
            if (double.TryParse(name, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double seconds))
            {
                await Task.Delay(TimeSpan.FromSeconds(seconds));
                continue;
            }
            DebugLog.Write("debug key " + name);
            if (name == "open") state.OpenCard(CardTab.Git);
            else if (name.StartsWith("open:", StringComparison.Ordinal) && DebugTab(name["open:".Length..]) is { } tab) state.OpenCard(tab);
            else if (name.StartsWith("snap:", StringComparison.Ordinal)) Snapshot(name["snap:".Length..]);
            else if (name == "hover") state.SetHovering(true);
            else if (name == "unhover") state.SetHovering(false);
            else if (name == "quit") { state.Quit(); return; }
            else if (DebugKey(name) is { } key) state.HandleKey(key);
            await Task.Delay(TimeSpan.FromSeconds(Theme.Timing.DebugKeysGap));
        }
    }

    private static CardTab? DebugTab(string name) =>
        CardTabs.Browsable.Cast<CardTab?>().FirstOrDefault(t => t!.Value.Label.Equals(name, StringComparison.OrdinalIgnoreCase));

    private static NotchKey? DebugKey(string name) => name switch
    {
        "esc" => NotchKey.Escape,
        "settings" => NotchKey.Settings,
        "d" => NotchKey.Diff,
        "e" => NotchKey.Edit,
        "alt-enter" => NotchKey.Teleport,
        "enter" => NotchKey.Primary,
        "cmdenter" => NotchKey.Submit,
        "cmdb" => NotchKey.ToggleTree,
        "space" => NotchKey.Toggle,
        "up" => NotchKey.Up,
        "down" => NotchKey.Down,
        "tab" => NotchKey.NextTab,
        "c" => NotchKey.Commit,
        "p" => NotchKey.MarkdownMode,
        "u" => NotchKey.Undo,
        "w" => NotchKey.Worktree,
        "r" => NotchKey.Repository,
        "/" => NotchKey.Filter,
        "y" => NotchKey.Copy,
        "a" => NotchKey.Always,
        "delete" => NotchKey.Deny,
        "1" or "2" or "3" or "4" or "5" => NotchKey.Number(int.Parse(name, System.Globalization.CultureInfo.InvariantCulture)),
        _ => null,
    };

    /// Renders the window's content (no screen capture) into a PNG.
    private void Snapshot(string name)
    {
        if (window?.Content is not FrameworkElement content) return;
        try
        {
            var dpi = VisualTreeHelper.GetDpi(content);
            int w = (int)Math.Ceiling(content.ActualWidth * dpi.DpiScaleX);
            int h = (int)Math.Ceiling(content.ActualHeight * dpi.DpiScaleY);
            var bitmap = new RenderTargetBitmap(w, h, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            bitmap.Render(content);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            string folder = Path.Combine(NotchcodePaths.SupportDirectory, "snapshots");
            Directory.CreateDirectory(folder);
            string file = Path.Combine(folder, name + ".png");
            using var stream = File.Create(file);
            encoder.Save(stream);
            DebugLog.Write($"snapshot {file} {w}x{h}");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            DebugLog.Write("snapshot failed " + ex.Message);
        }
    }
}
