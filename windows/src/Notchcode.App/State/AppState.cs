// AppState.cs
// Port of Sources/notchcode/State/AppState.swift.
// The single source of truth for the UI. Receives hook envelopes, keeps
// sessions and pending requests, and derives which state the notch shows.
//
// Port conventions for every AppState partial:
// - A Swift `@Published var` is a public property whose setter goes through `Set` and raises
//   PropertyChanged. Collections are immutable (ImmutableList / ImmutableDictionary /
//   ImmutableHashSet): change one by assigning the result, `Sessions = Sessions.SetItem(i, s)`,
//   `TurnStarts = TurnStarts.SetItem(id, now)`, so the change is published and a `didSet`
//   sees the old value. Value types (records) change with `with`: `FilesTool = FilesTool with { Filter = "" }`.
// - Swift's internal, never-published vars are `internal` fields (PascalCase), mutable in place.
// - Swift `Task<Void, Never>?` timers are `CancellationTokenSource?`: cancel to stop one.
// - Dates are UTC DateTimes (`DateTime.UtcNow`).
// - Everything runs on the UI thread, as the Swift class is @MainActor.

using System.Collections.Immutable;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using Notchcode.Core;
using Notchcode.Features.Changes;
using Notchcode.Features.Files;
using Notchcode.Features.Git;
using Notchcode.Features.Usage;
using Notchcode.Notch;
using Notchcode.UI;

namespace Notchcode.State;

/// How many sessions are in each shown state.
public record struct SessionCounts(int Working, int Waiting, int Done, int Idle);

public sealed partial class AppState : INotifyPropertyChanged, IHookEventSink, ITranscriptWatcherSink
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// Raises PropertyChanged for `name`.
    public void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// Stores `value` and raises PropertyChanged when it differs from the field. Returns true on a change.
    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    // MARK: Published state

    private ImmutableList<Session> _sessions = [];
    public ImmutableList<Session> Sessions { get => _sessions; set => Set(ref _sessions, value); }

    private ImmutableList<PendingRequest> _pending = [];
    public ImmutableList<PendingRequest> Pending
    {
        get => _pending;
        set
        {
            var oldFirst = _pending.FirstOrDefault()?.Id;
            if (!Set(ref _pending, value)) return;
            // A new request under the owner's fingers: ⏎ or ⌫ typed for the terminal must not
            // answer it. Answers wait `RequestKeyGuard`, keys and clicks alike (`Answer`).
            if (value.FirstOrDefault()?.Id is { } id && id != oldFirst)
            {
                AnswerKeysAllowedAt = DateTime.UtcNow.AddSeconds(Theme.Timing.RequestKeyGuard);
                // The request takes the well; the Files filter is gone, so it must not keep the keys.
                FilesTool = FilesTool with { FilterFocused = false };
            }
        }
    }

    /// Answers (⏎, ⌫, A, E, or a click on an action) are ignored before this moment.
    public DateTime AnswerKeysAllowedAt { get; set; } = DateTime.MinValue;

    private Peek? _peek;
    public Peek? Peek { get => _peek; set => Set(ref _peek, value); }

    private NotchMode _mode = NotchMode.Closed;
    public NotchMode Mode { get => _mode; private set => Set(ref _mode, value); }

    private bool _isCardOpen;
    public bool IsCardOpen { get => _isCardOpen; set => Set(ref _isCardOpen, value); }

    private QuestionPreview? _question;
    public QuestionPreview? Question
    {
        get => _question;
        set
        {
            if (!Set(ref _question, value)) return;
            // The question went away while the card showed it: the card falls back to the
            // selected tool, so the well, the filled tool, the bridge and the height agree.
            if (value is null && QuestionShown) QuestionShown = false;
        }
    }

    private bool _questionShown;
    /// The card shows the question (it opened on it) rather than the selected tool.
    public bool QuestionShown { get => _questionShown; set => Set(ref _questionShown, value); }

    /// The card opened for a request; it closes again once no request waits.
    internal bool CardOpenedForRequest;

    private NotchLayout _layout = NotchLayout.Fallback;
    public NotchLayout Layout { get => _layout; set => Set(ref _layout, value); }

    private ImmutableDictionary<string, DateTime> _turnStarts = ImmutableDictionary<string, DateTime>.Empty;
    public ImmutableDictionary<string, DateTime> TurnStarts { get => _turnStarts; set => Set(ref _turnStarts, value); }

    private ImmutableDictionary<string, string> _turnTitles = ImmutableDictionary<string, string>.Empty;
    public ImmutableDictionary<string, string> TurnTitles { get => _turnTitles; set => Set(ref _turnTitles, value); }

    private UsageSnapshot _usage = new();
    public UsageSnapshot Usage { get => _usage; set => Set(ref _usage, value); }

    private DateTime? _limitsUpdatedAt;
    /// When the status line last reported the 5-hour and weekly limits. The status line only
    /// reports when Claude Code redraws it, so the last known values stay on screen and
    /// this date is shown beside them ("updated 3m ago").
    public DateTime? LimitsUpdatedAt { get => _limitsUpdatedAt; set => Set(ref _limitsUpdatedAt, value); }

    private ImmutableDictionary<string, StatuslineFacts> _statusline = ImmutableDictionary<string, StatuslineFacts>.Empty;
    /// Per session, what the status line reported: real context, cost and model id.
    public ImmutableDictionary<string, StatuslineFacts> Statusline { get => _statusline; set => Set(ref _statusline, value); }

    private PlanUsage? _planUsage;
    /// Claude Code's own usage cache (%USERPROFILE%\.claude.json), as last read.
    public PlanUsage? PlanUsage { get => _planUsage; set => Set(ref _planUsage, value); }

    private UsageBehaviors? _usageBehaviors;
    /// "What's contributing to your limits usage?" from the last `claude -p /usage` run.
    public UsageBehaviors? UsageBehaviors { get => _usageBehaviors; set => Set(ref _usageBehaviors, value); }

    private bool _planUsageRefreshing;
    /// A `claude -p /usage` run is under way.
    public bool PlanUsageRefreshing { get => _planUsageRefreshing; set => Set(ref _planUsageRefreshing, value); }

    private string? _planUsageNote;
    /// Null, "claude command not found" or "couldn't run claude": why the last run gave nothing.
    public string? PlanUsageNote { get => _planUsageNote; set => Set(ref _planUsageNote, value); }

    /// The plan usage schedule: the launch delay, then every `PlanUsageInterval`.
    internal CancellationTokenSource? PlanUsageTask;

    private ImmutableDictionary<string, string> _newestSessionByCwd = ImmutableDictionary.Create<string, string>(Paths.CwdComparer);
    /// cwd -> the session id of the most recently written transcript in that folder.
    public ImmutableDictionary<string, string> NewestSessionByCwd { get => _newestSessionByCwd; set => Set(ref _newestSessionByCwd, value); }

    private ImmutableDictionary<string, ImmutableList<TranscriptTurn>> _turnsBySession = ImmutableDictionary<string, ImmutableList<TranscriptTurn>>.Empty;
    public ImmutableDictionary<string, ImmutableList<TranscriptTurn>> TurnsBySession { get => _turnsBySession; set => Set(ref _turnsBySession, value); }

    private ImmutableDictionary<string, ImmutableDictionary<string, ImmutableList<FileChange>>> _shellFiles
        = ImmutableDictionary<string, ImmutableDictionary<string, ImmutableList<FileChange>>>.Empty;
    /// Files a Bash command changed, per session and turn id, in first-seen order. Built from
    /// the hook's working-tree reports; `Turns(for:)` merges them into each turn's files.
    /// Held under `PendingTurnKey` until the transcript brings the turn they belong to.
    public ImmutableDictionary<string, ImmutableDictionary<string, ImmutableList<FileChange>>> ShellFiles
    {
        get => _shellFiles;
        set => Set(ref _shellFiles, value);
    }

    /// Sessions whose saved shell changes were read back from disk (`LoadShellFiles`).
    internal HashSet<string> ShellFilesLoaded = [];

    private CardTab _selectedTab = CardTab.Sessions;
    public CardTab SelectedTab
    {
        get => _selectedTab;
        set
        {
            var oldValue = _selectedTab;
            if (!Set(ref _selectedTab, value)) return;
            // While the card is open the pane follows one dispatcher tick later: the outgoing pane
            // renders once more with the new `TabMovedForward`, so its removal transition slides
            // the right way. Closed, or when no tool pane is on screen to leave (Settings, a
            // request, a question), it follows at once.
            bool paneToPane = CardTabs.Browsable.Contains(oldValue) && CardTabs.Browsable.Contains(value);
            if (!IsCardOpen || !paneToPane) { PaneTab = value; return; }
            // No WPF application (tests): follow at once.
            var dispatcher = Application.Current?.Dispatcher;
            if (dispatcher is null) { PaneTab = value; return; }
            dispatcher.InvokeAsync(() =>
            {
                if (PaneTab != SelectedTab) PaneTab = SelectedTab;
            });
        }
    }

    private CardTab _paneTab = CardTab.Sessions;
    /// The tool pane the well shows; trails `SelectedTab` by one dispatcher tick while the card is open.
    public CardTab PaneTab { get => _paneTab; private set => Set(ref _paneTab, value); }

    private bool _tabMovedForward = true;
    /// The last tab change moved right in tab order (panes slide in from the trailing edge).
    public bool TabMovedForward { get => _tabMovedForward; set => Set(ref _tabMovedForward, value); }

    private bool _hovering;
    /// The mouse has rested on the shape (the window sets it after `Theme.Motion.RimDelay`).
    /// Drives the rim light and the resting name's brightness.
    public bool Hovering { get => _hovering; set => Set(ref _hovering, value); }

    private CardTab? _toolLabel;
    /// The tool whose name shows as a caption under the strip: the tool under the mouse
    /// after `Theme.Motion.ToolLabelDelay`, or the tool `⇥` / `1–4` just moved to.
    public CardTab? ToolLabel { get => _toolLabel; set => Set(ref _toolLabel, value); }

    private bool _teleportFold;
    /// True for a moment after a teleport, so the shape folds instead of the usual close.
    public bool TeleportFold { get => _teleportFold; set => Set(ref _teleportFold, value); }

    private string? _focusedSessionId;
    public string? FocusedSessionId
    {
        get => _focusedSessionId;
        set
        {
            if (!Set(ref _focusedSessionId, value)) return;
            RowCursor = 0;
            FilesTool = FilesTool with { Filter = "" };
            ResetChangesView();
            RecomputeUsage();
            if (SelectedTab == CardTab.Files) LoadRepoTree();
            if (SelectedTab == CardTab.Git) GitFocusChanged();
        }
    }

    private int _sessionCursor;
    public int SessionCursor { get => _sessionCursor; set => Set(ref _sessionCursor, value); }

    private int _rowCursor;
    /// Keyboard cursor over the Changes tool's stops (`ChangesCursorItems`).
    public int RowCursor { get => _rowCursor; set => Set(ref _rowCursor, value); }

    private RequestDiffTarget? _requestDiff;
    /// The file whose diff is open inside the current request card, if any.
    public RequestDiffTarget? RequestDiff { get => _requestDiff; set => Set(ref _requestDiff, value); }

    private RequestDiffScroll _requestDiffScroll = new();
    /// ↑↓ scroll commands for the request card's open diff.
    public RequestDiffScroll RequestDiffScroll { get => _requestDiffScroll; set => Set(ref _requestDiffScroll, value); }

    private int _requestRowCursor;
    /// The commit card's file row under the keyboard cursor.
    public int RequestRowCursor { get => _requestRowCursor; set => Set(ref _requestRowCursor, value); }

    private ChangesToolState _changesTool = new();
    /// Changes tool (Direction G). All reset when the focused session changes.
    public ChangesToolState ChangesTool { get => _changesTool; set => Set(ref _changesTool, value); }

    private FilesToolState _filesTool = new();
    public FilesToolState FilesTool { get => _filesTool; set => Set(ref _filesTool, value); }

    private string? _hint;
    /// A short inline hint ("No terminal found", "Copied …") that clears itself.
    public string? Hint { get => _hint; set => Set(ref _hint, value); }

    private ImmutableDictionary<string, ImmutableList<Agent>> _agents = ImmutableDictionary<string, ImmutableList<Agent>>.Empty;
    /// Subagents per session id, in start order. Finished ones stay until the session ends.
    public ImmutableDictionary<string, ImmutableList<Agent>> Agents { get => _agents; set => Set(ref _agents, value); }

    private Preferences _prefs;
    /// The owner's choices. Saved to preferences.json on every change; every rule below reads it.
    public Preferences Prefs
    {
        get => _prefs;
        set
        {
            var oldValue = _prefs;
            if (!Set(ref _prefs, value)) return;
            if (SavesPrefs) PreferencesStore.Save(value);
            if (value.SystemNotifications && !oldValue.SystemNotifications) SystemNotificationsTurnedOn();
            if (!value.ShowPeeks) { PeekTask?.Cancel(); Peek = null; }
            if (value.PlanUsageRefresh != oldValue.PlanUsageRefresh) PlanUsagePrefChanged();
            Refresh();
        }
    }

    /// Off in tests so a preference change does not write the owner's preferences.json.
    internal bool SavesPrefs = true;

    /// The owner turned system notifications on (macOS asks for authorization here).
    /// Implemented by the notifier wiring (wave 1b / 2); a no-op until then.
    partial void SystemNotificationsTurnedOn();

    /// Off in demo mode so sample sessions are not mixed with real transcripts and git state.
    internal bool ReadsLocalFiles = true;

    // Git tool state views read but that is not published: every write goes through
    // `UpdateGit` (AppState.Git), which raises PropertyChanged itself.
    /// The Git tool's state; read it through `GitPanel`, write it through `UpdateGit`.
    internal GitPanelState GitStore = new();
    internal CancellationTokenSource? GitPollTask;
    /// Target key -> the timer that ends its write's result hold.
    internal Dictionary<string, CancellationTokenSource> GitHoldTasks = [];

    // MARK: Private state (never published)

    internal Dictionary<string, ReplyHandler> Handlers = [];
    /// When a Notification (or a lapsed permission) last said the session waits on the owner.
    /// `NeedsYou` without a pending request lives only this long (Theme.Timing.NeedsYouLifetime),
    /// and any later activity for the session clears it.
    internal Dictionary<string, DateTime> NeedsYouSince = [];
    internal Dictionary<string, CancellationTokenSource> NeedsYouTasks = [];
    /// Sessions with a turn in progress as far as hooks know: activity seen, no Stop yet.
    internal HashSet<string> OpenTurns = [];
    /// Sessions whose Stop came while agents still ran: they stay working, and the last
    /// SubagentStop finishes the turn (done peek, tallies cleared).
    internal HashSet<string> StoppedWithAgents = [];
    /// Claude Code's own helper runs (entrypoint sdk-cli), from the transcript watcher.
    /// Their hooks are ignored: PLAN says they never show.
    internal HashSet<string> HeadlessIds = [];
    internal CancellationTokenSource? PeekTask;
    /// Files edited in the current turn, per session, in first-edit order.
    internal Dictionary<string, List<string>> TurnFiles = [];
    /// Lines added and removed in the current turn, per session, from PostToolUse.
    internal Dictionary<string, (int Added, int Removed)> TurnLineCounts = [];
    /// Per session, the working tree as the last report left it: the baseline a Bash call's
    /// report is compared against. Set at each prompt, moved on after each Bash call.
    internal Dictionary<string, TreeSnapshot> TreeSnapshots = [];
    /// Lines added and removed by shell-changed files this turn, per session and absolute path
    /// (only files no Edit/Write/MultiEdit touched, so the done peek counts nothing twice).
    internal Dictionary<string, Dictionary<string, (int Added, int Removed)>> TurnShellCounts = [];
    /// External agent ids (hook agent_id or transcript tool_use id) -> the id stored in `Agents`.
    internal Dictionary<string, string> AgentKeys = [];
    /// Stored agent ids that came from a hook and have not yet been matched to a transcript entry.
    internal HashSet<string> UnmatchedHookAgents = [];
    /// When each session last got a hook envelope. Hooks win on state while this is recent.
    internal Dictionary<string, DateTime> HookSeenAt = [];
    /// Sessions a SessionEnd hook closed, and when. The watcher revives one only on newer activity.
    internal Dictionary<string, DateTime> EndedAt = [];
    /// The transcript activity time last reported per session, to reload only what changed.
    internal Dictionary<string, DateTime> LastSeenActivity = [];
    /// The tab to return to when Settings closes.
    internal CardTab TabBeforeSettings = CardTab.Sessions;
    internal CancellationTokenSource? HintTask;
    internal CancellationTokenSource? ToolLabelTask;
    /// Set by teleport so closing the card does not hand focus back to the previous app.
    internal bool SkipFocusReturn;

    public AppState() : this(PreferencesStore.Load()) { }

    /// Starts from `prefs` without reading preferences.json (tests, demo).
    internal AppState(Preferences prefs, bool savesPrefs = true)
    {
        _prefs = prefs;
        SavesPrefs = savesPrefs;
    }

    // MARK: - Derived values for views

    public PendingRequest? CurrentPending => Pending.FirstOrDefault();

    /// The session the wings and the strip's status segment are about: the one that needs the owner
    /// (the current request's first), else the most recently active live session.
    public Session? PrimarySession
    {
        get
        {
            if (CurrentPending is { } req && Session(req.SessionId) is { } s) return s;
            var waiting = Sessions.Where(x => ShownState(x) == SessionState.NeedsYou).ToList();
            if (waiting.Count > 0) return MaxByLastEvent(waiting);
            var live = Sessions.Where(IsLive).ToList();
            return MaxByLastEvent(live.Count == 0 ? Sessions : live);
        }
    }

    /// Swift's `max(by:)`: the last of equal maxima wins.
    private static Session? MaxByLastEvent(IEnumerable<Session> list)
    {
        Session? best = null;
        foreach (var s in list)
            if (best is null || !(s.LastEventAt < best.LastEventAt)) best = s;
        return best;
    }

    /// Sessions other than `besides` that still exist (not ended), for the "+N" while resting.
    public int OtherSessionCount(Session? besides)
        => Sessions.Count(s => s.Id != besides?.Id && !EndedAt.ContainsKey(s.Id));

    /// Live sessions other than `besides`, for the "+1" in the wings.
    public int OtherLiveSessionCount(Session? besides)
        => Sessions.Count(s => s.Id != besides?.Id && IsLive(s));

    /// The state a session shows: a pending request always reads as needs you.
    public SessionState ShownState(Session session)
        => Pending.Any(p => p.SessionId == session.Id) ? SessionState.NeedsYou : session.State;

    public SessionCounts SessionCounts
    {
        get
        {
            var counts = new SessionCounts();
            foreach (var session in Sessions)
            {
                switch (ShownState(session))
                {
                    case SessionState.Working: counts.Working += 1; break;
                    case SessionState.NeedsYou: counts.Waiting += 1; break;
                    case SessionState.Done: counts.Done += 1; break;
                    case SessionState.Idle: counts.Idle += 1; break;
                }
            }
            return counts;
        }
    }

    /// Another listed session runs in the same folder, so the name alone does not tell them apart.
    public bool IsAmbiguous(Session session)
    {
        if (session.Cwd.Length == 0) return false;
        return Sessions.Any(s => s.Id != session.Id && Paths.CwdComparer.Equals(s.Cwd, session.Cwd));
    }

    /// The session whose transcript is the newest in its folder (only meaningful when ambiguous).
    /// The map's keys compare the Windows way (`Paths.CwdComparer`).
    public bool IsNewest(Session session)
        => NewestSessionByCwd.TryGetValue(session.Cwd, out var id) && id == session.Id;

    /// When the session really started: its first transcript turn if earlier than the first hook.
    public DateTime StartTime(Session session)
    {
        DateTime? first = TurnsBySession.TryGetValue(session.Id, out var turns) && turns.Count > 0
            ? turns.Min(t => t.StartedAt)
            : null;
        var f = first ?? session.StartedAt;
        return f < session.StartedAt ? f : session.StartedAt;
    }

    public Session? FocusedSession
    {
        get
        {
            if (FocusedSessionId is { } id && Session(id) is { } s) return s;
            return PrimarySession;
        }
    }

    public bool ShowingQuestion => CardContent is CardContent.Question;

    public CardContent CardContent
    {
        get
        {
            if (CurrentPending is { } req) return new CardContent.Request(req);
            if (QuestionShown && Question is { } question) return new CardContent.Question(question);
            if (SelectedTab == CardTab.Settings) return CardContent.Settings.Instance;
            return new CardContent.Tool(SelectedTab);
        }
    }

    /// The card shows `tab`'s pane (not a request, the question or Settings over it).
    public bool IsShowingTool(CardTab tab) => CardContent is CardContent.Tool t && t.Tab == tab;

    /// Height of the card below the notch row, by what it shows.
    public double CardHeight
    {
        get
        {
            switch (CardContent)
            {
                case CardContent.Request r:
                    var req = r.Value;
                    // A plan has no diff; the others grow while theirs is open.
                    if (req.Kind == PendingRequestKind.Plan) return Theme.Size.PlanCardHeight;
                    if (IsCardOpen && RequestDiffPath(req) is not null) return Theme.Size.RequestCardHeightExpanded;
                    return req.Kind == PendingRequestKind.Commit ? Theme.Size.CommitCardHeight : Theme.Size.RequestCardHeight;
                case CardContent.Question:
                    return Theme.Size.QuestionCardHeight;
                case CardContent.Settings:
                    return Theme.Size.SettingsCardHeight;
                case CardContent.Tool t:
                    return t.Tab switch
                    {
                        CardTab.Settings => Theme.Size.SettingsCardHeight,
                        CardTab.Sessions => Theme.Size.SessionsCardHeight,
                        CardTab.Changes => Theme.Size.ChangesCardHeight,
                        CardTab.Files => Theme.Size.FilesCardHeight,
                        CardTab.Usage => Theme.Size.UsageCardHeight,
                        _ => Theme.Size.GitCardHeight,
                    };
                default:
                    return Theme.Size.SessionsCardHeight;
            }
        }
    }

    public Session? Session(string id) => Sessions.FirstOrDefault(s => s.Id == id);

    /// Sessions by urgency: waiting on the owner first, then working, done, idle;
    /// most recent first inside each state.
    private List<Session> SessionsByUrgency
    {
        get
        {
            var pendingIds = Pending.Select(p => p.SessionId).ToHashSet();
            // A waiting request ranks above a needs-you without one.
            int Rank(Session s) => HookText.Urgency(ShownState(s)) + (pendingIds.Contains(s.Id) ? 1 : 0);
            // A stable sort, like Swift's sorted(by:) on these keys.
            return Sessions
                .OrderByDescending(Rank)
                .ThenByDescending(s => s.LastEventAt)
                .ToList();
        }
    }

    /// The Sessions tab's groups, one per repository. Worktrees of one repo share its name
    /// (`RepoName`); a folder that is not a git worktree of anything is its own group.
    /// The group with the most urgent session comes first; inside a group, by urgency.
    public List<SessionGroup> SessionGroups
    {
        get
        {
            var groups = new List<SessionGroup>();
            // Windows folders: "c:\x" and "C:/x" are one group (the Id keeps the first one's spelling).
            var index = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var session in SessionsByUrgency)
            {
                var key = GroupKey(session);
                var match = session.RepoName is null && session.Cwd.Length > 0 ? "dir|" + Paths.CwdKey(session.Cwd) : key;
                if (index.TryGetValue(match, out var i))
                {
                    groups[i].Sessions.Add(session);
                }
                else
                {
                    index[match] = groups.Count;
                    groups.Add(new SessionGroup { Id = key, Name = session.DisplayName, Sessions = [session] });
                }
            }
            return groups;
        }
    }

    public static string GroupKey(Session session)
    {
        if (session.RepoName is { } repo) return "repo|" + repo;
        return "dir|" + (session.Cwd.Length == 0 ? session.Id : session.Cwd);
    }

    /// Sessions in the order the Sessions tab lists them: group by group, as `SessionGroups`.
    /// The keyboard cursor (`SessionCursor`) indexes this list.
    public List<Session> OrderedSessions => SessionGroups.SelectMany(g => g.Sessions).ToList();

    /// Swift `agents(for:)`.
    public ImmutableList<Agent> AgentsFor(string sessionId)
        => Agents.TryGetValue(sessionId, out var list) ? list : [];

    public List<Agent> RunningAgents(string sessionId) => AgentsFor(sessionId).Where(a => a.IsRunning).ToList();

    public int RunningAgentCount => Agents.Values.Sum(list => list.Count(a => a.IsRunning));

    /// Stable colour slot: the agent's index among all agents its session has had.
    public int AgentColorIndex(Agent agent)
    {
        var i = AgentsFor(agent.SessionId).FindIndex(a => a.Id == agent.Id);
        return i < 0 ? 0 : i;
    }

    // MARK: - Mode

    public void Refresh()
    {
        NotchMode next;
        if (IsCardOpen)
        {
            next = NotchMode.Card;
        }
        else if (!Pending.IsEmpty)
        {
            // "Wings only" keeps the shape one row high; the wings show the triangle instead.
            next = Prefs.AttentionStyle == AttentionStyle.TwoRow ? NotchMode.Attention : NotchMode.Wings;
        }
        else if (Peek is not null)
        {
            next = NotchMode.Peek;
        }
        else if (!Sessions.Any(Exists))
        {
            // No session, or every one idle for 2 h: the bare notch.
            next = NotchMode.Closed;
        }
        else if (Sessions.Any(s => Exists(s) && (s.State == SessionState.Working || s.State == SessionState.NeedsYou)))
        {
            // Work in progress, or something needs the owner: the wings.
            next = NotchMode.Wings;
        }
        else
        {
            // Sessions exist but all are done or idle: resting, unless the owner picked pure notch.
            next = Prefs.IdleStyle == IdleStyle.Wings ? NotchMode.Resting : NotchMode.Closed;
        }
        if (next != Mode) Mode = next;
    }

    /// A session that keeps the notch out of `Closed`: not ended, and busy or active within 2 h.
    private bool Exists(Session s)
    {
        if (EndedAt.ContainsKey(s.Id)) return false;
        if (s.State != SessionState.Idle) return true;
        return (DateTime.UtcNow - s.LastEventAt).TotalSeconds < Theme.Timing.SessionIdleCutoff;
    }

    /// A session that keeps the wings up: not ended, and driven by hooks, busy, or recently active.
    private bool IsLive(Session s)
    {
        if (EndedAt.ContainsKey(s.Id)) return false;
        if (IsHookDriven(s.Id) || s.State != SessionState.Idle) return true;
        return (DateTime.UtcNow - s.LastEventAt).TotalSeconds < Theme.Timing.LiveSessionWindow;
    }
}
