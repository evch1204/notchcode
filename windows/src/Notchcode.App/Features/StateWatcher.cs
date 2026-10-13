// StateWatcher.cs
// How a pane follows AppState (SwiftUI's @ObservedObject): it listens for the published
// properties it reads while it is on screen, and coalesces a burst of changes into one call
// on the dispatcher, so one key press that sets three properties redraws the pane once.

using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using Notchcode.State;

namespace Notchcode.Features;

public sealed class StateWatcher
{
    private readonly AppState state;
    private readonly HashSet<string> rebuildOn;
    private readonly Dictionary<string, Action> after;
    private readonly Action rebuild;
    private bool rebuildPending;
    private readonly HashSet<string> afterPending = [];
    private bool scheduled;
    private readonly Dispatcher dispatcher;

    /// `rebuild` runs after any of `rebuildOn` changes; each `after` action runs after its own
    /// property changes (and after a rebuild in the same burst), for moves that keep the tree.
    public StateWatcher(FrameworkElement owner, AppState state, IEnumerable<string> rebuildOn, Action rebuild,
                        IReadOnlyDictionary<string, Action>? after = null)
    {
        this.state = state;
        this.rebuildOn = [.. rebuildOn];
        this.after = after is null ? [] : new Dictionary<string, Action>(after);
        this.rebuild = rebuild;
        dispatcher = owner.Dispatcher;
        owner.Loaded += (_, _) => { state.PropertyChanged -= Changed; state.PropertyChanged += Changed; };
        owner.Unloaded += (_, _) => state.PropertyChanged -= Changed;
        // A pane built before it is loaded (the harness renders without a window) listens at once.
        state.PropertyChanged += Changed;
    }

    private void Changed(object? sender, PropertyChangedEventArgs e)
    {
        var name = e.PropertyName ?? "";
        bool hit = false;
        if (rebuildOn.Contains(name)) { rebuildPending = true; hit = true; }
        if (after.ContainsKey(name)) { afterPending.Add(name); hit = true; }
        if (!hit || scheduled) return;
        scheduled = true;
        dispatcher.BeginInvoke(Flush, DispatcherPriority.DataBind);
    }

    /// Runs what is pending now (the harness calls it to render without waiting).
    public void Flush()
    {
        scheduled = false;
        if (rebuildPending)
        {
            rebuildPending = false;
            rebuild();
        }
        var names = afterPending.ToList();
        afterPending.Clear();
        foreach (var name in names) after[name]();
    }
}
