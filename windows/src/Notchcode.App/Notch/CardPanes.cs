// CardPanes.cs
// What the card's well shows for each `CardContent`: a registry the panes fill in. Wave 1b
// ships a placeholder per pane (a centred caption naming the wave that builds it); in wave 2
// the feature waves register their real panes, e.g. at startup:
//
//     CardPanes.Register(CardPaneKind.Sessions, (state, _) => new SessionsTab(state));
//     CardPanes.Register(CardPaneKind.Permission, (state, c) => new PermissionCard(state, ((CardContent.Request)c).Value));
//
// The well asks `Resolve` once per change of `KeyOf`, so a pane is built once per tool, request
// or question and keeps its own state while it shows.

using System.Windows;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Notch;

/// The panes the well can show (CardView.swift's `well` and `tabBody` switches).
public enum CardPaneKind { Sessions, Changes, Files, Git, Usage, Settings, Permission, Commit, Plan, Question }

public static class CardPanes
{
    private static readonly Dictionary<CardPaneKind, Func<AppState, CardContent, FrameworkElement>> factories = [];

    /// Who builds each placeholder's real pane.
    private static readonly Dictionary<CardPaneKind, string> owners = new()
    {
        [CardPaneKind.Sessions] = "wave 1c",
        [CardPaneKind.Changes] = "wave 1c",
        [CardPaneKind.Files] = "wave 1c",
        [CardPaneKind.Usage] = "wave 1c",
        [CardPaneKind.Git] = "wave 1d",
        [CardPaneKind.Settings] = "wave 1d",
        [CardPaneKind.Permission] = "wave 1d",
        [CardPaneKind.Commit] = "wave 1d",
        [CardPaneKind.Plan] = "wave 1d",
        [CardPaneKind.Question] = "wave 1d",
    };

    /// Registers (or replaces) the factory for `kind`. Called on the UI thread before the card opens.
    public static void Register(CardPaneKind kind, Func<AppState, CardContent, FrameworkElement> factory)
        => factories[kind] = factory;

    /// Which pane `content` needs. A tool's pane is its tab (`.changes` and `.settings` show
    /// Changes, as the Swift `tabBody` does).
    public static CardPaneKind KindOf(CardContent content) => content switch
    {
        CardContent.Request r => r.Value.Kind switch
        {
            PendingRequestKind.Commit => CardPaneKind.Commit,
            PendingRequestKind.Plan => CardPaneKind.Plan,
            _ => CardPaneKind.Permission,
        },
        CardContent.Question => CardPaneKind.Question,
        CardContent.Settings => CardPaneKind.Settings,
        CardContent.Tool t => t.Tab switch
        {
            CardTab.Sessions => CardPaneKind.Sessions,
            CardTab.Files => CardPaneKind.Files,
            CardTab.Usage => CardPaneKind.Usage,
            CardTab.Git => CardPaneKind.Git,
            _ => CardPaneKind.Changes,
        },
        _ => CardPaneKind.Sessions,
    };

    /// The pane's identity: a new key builds a new pane ("tool:Files", "request:<id>",
    /// "question:<session>", "settings").
    public static string KeyOf(CardContent content) => content switch
    {
        CardContent.Request r => "request:" + r.Value.Id,
        CardContent.Question q => "question:" + q.Value.SessionId + ":" + q.Value.Question,
        CardContent.Settings => "settings",
        CardContent.Tool t => "tool:" + KindOf(t),
        _ => "none",
    };

    /// Builds the pane for `content`: the registered one, else the placeholder.
    public static FrameworkElement Resolve(AppState state, CardContent content)
    {
        var kind = KindOf(content);
        if (factories.TryGetValue(kind, out var factory)) return factory(state, content);
        return new PlaceholderPane($"{kind} pane{Theme.Glyphs.Separator}{owners[kind]}");
    }
}
