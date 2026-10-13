// SystemNotifier.cs
// Port of Sources/notchcode/App/SystemNotifier.swift: an optional system notification for
// blocking events (Settings → "When Claude needs you", `prefs.SystemNotifications`, off by
// default). On Windows it is a tray balloon (NIF_INFO), no package dependency. Clicking it
// opens the card. The app wires the tray icon in at launch.

namespace Notchcode.App;

public static class SystemNotifier
{
    private static TrayIcon? tray;
    private static string? shownId;

    /// Set once at launch.
    public static void Attach(TrayIcon icon) => tray = icon;

    /// macOS asks for permission here; Windows needs none.
    public static void RequestAuthorization() { }

    /// Posts a balloon. `subtitle` leads the body (a balloon has a title and one text).
    public static void Post(string title, string? subtitle, string body, string id)
    {
        if (tray is null) return;
        shownId = id;
        tray.ShowBalloon(title, subtitle is null ? body : subtitle + "\n" + body);
    }

    /// Clears the balloon once the request is answered anywhere.
    public static void Remove(string id)
    {
        if (tray is null || shownId != id) return;
        shownId = null;
        tray.ClearBalloon();
    }
}
