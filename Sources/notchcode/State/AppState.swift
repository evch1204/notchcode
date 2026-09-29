// AppState.swift
// The single source of truth for the UI. Receives hook envelopes, keeps
// sessions and pending requests, and derives which state the notch shows.

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject, HookEventSink, TranscriptWatcherSink {

    // MARK: Published state

    @Published var sessions: [Session] = []
    @Published var pending: [PendingRequest] = [] {
        didSet {
            // A new request under the owner's fingers: ⏎ or ⌫ typed for the terminal must not
            // answer it. Answers wait `requestKeyGuard`, keys and clicks alike (`answer(_:to:)`).
            if let id = pending.first?.id, id != oldValue.first?.id {
                answerKeysAllowedAt = Date().addingTimeInterval(Theme.Timing.requestKeyGuard)
                // The request takes the well; the Files filter is gone, so it must not keep the keys.
                fileFilterFocused = false
            }
        }
    }
    /// Answers (⏎, ⌫, A, E, or a click on an action) are ignored before this moment.
    var answerKeysAllowedAt = Date.distantPast
    @Published var peek: Peek?
    @Published private(set) var mode: NotchMode = .closed
    @Published var isCardOpen = false
    @Published var question: QuestionPreview? {
        didSet {
            // The question went away while the card showed it: the card falls back to the
            // selected tool, so the well, the filled tool, the bridge and the height agree.
            if question == nil, questionShown { questionShown = false }
        }
    }
    /// The card shows the question (it opened on it) rather than the selected tool.
    @Published var questionShown = false
    /// The card opened for a request; it closes again once no request waits.
    var cardOpenedForRequest = false
    @Published var layout = NotchLayout.fallback
    @Published var turnStarts: [String: Date] = [:]
    @Published var turnTitles: [String: String] = [:]

    @Published var usage = UsageSnapshot()
    /// When the status line last reported the 5-hour and weekly limits. The status line only
    /// reports when Claude Code redraws it, so the last known values stay on screen and
    /// this date is shown beside them ("updated 3m ago").
    @Published var limitsUpdatedAt: Date?
    /// Per session, what the status line reported: real context, cost and model id.
    @Published var statusline: [String: StatuslineFacts] = [:]
    /// cwd -> the session id of the most recently written transcript in that folder.
    @Published var newestSessionByCWD: [String: String] = [:]
    @Published var turnsBySession: [String: [TranscriptTurn]] = [:]
    /// Files a Bash command changed, per session and turn id, in first-seen order. Built from
    /// the hook's working-tree reports; `turns(for:)` merges them into each turn's files.
    /// Held under `pendingTurnKey` until the transcript brings the turn they belong to.
    @Published var shellFiles: [String: [String: [FileChange]]] = [:]
    @Published var selectedTab: CardTab = .sessions {
        didSet {
            guard selectedTab != oldValue else { return }
            // While the card is open the pane follows one run loop later: the outgoing pane
            // renders once more with the new `tabMovedForward`, so its removal transition
            // (captured at its last render) slides the right way. Closed, or when no tool pane
            // is on screen to leave (Settings, a request, a question), it follows at once.
            let paneToPane = CardTab.browsable.contains(oldValue) && CardTab.browsable.contains(selectedTab)
            guard isCardOpen, paneToPane else { paneTab = selectedTab; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.paneTab != self.selectedTab else { return }
                self.paneTab = self.selectedTab
            }
        }
    }
    /// The tool pane the well shows; trails `selectedTab` by one run loop while the card is open.
    @Published private(set) var paneTab: CardTab = .sessions
    /// The last tab change moved right in tab order (panes slide in from the trailing edge).
    @Published var tabMovedForward = true
    /// The mouse has rested on the shape (AppDelegate sets it after `Theme.Motion.rimDelay`).
    /// Drives the rim light and the resting name's brightness.
    @Published var hovering = false
    /// The tool whose name shows as a caption under the strip: the tool under the mouse
    /// after `Theme.Motion.toolLabelDelay`, or the tool `⇥` / `1–4` just moved to.
    @Published var toolLabel: CardTab?
    /// True for a moment after a teleport, so the shape folds instead of the usual close.
    @Published var teleportFold = false
    @Published var focusedSessionId: String? {
        didSet {
            guard focusedSessionId != oldValue else { return }
            rowCursor = 0
            fileFilter = ""
            recomputeUsage()
            if selectedTab == .files { loadRepoTree() }
            if selectedTab == .git { gitFocusChanged() }
        }
    }
    @Published var sessionCursor = 0
    /// Keyboard cursor over the file rows of the Changes or Files tab.
    @Published var rowCursor = 0
    /// Diff rows whose open state differs from their default (see `isDiffOpen`).
    @Published var diffToggled: Set<String> = []
    /// The file whose diff is open inside the current request card, if any.
    @Published var requestDiff: RequestDiffTarget?
    /// ↑↓ scroll commands for the request card's open diff.
    @Published var requestDiffScroll = RequestDiffScroll()
    /// The commit card's file row under the keyboard cursor.
    @Published var requestRowCursor = 0
    /// Turns in the Changes tab whose file list is flipped from its default (newest open, older closed).
    @Published var turnToggled: Set<String> = []

    // Files tab. Per session: the tree cursor, the file being previewed, and the folders
    // flipped from their default (top level open, deeper closed).
    /// cwd -> the repository tree, as RepoFiles last read it.
    @Published var repoTrees: [String: [FileTreeNode]] = [:]
    /// cwds whose tree is being read right now.
    @Published var repoTreesLoading: Set<String> = []
    @Published var treeCursor: [String: String] = [:]
    @Published var openedFile: [String: String] = [:]
    @Published var treeToggled: [String: Set<String>] = [:]
    /// The Files tab's name filter. Esc clears it.
    @Published var fileFilter = ""
    /// The filter field has keyboard focus: typed keys go to it, not to the card's shortcuts.
    @Published var fileFilterFocused = false
    /// The preview of the opened file, keyed "cwd|path". Only the newest few are kept.
    @Published var previews: [String: LoadedPreview] = [:]
    /// A short inline hint ("No terminal found", "Copied …") that clears itself.
    @Published var hint: String?

    /// Subagents per session id, in start order. Finished ones stay until the session ends.
    @Published var agents: [String: [Agent]] = [:]

    /// The owner's choices. Saved to UserDefaults on every change; every rule below reads it.
    @Published var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            PreferencesStore.save(prefs, extras: extraPrefs)
            if prefs.systemNotifications && !oldValue.systemNotifications {
                SystemNotifier.requestAuthorization()
            }
            if !prefs.showPeeks { peekTask?.cancel(); peek = nil }
            refresh()
        }
    }

    /// Choices Contract's `Preferences` has no field for, saved in the same blob.
    @Published var extraPrefs: ExtraPreferences {
        didSet {
            guard extraPrefs != oldValue else { return }
            PreferencesStore.save(prefs, extras: extraPrefs)
        }
    }

    /// Off in demo mode so sample sessions are not mixed with real transcripts and git state.
    var readsLocalFiles = true

    // Tool state views read but that is not `@Published`: every write goes through
    // `updateGit` (GitPanel) or the `markdownShowsCode` setter (FilesBrowser), which call
    // `objectWillChange.send()` themselves.
    /// The Git tool's state; read it through `gitPanel`, write it through `updateGit`.
    var gitStore = GitPanelState()
    var gitPollTask: Task<Void, Never>?
    var gitHoldTask: Task<Void, Never>?
    /// Session id -> a Markdown file shows its source instead of the rendered preview.
    /// In memory only: every run starts on Preview.
    var markdownSource: [String: Bool] = [:]

    // MARK: Private state (never published)

    var handlers: [String: ReplyHandler] = [:]
    var deadlineTasks: [String: Task<Void, Never>] = [:]
    /// When a Notification (or a lapsed permission) last said the session waits on the owner.
    /// `.needsYou` without a pending request lives only this long (Theme.Timing.needsYouLifetime),
    /// and any later activity for the session clears it.
    var needsYouSince: [String: Date] = [:]
    var needsYouTasks: [String: Task<Void, Never>] = [:]
    /// Sessions with a turn in progress as far as hooks know: activity seen, no Stop yet.
    var openTurns: Set<String> = []
    /// Sessions whose Stop came while agents still ran: they stay working, and the last
    /// SubagentStop finishes the turn (done peek, tallies cleared).
    var stoppedWithAgents: Set<String> = []
    /// Claude Code's own helper runs (entrypoint sdk-cli), from the transcript watcher.
    /// Their hooks are ignored: PLAN says they never show.
    var headlessIds: Set<String> = []
    var peekTask: Task<Void, Never>?
    /// Files edited in the current turn, per session, in first-edit order.
    var turnFiles: [String: [String]] = [:]
    /// Lines added and removed in the current turn, per session, from PostToolUse.
    var turnLineCounts: [String: (added: Int, removed: Int)] = [:]
    /// Per session, the working tree as the last report left it: the baseline a Bash call's
    /// report is compared against. Set at each prompt, moved on after each Bash call.
    var treeSnapshots: [String: TreeSnapshot] = [:]
    /// Lines added and removed by shell-changed files this turn, per session and absolute path
    /// (only files no Edit/Write/MultiEdit touched, so the done peek counts nothing twice).
    var turnShellCounts: [String: [String: (added: Int, removed: Int)]] = [:]
    /// External agent ids (hook agent_id or transcript tool_use id) -> the id stored in `agents`.
    var agentKeys: [String: String] = [:]
    /// Stored agent ids that came from a hook and have not yet been matched to a transcript entry.
    var unmatchedHookAgents: Set<String> = []
    /// When each session last got a hook envelope. Hooks win on state while this is recent.
    var hookSeenAt: [String: Date] = [:]
    /// Sessions a SessionEnd hook closed, and when. The watcher revives one only on newer activity.
    var endedAt: [String: Date] = [:]
    /// The transcript activity time last reported per session, to reload only what changed.
    var lastSeenActivity: [String: Date] = [:]
    /// The tab to return to when Settings closes.
    var tabBeforeSettings: CardTab = .sessions
    var hintTask: Task<Void, Never>?
    var toolLabelTask: Task<Void, Never>?
    /// Set by teleport so closing the card does not hand focus back to the previous app.
    var skipFocusReturn = false

    init() {
        prefs = PreferencesStore.load()
        extraPrefs = PreferencesStore.loadExtras()
    }

    // MARK: - Derived values for views

    var currentPending: PendingRequest? { pending.first }

    /// The session the wings and the strip's status segment are about: the one that needs the owner
    /// (the current request's first), else the most recently active live session.
    var primarySession: Session? {
        if let req = currentPending, let s = session(id: req.sessionId) { return s }
        let waiting = sessions.filter { shownState($0) == .needsYou }
        if let s = waiting.max(by: { $0.lastEventAt < $1.lastEventAt }) { return s }
        let live = sessions.filter { isLive($0) }
        return (live.isEmpty ? sessions : live).max { $0.lastEventAt < $1.lastEventAt }
    }

    /// Sessions other than `session` that still exist (not ended), for the "+N" while resting.
    func otherSessionCount(besides session: Session?) -> Int {
        sessions.filter { $0.id != session?.id && endedAt[$0.id] == nil }.count
    }

    /// Live sessions other than `session`, for the "+1" in the wings.
    func otherLiveSessionCount(besides session: Session?) -> Int {
        sessions.filter { $0.id != session?.id && isLive($0) }.count
    }

    /// The state a session shows: a pending request always reads as needs you.
    func shownState(_ session: Session) -> SessionState {
        pending.contains { $0.sessionId == session.id } ? .needsYou : session.state
    }

    /// How many sessions are in each shown state.
    struct SessionCounts {
        var working = 0, waiting = 0, done = 0, idle = 0
    }

    var sessionCounts: SessionCounts {
        var counts = SessionCounts()
        for session in sessions {
            switch shownState(session) {
            case .working: counts.working += 1
            case .needsYou: counts.waiting += 1
            case .done: counts.done += 1
            case .idle: counts.idle += 1
            }
        }
        return counts
    }

    /// Another listed session runs in the same folder, so the name alone does not tell them apart.
    func isAmbiguous(_ session: Session) -> Bool {
        guard !session.cwd.isEmpty else { return false }
        return sessions.contains { $0.id != session.id && $0.cwd == session.cwd }
    }

    /// The session whose transcript is the newest in its folder (only meaningful when ambiguous).
    func isNewest(_ session: Session) -> Bool {
        newestSessionByCWD[session.cwd] == session.id
    }

    /// When the session really started: its first transcript turn if earlier than the first hook.
    func startTime(for session: Session) -> Date {
        let first = (turnsBySession[session.id] ?? []).map { $0.startedAt }.min()
        return min(first ?? session.startedAt, session.startedAt)
    }

    var focusedSession: Session? {
        if let id = focusedSessionId, let s = session(id: id) { return s }
        return primarySession
    }

    var showingQuestion: Bool {
        if case .question = cardContent { return true }
        return false
    }

    var cardContent: CardContent {
        if let req = currentPending { return .request(req) }
        if questionShown, let question { return .question(question) }
        if selectedTab == .settings { return .settings }
        return .tool(selectedTab)
    }

    /// The card shows `tab`'s pane (not a request, the question or Settings over it).
    func isShowingTool(_ tab: CardTab) -> Bool {
        if case .tool(let shown) = cardContent { return shown == tab }
        return false
    }

    /// Height of the card below the notch row, by what it shows.
    var cardHeight: CGFloat {
        switch cardContent {
        case .request(let req):
            if isCardOpen, requestDiffPath(for: req) != nil { return Theme.Size.requestCardHeightExpanded }
            return req.kind == .commit ? Theme.Size.commitCardHeight : Theme.Size.requestCardHeight
        case .question: return Theme.Size.questionCardHeight
        case .settings, .tool(.settings): return Theme.Size.settingsCardHeight
        case .tool(.sessions): return Theme.Size.sessionsCardHeight
        case .tool(.changes): return Theme.Size.changesCardHeight
        case .tool(.files): return Theme.Size.filesCardHeight
        case .tool(.usage): return Theme.Size.usageCardHeight
        case .tool(.git): return Theme.Size.gitCardHeight
        }
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Sessions by urgency: waiting on the owner first, then working, done, idle;
    /// most recent first inside each state.
    private var sessionsByUrgency: [Session] {
        let pendingIds = Set(pending.map { $0.sessionId })
        // A waiting request ranks above a needs-you without one.
        func rank(_ s: Session) -> Int {
            HookText.urgency(shownState(s)) + (pendingIds.contains(s.id) ? 1 : 0)
        }
        return sessions.sorted { a, b in
            let ra = rank(a)
            let rb = rank(b)
            if ra != rb { return ra > rb }
            return a.lastEventAt > b.lastEventAt
        }
    }

    /// The Sessions tab's groups, one per repository. Worktrees of one repo share its name
    /// (`repoName`); a folder that is not a git worktree of anything is its own group.
    /// The group with the most urgent session comes first; inside a group, by urgency.
    var sessionGroups: [SessionGroup] {
        var groups: [SessionGroup] = []
        var index: [String: Int] = [:]
        for session in sessionsByUrgency {
            let key = Self.groupKey(session)
            if let i = index[key] {
                groups[i].sessions.append(session)
            } else {
                index[key] = groups.count
                groups.append(SessionGroup(id: key, name: session.displayName, sessions: [session]))
            }
        }
        return groups
    }

    static func groupKey(_ session: Session) -> String {
        if let repo = session.repoName { return "repo|" + repo }
        return "dir|" + (session.cwd.isEmpty ? session.id : session.cwd)
    }

    /// Sessions in the order the Sessions tab lists them: group by group, as `sessionGroups`.
    /// The keyboard cursor (`sessionCursor`) indexes this list.
    var orderedSessions: [Session] {
        sessionGroups.flatMap { $0.sessions }
    }

    func agents(for sessionId: String) -> [Agent] {
        agents[sessionId] ?? []
    }

    func runningAgents(for sessionId: String) -> [Agent] {
        agents(for: sessionId).filter { $0.isRunning }
    }

    func finishedAgentCount(for sessionId: String) -> Int {
        agents(for: sessionId).filter { !$0.isRunning }.count
    }

    var runningAgentCount: Int {
        agents.values.reduce(0) { $0 + $1.filter { $0.isRunning }.count }
    }

    /// Every running agent, most urgent session first, in start order inside a session.
    var allRunningAgents: [Agent] {
        orderedSessions.flatMap { runningAgents(for: $0.id) }
    }

    /// Stable colour slot: the agent's index among all agents its session has had.
    func agentColorIndex(_ agent: Agent) -> Int {
        agents(for: agent.sessionId).firstIndex { $0.id == agent.id } ?? 0
    }

    // MARK: - Mode

    func refresh() {
        let next: NotchMode
        if isCardOpen {
            next = .card
        } else if !pending.isEmpty {
            // "Wings only" keeps the shape one row high; the wings show the triangle instead.
            next = prefs.attentionStyle == .twoRow ? .attention : .wings
        } else if peek != nil {
            next = .peek
        } else if !sessions.contains(where: exists) {
            // No session, or every one idle for 2 h: the bare notch.
            next = .closed
        } else if sessions.contains(where: { exists($0) && ($0.state == .working || $0.state == .needsYou) }) {
            // Work in progress, or something needs the owner: the wings.
            next = .wings
        } else {
            // Sessions exist but all are done or idle: resting, unless the owner picked pure notch.
            next = prefs.idleStyle == .wings ? .resting : .closed
        }
        if next != mode { mode = next }
    }

    /// A session that keeps the notch out of `.closed`: not ended, and busy or active within 2 h.
    private func exists(_ s: Session) -> Bool {
        if endedAt[s.id] != nil { return false }
        if s.state != .idle { return true }
        return Date().timeIntervalSince(s.lastEventAt) < Theme.Timing.sessionIdleCutoff
    }

    /// A session that keeps the wings up: not ended, and driven by hooks, busy, or recently active.
    private func isLive(_ s: Session) -> Bool {
        if endedAt[s.id] != nil { return false }
        if isHookDriven(s.id) || s.state != .idle { return true }
        return Date().timeIntervalSince(s.lastEventAt) < Theme.Timing.liveSessionWindow
    }

}
