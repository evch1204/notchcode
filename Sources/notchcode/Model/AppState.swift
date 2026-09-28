// AppState.swift
// The single source of truth for the UI. Receives hook envelopes, keeps
// sessions and pending requests, and derives which state the notch shows.

import AppKit
import Combine
import SwiftUI

enum NotchMode: Hashable {
    /// `resting`: sessions exist but none works or needs the owner; a dim name, nothing moves.
    case closed, resting, wings, attention, peek, card
}

enum CardTab: Hashable {
    case changes, files, usage, sessions, permission, commit, question, settings

    /// The tabs the owner can move between with 1-4 and tab, left to right.
    static let browsable: [CardTab] = [.sessions, .changes, .files, .usage]

    var label: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .usage: return "Usage"
        case .sessions: return "Sessions"
        case .permission: return "Permission"
        case .commit: return "Commit"
        case .question: return "Question"
        case .settings: return "Settings"
        }
    }
}

/// Keys the card understands, already decoded from NSEvent.
enum NotchKey: Equatable {
    case primary, deny, always, edit, escape, nextTab, previousTab, up, down, left, right, teleport, settings, copy, quit
    /// "D": open or close a request card's diff.
    case diff
    /// "/": focus the Files tab's filter field.
    case filter
    case number(Int)
}

/// One repository in the Sessions tab: its worktrees' sessions, most urgent first.
struct SessionGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var sessions: [Session]
    /// Distinct working folders in the group.
    var worktreeCount: Int { Set(sessions.map { $0.cwd }).count }
    /// A worktree checkout, or more than one folder: the header counts worktrees.
    var hasWorktrees: Bool { worktreeCount > 1 || sessions.contains { $0.displaySub != nil } }
}

/// A file preview as loaded for the pane, with the line count when RepoFiles capped it.
struct LoadedPreview: Equatable {
    var preview: FilePreview
    /// Lines in the whole file, when the preview was truncated and the count is known.
    var totalLines: Int?
}

/// One row of the Changes tab: a turn's one-line header, or one of its files.
enum ChangesRow: Identifiable, Equatable {
    case turn(TranscriptTurn)
    case file(DiffRowItem)

    var id: String {
        switch self {
        case .turn(let turn): return AppState.turnRowKey(turn)
        case .file(let item): return item.key
        }
    }
}

/// A one-line passive notice shown for a few seconds.
/// Peeks mark completions: a finished turn, a finished subagent, and (if the owner opts in) each edit.
struct Peek: Identifiable, Equatable {
    enum Kind: Equatable { case edit, done, agent }
    var id = UUID()
    var kind: Kind
    var sessionId: String
    var title: String
    var added: Int? = nil
    var removed: Int? = nil
    var detail: String? = nil
    /// Agent peeks: the finished agent's colour slot.
    var colorIndex: Int? = nil
    var createdAt = Date()
}

/// One expandable file row in the Changes or Files tab. `key` is stable across reloads.
struct DiffRowItem: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var file: FileChange
}

/// The one file whose diff is open inside a permission or commit card.
struct RequestDiffTarget: Equatable {
    var requestId: String
    var path: String
}

/// A request card's diff moves by `delta` lines each time `seq` changes (↑↓ while it is open).
struct RequestDiffScroll: Equatable {
    var seq = 0
    var delta = 0
}

/// A weekly limit for one model family ("This week · Opus"). No real source yet; the demo sets it.
struct ModelLimit: Equatable {
    var model: String
    var percent: Double
    var resetsAt: Date?
}

/// What Claude Code's status line input said about one session. Every field optional.
struct StatuslineFacts: Equatable {
    var contextPercent: Double?
    var contextUsed: Int?
    var contextLimit: Int?
    var costUSD: Double?
    var model: String?
    var updatedAt: Date
}

/// A question Claude asked in the terminal. Read-only here: no hook can answer it.
struct QuestionPreview: Equatable {
    var sessionId: String
    var question: String
    var options: [String]
}

@MainActor
final class AppState: ObservableObject, HookEventSink, TranscriptWatcherSink {

    // MARK: Published state

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pending: [PendingRequest] = []
    @Published private(set) var peek: Peek?
    @Published private(set) var mode: NotchMode = .closed
    @Published private(set) var isCardOpen = false
    @Published private(set) var question: QuestionPreview?
    @Published private(set) var layout = NotchLayout.fallback
    @Published private(set) var turnStarts: [String: Date] = [:]
    @Published private(set) var turnTitles: [String: String] = [:]

    @Published var usage = UsageSnapshot()
    /// The per-model weekly limit, when a source provides it. Nil on real data today.
    @Published var weekModelLimit: ModelLimit?
    /// When the status line last reported the 5-hour and weekly limits. Limits older than
    /// `Theme.Motion.limitsFreshWindow` are not shown.
    @Published private(set) var limitsUpdatedAt: Date?
    /// Per session, what the status line reported: real context, cost and model id.
    @Published private(set) var statusline: [String: StatuslineFacts] = [:]
    /// cwd -> the session id of the most recently written transcript in that folder.
    @Published private(set) var newestSessionByCWD: [String: String] = [:]
    @Published var turnsBySession: [String: [TranscriptTurn]] = [:]
    @Published var selectedTab: CardTab = .sessions
    /// The last tab change moved right in tab order (panes slide in from the trailing edge).
    @Published private(set) var tabMovedForward = true
    /// The mouse has rested on the shape (AppDelegate sets it after `Theme.Motion.rimDelay`).
    /// Drives the rim light and the resting name's brightness.
    @Published private(set) var hovering = false
    /// True for a moment after a teleport, so the shape folds instead of the usual close.
    @Published private(set) var teleportFold = false
    @Published var focusedSessionId: String? {
        didSet {
            guard focusedSessionId != oldValue else { return }
            rowCursor = 0
            fileFilter = ""
            recomputeUsage()
            if selectedTab == .files { loadRepoTree() }
        }
    }
    @Published var sessionCursor = 0
    /// Keyboard cursor over the file rows of the Changes or Files tab.
    @Published var rowCursor = 0
    /// Diff rows whose open state differs from their default (see `isDiffOpen`).
    @Published var diffToggled: Set<String> = []
    /// The file whose diff is open inside the current request card, if any.
    @Published private(set) var requestDiff: RequestDiffTarget?
    /// ↑↓ scroll commands for the request card's open diff.
    @Published private(set) var requestDiffScroll = RequestDiffScroll()
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
    @Published private(set) var hint: String?

    /// Subagents per session id, in start order. Finished ones stay until the session ends.
    @Published private(set) var agents: [String: [Agent]] = [:]

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

    // MARK: Private state (never published)

    private var handlers: [String: ReplyHandler] = [:]
    private var deadlineTasks: [String: Task<Void, Never>] = [:]
    /// When a Notification (or a lapsed permission) last said the session waits on the owner.
    /// `.needsYou` without a pending request lives only this long (Theme.Motion.needsYouLifetime),
    /// and any later activity for the session clears it.
    private var needsYouSince: [String: Date] = [:]
    private var needsYouTasks: [String: Task<Void, Never>] = [:]
    /// Sessions with a turn in progress as far as hooks know: activity seen, no Stop yet.
    private var openTurns: Set<String> = []
    private var peekTask: Task<Void, Never>?
    /// Files edited in the current turn, per session, in first-edit order.
    private var turnFiles: [String: [String]] = [:]
    /// Lines added and removed in the current turn, per session, from PostToolUse.
    private var turnLineCounts: [String: (added: Int, removed: Int)] = [:]
    /// External agent ids (hook agent_id or transcript tool_use id) -> the id stored in `agents`.
    private var agentKeys: [String: String] = [:]
    /// Stored agent ids that came from a hook and have not yet been matched to a transcript entry.
    private var unmatchedHookAgents: Set<String> = []
    /// When each session last got a hook envelope. Hooks win on state while this is recent.
    private var hookSeenAt: [String: Date] = [:]
    /// Sessions a SessionEnd hook closed, and when. The watcher revives one only on newer activity.
    private var endedAt: [String: Date] = [:]
    /// The transcript activity time last reported per session, to reload only what changed.
    private var lastSeenActivity: [String: Date] = [:]
    /// The tab to return to when Settings closes.
    private var tabBeforeSettings: CardTab = .sessions
    private var hintTask: Task<Void, Never>?
    /// Set by teleport so closing the card does not hand focus back to the previous app.
    private var skipFocusReturn = false

    /// TERM_PROGRAM -> bundle id.
    static let terminalBundleIds: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "WarpTerminal": "dev.warp.Warp-Stable",
    ]

    static let terminalNames: [String: String] = [
        "ghostty": "Ghostty",
        "iTerm.app": "iTerm",
        "Apple_Terminal": "Terminal",
        "vscode": "VS Code",
        "cursor": "Cursor",
        "WarpTerminal": "Warp",
    ]

    /// Tried in order when a session has no terminal on record: the first one running wins.
    static let knownTerminalBundleIds: [String] = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    init() {
        prefs = PreferencesStore.load()
        extraPrefs = PreferencesStore.loadExtras()
    }

    // MARK: - Derived values for views

    var currentPending: PendingRequest? { pending.first }

    /// The session the wings and the card header are about: the one that needs the owner
    /// (the current request's first), else the most recently active live session.
    var primarySession: Session? {
        if let req = currentPending, let s = session(id: req.sessionId) { return s }
        let pendingIds = Set(pending.map { $0.sessionId })
        let waiting = sessions.filter { $0.state == .needsYou || pendingIds.contains($0.id) }
        if let s = waiting.max(by: { $0.lastEventAt < $1.lastEventAt }) { return s }
        let live = sessions.filter { isLive($0) }
        return (live.isEmpty ? sessions : live).max { $0.lastEventAt < $1.lastEventAt }
    }

    /// Sessions other than `session` that still exist (not ended), for the "+N" while resting.
    func otherSessionCount(besides session: Session?) -> Int {
        sessions.filter { $0.id != session?.id && endedAt[$0.id] == nil }.count
    }

    func setHovering(_ value: Bool) {
        if hovering != value { hovering = value }
    }

    /// Live sessions other than `session`, for the "+1" in the wings.
    func otherLiveSessionCount(besides session: Session?) -> Int {
        sessions.filter { $0.id != session?.id && isLive($0) }.count
    }

    /// The state a session shows: a pending request always reads as needs you.
    func shownState(_ session: Session) -> SessionState {
        pending.contains { $0.sessionId == session.id } ? .needsYou : session.state
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

    /// "fable", "opus", "sonnet", "haiku" from the model of the newest turn that names one.
    func modelShortName(for sessionId: String) -> String? {
        let model = statusline[sessionId]?.model ?? turns(for: sessionId).lazy.compactMap { $0.model }.first
        return Self.modelShortName(model)
    }

    static func modelShortName(_ model: String?) -> String? {
        guard let m = model?.lowercased() else { return nil }
        return ["fable", "opus", "sonnet", "haiku"].first { m.contains($0) }
    }

    /// Context used as 0-100, never above 100. Nil when unknown.
    var contextPercent: Double? {
        if let id = focusedSession?.id, let percent = statusline[id]?.contextPercent { return min(100, percent) }
        guard let used = usage.contextUsed, let limit = usage.contextLimit, limit > 0 else { return nil }
        return min(100, Double(used) / Double(limit) * 100)
    }

    /// The focused session's cost came from Claude Code, not from our rate table.
    var sessionCostIsReported: Bool {
        guard let id = focusedSession?.id else { return false }
        return statusline[id]?.costUSD != nil
    }

    var focusedSession: Session? {
        if let id = focusedSessionId, let s = session(id: id) { return s }
        return primarySession
    }

    var showingQuestion: Bool {
        currentPending == nil && selectedTab == .question && question != nil
    }

    /// Height of the card below the notch row, by what it shows.
    var cardHeight: CGFloat {
        if let req = currentPending {
            if isCardOpen, requestDiffPath(for: req) != nil { return Theme.Size.requestCardHeightExpanded }
            return req.kind == .commit ? Theme.Size.commitCardHeight : Theme.Size.requestCardHeight
        }
        if showingQuestion { return Theme.Size.questionCardHeight }
        switch selectedTab {
        case .settings: return Theme.Size.settingsCardHeight
        case .sessions: return Theme.Size.sessionsCardHeight
        case .changes: return Theme.Size.changesCardHeight
        case .files: return Theme.Size.filesCardHeight
        case .usage: return Theme.Size.usageCardHeight
        default: return Theme.Size.cardHeight
        }
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Sessions by urgency: waiting on the owner first, then working, done, idle;
    /// most recent first inside each state.
    private var sessionsByUrgency: [Session] {
        let pendingIds = Set(pending.map { $0.sessionId })
        func rank(_ s: Session) -> Int {
            pendingIds.contains(s.id) ? Self.urgency(.needsYou) + 1 : Self.urgency(s.state)
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

    /// The prompt of the session's current (or last) turn.
    func currentPrompt(for sessionId: String) -> String? {
        if let title = turnTitles[sessionId], !title.isEmpty { return title }
        return turns(for: sessionId).first?.prompt
    }

    /// When the current turn started, for the working clock in the Sessions tab. Nil when unknown.
    func turnStart(for session: Session) -> Date? {
        turnStarts[session.id]
    }

    func turns(for sessionId: String?) -> [TranscriptTurn] {
        guard let sessionId else { return [] }
        return (turnsBySession[sessionId] ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    /// The Changes tab's rows in display order: each turn's header, then its file rows when
    /// the turn is open. The keyboard cursor (`rowCursor`) indexes this list.
    var changesRows: [ChangesRow] {
        var rows: [ChangesRow] = []
        for (index, turn) in turns(for: focusedSession?.id).enumerated() {
            rows.append(.turn(turn))
            guard isTurnOpen(turn, newest: index == 0) else { continue }
            rows += turn.files.map { .file(DiffRowItem(key: Self.changesRowKey(turn: turn, file: $0), file: $0)) }
        }
        return rows
    }

    nonisolated static func changesRowKey(turn: TranscriptTurn, file: FileChange) -> String { "c|\(turn.id)|\(file.path)" }
    nonisolated static func turnRowKey(_ turn: TranscriptTurn) -> String { "t|\(turn.id)" }

    /// The newest turn's files show by default; older turns start folded. A turn without files never opens.
    func isTurnOpen(_ turn: TranscriptTurn, newest: Bool) -> Bool {
        guard !turn.files.isEmpty else { return false }
        return newest != turnToggled.contains(turn.id)
    }

    func toggleTurn(_ id: String) {
        if turnToggled.contains(id) { turnToggled.remove(id) } else { turnToggled.insert(id) }
    }

    /// The key of the row under the keyboard cursor in the Changes tab.
    var cursorRowKey: String? {
        guard selectedTab == .changes else { return nil }
        let rows = changesRows
        return rows.indices.contains(rowCursor) ? rows[rowCursor].id : nil
    }

    /// The lines a diff row shows: the whole patch, or the snippet when no patch was recorded.
    static func diffLines(_ file: FileChange) -> [DiffLine] {
        file.patch.isEmpty ? file.snippet : file.patch
    }

    /// Short diffs open by default; a click or ⏎ flips a row.
    func isDiffOpen(_ item: DiffRowItem) -> Bool {
        let count = Self.diffLines(item.file).count
        let openByDefault = count > 0 && count < Theme.Size.inlineSnippetMaxLines
        return openByDefault != diffToggled.contains(item.key)
    }

    func toggleDiff(_ key: String) {
        if diffToggled.contains(key) { diffToggled.remove(key) } else { diffToggled.insert(key) }
    }

    /// Moves the keyboard cursor to a row the owner clicked.
    func setRowCursor(key: String) {
        if let index = changesRows.firstIndex(where: { $0.id == key }) {
            rowCursor = index
        }
    }

    // MARK: - Request card diff

    /// The path whose diff is open in `request`'s card, if it is still one of its files.
    func requestDiffPath(for request: PendingRequest) -> String? {
        guard let target = requestDiff, target.requestId == request.id,
              request.files.contains(where: { $0.path == target.path }) else { return nil }
        return target.path
    }

    /// Opens `path`'s diff in the current request card, or closes it when it is the open one.
    /// The card grows (or shrinks) with the shape's height spring.
    func toggleRequestDiff(path: String) {
        guard let req = currentPending,
              let file = req.files.first(where: { $0.path == path }),
              !Self.diffLines(file).isEmpty else { return }
        if let index = req.files.firstIndex(where: { $0.path == path }) { requestRowCursor = index }
        let opening = requestDiffPath(for: req) != path
        withAnimation(Theme.Motion.requestDiff(expanding: opening && requestDiffPath(for: req) == nil)) {
            requestDiff = opening ? RequestDiffTarget(requestId: req.id, path: path) : nil
        }
    }

    func closeRequestDiff() {
        guard requestDiff != nil else { return }
        withAnimation(Theme.Motion.requestDiff(expanding: false)) { requestDiff = nil }
    }

    /// "D": the permission card's file, or the commit card's file under the cursor.
    private func toggleRequestDiffAtCursor(_ req: PendingRequest) -> Bool {
        let files = req.files
        guard !files.isEmpty else { return false }
        if let open = requestDiffPath(for: req) {
            toggleRequestDiff(path: open)
            return true
        }
        let index = req.kind == .commit ? max(0, min(files.count - 1, requestRowCursor)) : 0
        guard !Self.diffLines(files[index]).isEmpty else { return false }
        if !isCardOpen { openCard() }
        toggleRequestDiff(path: files[index].path)
        return true
    }

    func terminalName(for session: Session?) -> String {
        guard let program = session?.termProgram, let name = Self.terminalNames[program] else {
            return "terminal"
        }
        return name
    }

    func setNotch(width: CGFloat, height: CGFloat) {
        let next = NotchLayout(notchWidth: width, notchHeight: height)
        if next != layout { layout = next }
    }

    // MARK: - HookEventSink

    func receive(_ envelope: HookEnvelope, reply: @escaping ReplyHandler) {
        let sid = envelope.resolvedSessionId

        // The status line refreshes on its own schedule: it carries numbers, not activity,
        // so it neither creates sessions nor moves "most recently active".
        if envelope.kind == .statusline {
            handleStatusline(envelope.payload, sessionId: sid)
            return
        }

        hookSeenAt[sid] = Date()
        endedAt[sid] = nil

        if envelope.kind == .sessionEnd {
            endSession(sid)
            if envelope.isBlocking { reply(HookReply(id: envelope.id, decision: .none)) }
            refresh()
            return
        }

        touchSession(envelope)
        let payload = envelope.payload

        // Any sign that Claude moved on ends a notification's "needs you".
        switch envelope.kind {
        case .userPrompt, .preTool, .postTool, .stop, .subagentStart:
            clearNeedsYou(sid)
        default:
            break
        }
        switch envelope.kind {
        case .userPrompt, .preTool, .postTool, .subagentStart, .permission:
            openTurns.insert(sid)
        case .stop:
            openTurns.remove(sid)
        default:
            break
        }

        switch envelope.kind {
        case .permission:
            handlePermission(envelope, sessionId: sid, reply: reply)

        case .preTool:
            handlePreTool(envelope, sessionId: sid, reply: reply)

        case .postTool:
            handlePostTool(payload, sessionId: sid)
            // Turns include subagent edits; the transcript may be the only record of them.
            reloadTurns(for: sid)

        case .notification:
            handleNotification(payload, sessionId: sid)

        case .stop:
            updateSession(sid) {
                $0.state = .done
                $0.verb = nil
            }
            if question?.sessionId == sid { question = nil }
            showPeek(donePeek(for: sid))
            turnFiles[sid] = []
            turnLineCounts[sid] = nil
            reloadTurns(for: sid)

        case .userPrompt:
            let prompt = payload["prompt"]?.stringValue ?? ""
            updateSession(sid) {
                $0.state = .working
                $0.verb = "Thinking"
            }
            turnStarts[sid] = Date()
            turnTitles[sid] = prompt
            turnFiles[sid] = []
            turnLineCounts[sid] = nil
            if question?.sessionId == sid { question = nil }
            reloadTurns(for: sid)

        case .sessionStart:
            reloadTurns(for: sid)
            reloadAgents(for: sid)

        case .subagentStart:
            let agentId = payload["agent_id"]?.stringValue ?? envelope.id
            let type = payload["agent_type"]?.stringValue ?? "agent"
            let description = payload["description"]?.stringValue
            agentStarted(id: agentId, type: type, description: description, sessionId: sid, at: Date())
            // The Agent tool call that started it is already in the transcript: pick up its description.
            reloadAgents(for: sid)

        case .subagentStop:
            let agentId = payload["agent_id"]?.stringValue ?? ""
            if let agent = agentStopped(id: agentId, type: payload["agent_type"]?.stringValue, sessionId: sid, at: Date()) {
                showPeek(Peek(
                    kind: .agent,
                    sessionId: sid,
                    title: agent.type + " finished",
                    colorIndex: agentColorIndex(agent)
                ))
            }
            // The agent's edits are in the turns now.
            reloadTurns(for: sid)

        case .sessionEnd, .statusline:
            break
        }
        settle(sid)
        refresh()
    }

    /// The hook went away before a reply: the owner answered in the terminal, or Claude Code
    /// gave up on the hook. Forget the request without replying, then recompute the state.
    func cancel(requestId: String) {
        guard let sid = dropPending(requestId) else { return }
        afterPendingChange(sessionId: sid)
    }

    // MARK: - Owner actions

    func allow(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow))
    }

    func deny(id: String) {
        resolve(id, with: HookReply(id: id, decision: .deny, reason: "The owner denied this from notchcode."))
    }

    func allowAlways(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow, always: true))
    }

    /// Commit card "Edit": let Claude know the owner wants a different message.
    func requestCommitEdit(id: String) {
        resolve(id, with: HookReply(
            id: id,
            decision: .deny,
            reason: "The owner wants to change the commit message first. Ask them for the message, then commit again."
        ))
    }

    func openCard(tab: CardTab? = nil) {
        if let req = currentPending {
            selectedTab = req.kind == .commit ? .commit : .permission
            focusedSessionId = req.sessionId
        } else if let tab {
            selectedTab = tab
            if tab == .question, let q = question { focusedSessionId = q.sessionId }
        } else if !CardTab.browsable.contains(selectedTab) && selectedTab != .settings {
            selectedTab = .sessions
        }
        if focusedSessionId == nil || session(id: focusedSessionId ?? "") == nil {
            focusedSessionId = primarySession?.id
        }
        if let id = focusedSessionId, let index = orderedSessions.firstIndex(where: { $0.id == id }) {
            sessionCursor = index
        }
        if selectedTab == .files { loadRepoTree() }
        isCardOpen = true
        skipFocusReturn = false
        recomputeUsage()
        refresh()
    }

    func closeCard() {
        guard isCardOpen else { return }
        isCardOpen = false
        if !CardTab.browsable.contains(selectedTab) { selectedTab = .sessions }
        fileFilterFocused = false
        requestDiff = nil
        refresh()
    }

    /// Settings is a page inside the card. A pending request still takes the card first.
    func openSettings() {
        guard currentPending == nil else { return }
        if selectedTab != .settings {
            tabBeforeSettings = CardTab.browsable.contains(selectedTab) ? selectedTab : .sessions
        }
        if isCardOpen {
            selectTab(.settings)
        } else {
            openCard(tab: .settings)
        }
    }

    func closeSettings() {
        guard selectedTab == .settings else { return }
        selectTab(tabBeforeSettings)
    }

    /// Row click or ⏎ in the Sessions tab: show that session's changes.
    func selectSession(_ session: Session) {
        focusedSessionId = session.id
        if let index = orderedSessions.firstIndex(where: { $0.id == session.id }) {
            sessionCursor = index
        }
        rowCursor = 0
        selectTab(.changes)
    }

    /// Read once by AppDelegate when the card closes.
    func takeSkipFocusReturn() -> Bool {
        defer { skipFocusReturn = false }
        return skipFocusReturn
    }

    /// Shows a short inline hint for a couple of seconds.
    func flash(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.hintDuration))
            if Task.isCancelled { return }
            self?.hint = nil
        }
    }

    /// "y" in Changes: copies `path:line` of the first changed line of the file row under the cursor.
    func copyCursorLocation() -> Bool {
        let rows = changesRows
        guard rows.indices.contains(rowCursor), case .file(let item) = rows[rowCursor] else { return false }
        copyLocation(path: item.file.path, line: Self.firstChangedLine(item.file))
        return true
    }

    /// Puts `/abs/path:line` on the pasteboard and says so in the footer.
    func copyLocation(path relative: String, line: Int) {
        var path = relative
        if !path.hasPrefix("/"), let cwd = focusedSession?.cwd, !cwd.isEmpty {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(path):\(line)", forType: .string)
        flash("Copied " + Format.fileName(relative) + ":\(line)")
    }

    /// The new-file line number of the first added line, else the old one of the first removed line.
    static func firstChangedLine(_ file: FileChange) -> Int {
        for line in diffLines(file) {
            if line.kind == .added, let n = line.newLine { return n }
            if line.kind == .removed, let n = line.oldLine ?? line.newLine { return n }
        }
        return 1
    }

    func toggleFromNotchTap() {
        if isCardOpen {
            closeCard()
        } else if currentPending != nil {
            openCard()
        } else if question != nil {
            openCard(tab: .question)
        } else {
            // From the notch the card always lands on Sessions; only a blocking request (above) differs.
            openCard(tab: .sessions)
        }
    }

    func selectTab(_ tab: CardTab) {
        if tab != selectedTab {
            rowCursor = 0
            let order = CardTab.browsable
            if let from = order.firstIndex(of: selectedTab), let to = order.firstIndex(of: tab) {
                tabMovedForward = to > from
            } else {
                tabMovedForward = true
            }
        }
        selectedTab = tab
        if tab != .files { fileFilterFocused = false }
        if tab == .files { loadRepoTree() }
        refresh()
    }

    /// Bring the session's terminal to the front. Activates the app only; never runs a command.
    /// The session's own terminal first (bundle id, then TERM_PROGRAM), else the first known
    /// terminal that is running. With none, a short "No terminal found" hint and the card stays.
    func teleport(session: Session?) {
        let session = session ?? focusedSession
        let recorded = [session?.termBundleId, session?.termProgram.flatMap { Self.terminalBundleIds[$0] }].compactMap { $0 }
        for bundleId in recorded {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                activateAndClose(app)
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                fold {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
                }
                return
            }
        }
        for bundleId in Self.knownTerminalBundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                activateAndClose(app)
                return
            }
        }
        flash("No terminal found")
    }

    private func activateAndClose(_ app: NSRunningApplication) {
        fold { app.activate() }
    }

    /// Teleport fold: the card folds into the notch (height, then width) and the terminal is
    /// brought forward at the 0.15 s mark so it rises behind. Reduce Motion: activate at once.
    private func fold(activate: @escaping () -> Void) {
        skipFocusReturn = true
        let reduce = Theme.Motion.reduceMotion
        if isCardOpen && !reduce {
            teleportFold = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.teleportActivateAt) { activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.foldTotal) { [weak self] in
                self?.teleportFold = false
            }
        } else {
            activate()
        }
        closeCard()
    }

    /// Returns true when the key was used.
    /// ⌘Q while the card is open, or the Quit button in Settings. Pending requests are left
    /// unanswered on purpose: their hooks time out and the terminal prompt takes over.
    func quit() {
        NSApp.terminate(nil)
    }

    func handleKey(_ key: NotchKey) -> Bool {
        guard mode == .card || mode == .attention else { return false }
        if key == .quit { quit(); return true }

        let filesOpen = isCardOpen && currentPending == nil && selectedTab == .files
        if key == .escape, filesOpen, fileFilterFocused || !fileFilter.isEmpty {
            // Esc clears the filter first; a second esc closes the card.
            withAnimation(Theme.Motion.filterRows) { fileFilter = "" }
            fileFilterFocused = false
            return true
        }
        if filesOpen && fileFilterFocused {
            // Typing goes to the filter field; only the tree keys and teleport stay with the card.
            switch key {
            case .up, .down, .primary, .teleport: break
            default: return false
            }
        }

        if key == .escape {
            guard isCardOpen else { return false }
            if let req = currentPending, requestDiffPath(for: req) != nil {
                // Esc closes the diff first, then the card.
                closeRequestDiff()
            } else if selectedTab == .settings && currentPending == nil {
                closeSettings()
            } else {
                closeCard()
            }
            return true
        }
        if key == .settings {
            if isCardOpen && selectedTab == .settings {
                closeSettings()
            } else {
                openSettings()
            }
            return true
        }
        if key == .teleport {
            let ordered = orderedSessions
            if isCardOpen, currentPending == nil, selectedTab == .sessions, ordered.indices.contains(sessionCursor) {
                teleport(session: ordered[sessionCursor])
            } else {
                teleport(session: focusedSession)
            }
            return true
        }

        if let req = currentPending {
            switch key {
            case .primary: allow(id: req.id)
            case .deny: deny(id: req.id)
            case .always:
                guard req.kind == .permission else { return false }
                allowAlways(id: req.id)
            case .edit:
                guard req.kind == .commit else { return false }
                requestCommitEdit(id: req.id)
            case .diff:
                return toggleRequestDiffAtCursor(req)
            case .up, .down:
                guard isCardOpen else { return false }
                let step = key == .up ? -1 : 1
                if requestDiffPath(for: req) != nil {
                    requestDiffScroll = RequestDiffScroll(
                        seq: requestDiffScroll.seq + 1,
                        delta: step * Theme.Size.requestDiffScrollLines
                    )
                } else if req.kind == .commit, !req.files.isEmpty {
                    let shown = min(req.files.count, Theme.Size.commitMaxFileRows)
                    requestRowCursor = max(0, min(shown - 1, requestRowCursor + step))
                } else {
                    return false
                }
            default:
                return false
            }
            return true
        }

        guard isCardOpen else { return false }

        // Settings has no keys of its own beyond esc and ⌘,.
        if selectedTab == .settings { return false }

        if showingQuestion {
            switch key {
            case .primary:
                teleport(session: question.flatMap { session(id: $0.sessionId) })
                return true
            case .number:
                return true // options are read-only; swallow so nothing else reacts
            default:
                break
            }
        }

        if selectedTab == .files, let used = handleFilesKey(key) { return used }

        let rows = selectedTab == .changes ? changesRows : []

        switch key {
        case .number(let n):
            guard n >= 1 && n <= CardTab.browsable.count else { return false }
            selectTab(CardTab.browsable[n - 1])
        case .nextTab:
            cycleTab(by: 1)
        case .previousTab:
            cycleTab(by: -1)
        case .up:
            if selectedTab == .sessions, !sessions.isEmpty {
                sessionCursor = max(0, sessionCursor - 1)
            } else if !rows.isEmpty {
                rowCursor = max(0, min(rows.count - 1, rowCursor - 1))
            } else {
                return false
            }
        case .down:
            if selectedTab == .sessions, !sessions.isEmpty {
                sessionCursor = min(sessions.count - 1, sessionCursor + 1)
            } else if !rows.isEmpty {
                rowCursor = min(rows.count - 1, rowCursor + 1)
            } else {
                return false
            }
        case .primary:
            if selectedTab == .sessions {
                let ordered = orderedSessions
                guard ordered.indices.contains(sessionCursor) else { return false }
                selectSession(ordered[sessionCursor])
            } else if rows.indices.contains(rowCursor) {
                switch rows[rowCursor] {
                case .turn(let turn):
                    guard !turn.files.isEmpty else { return false }
                    withAnimation(Theme.Motion.disclosure) { toggleTurn(turn.id) }
                case .file(let item):
                    guard !Self.diffLines(item.file).isEmpty else { return false }
                    withAnimation(Theme.Motion.tap) { toggleDiff(item.key) }
                }
            } else {
                return false
            }
        case .copy:
            guard selectedTab == .changes else { return false }
            return copyCursorLocation()
        default:
            return false
        }
        return true
    }

    // MARK: - Hooks for DemoScript

    func mutateSession(_ id: String, _ change: (inout Session) -> Void) {
        updateSession(id, change)
        refresh()
    }

    func setFiles(_ files: [FileChange], forRequest id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].files = files
    }

    func setTurns(_ turns: [TranscriptTurn], for sessionId: String) {
        turnsBySession[sessionId] = turns
        recomputeUsage()
    }

    func seedTurnFiles(_ paths: [String], for sessionId: String) {
        turnFiles[sessionId] = paths
    }

    func setAgentDescription(_ description: String, agentId: String, sessionId: String) {
        let stored = agentKeys[agentId] ?? agentId
        guard var list = agents[sessionId], let index = list.firstIndex(where: { $0.id == stored }) else { return }
        list[index].description = description
        agents[sessionId] = list
    }

    func setQuestion(_ preview: QuestionPreview?) {
        question = preview
        refresh()
    }

    // MARK: - Envelope handling

    private func handlePermission(_ envelope: HookEnvelope, sessionId: String, reply: @escaping ReplyHandler) {
        let payload = envelope.payload
        let tool = payload["tool_name"]?.stringValue ?? "Tool"
        let input = payload["tool_input"]
        let now = Date()
        var request = PendingRequest(
            id: envelope.id,
            kind: .permission,
            sessionId: sessionId,
            tool: tool,
            title: Self.permissionTitle(tool: tool),
            detail: Self.permissionDetail(tool: tool, input: input),
            reason: Self.permissionReason(payload: payload),
            receivedAt: now,
            deadline: now.addingTimeInterval(Theme.Motion.permissionDeadline)
        )
        // A file change: show what it would do, and name the file in the title.
        if let proposed = Self.proposedChange(tool: tool, input: input, cwd: envelope.resolvedCWD, readsDisk: readsLocalFiles) {
            request.files = [proposed.file]
            request.title = proposed.title
            request.detail = proposed.file.path
        }
        enqueue(request, reply: reply)
        updateSession(sessionId) { $0.state = .needsYou }
    }

    private func handlePreTool(_ envelope: HookEnvelope, sessionId: String, reply: @escaping ReplyHandler) {
        let payload = envelope.payload
        let tool = payload["tool_name"]?.stringValue ?? ""
        let command = payload["tool_input"]?["command"]?.stringValue ?? ""
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if tool == "Bash" && trimmed.hasPrefix("git commit") {
            let now = Date()
            // A file with no recorded patch still opens to its snippet.
            let latestFiles = (turns(for: sessionId).first?.files ?? []).map { file -> FileChange in
                var file = file
                if file.patch.isEmpty { file.patch = file.snippet }
                return file
            }
            let request = PendingRequest(
                id: envelope.id,
                kind: .commit,
                sessionId: sessionId,
                tool: tool,
                title: Self.commitSubject(from: trimmed) ?? "git commit",
                detail: trimmed,
                reason: payload["tool_input"]?["description"]?.stringValue,
                files: latestFiles,
                receivedAt: now,
                deadline: now.addingTimeInterval(Theme.Motion.permissionDeadline)
            )
            enqueue(request, reply: reply)
            updateSession(sessionId) { $0.state = .needsYou }
            return
        }

        reply(HookReply(id: envelope.id, decision: .none))
        updateSession(sessionId) {
            $0.state = .working
            $0.verb = Self.verb(forTool: tool)
        }
    }

    private func handlePostTool(_ payload: JSONValue, sessionId: String) {
        let tool = payload["tool_name"]?.stringValue ?? ""
        guard ["Edit", "Write", "MultiEdit"].contains(tool) else { return }

        let response = payload["tool_response"]
        let input = payload["tool_input"]
        guard let path = response?["filePath"]?.stringValue ?? input?["file_path"]?.stringValue else { return }

        var added: Int?
        var removed: Int?
        if let counts = Self.patchCounts(response?["structuredPatch"]) {
            added = counts.added
            removed = counts.removed
        } else if tool == "Write", let content = input?["content"]?.stringValue {
            added = content.split(separator: "\n", omittingEmptySubsequences: false).count
            removed = 0
        }

        var files = turnFiles[sessionId] ?? []
        if !files.contains(path) { files.append(path) }
        turnFiles[sessionId] = files
        let position = (files.firstIndex(of: path) ?? 0) + 1
        let detail: String? = files.count > 1 ? "\(position) of \(files.count)" : nil
        let counts = turnLineCounts[sessionId] ?? (0, 0)
        turnLineCounts[sessionId] = (counts.added + (added ?? 0), counts.removed + (removed ?? 0))

        updateSession(sessionId) {
            $0.state = .working
            $0.verb = "Thinking"
        }
        if extraPrefs.peekEdits {
            showPeek(Peek(
                kind: .edit,
                sessionId: sessionId,
                title: Format.fileName(path),
                added: added,
                removed: removed,
                detail: detail
            ))
        }
        reloadTurns(for: sessionId)
    }

    private func handleNotification(_ payload: JSONValue, sessionId: String) {
        let type = payload["notification_type"]?.stringValue ?? ""
        let message = payload["message"]?.stringValue ?? ""
        switch type {
        case "idle_prompt":
            // Claude finished and waits for the owner to type: that is done, not blocked.
            clearNeedsYou(sessionId)
            openTurns.remove(sessionId)
            updateSession(sessionId) {
                $0.state = .done
                $0.verb = nil
            }
        case _ where type == "permission_prompt" || type == "agent_needs_input" || type.hasPrefix("elicitation"):
            openTurns.insert(sessionId)
            markNeedsYou(sessionId)
            if type == "agent_needs_input" && !message.isEmpty {
                question = QuestionPreview(sessionId: sessionId, question: message, options: [])
            }
        case "agent_completed":
            clearNeedsYou(sessionId)
            openTurns.remove(sessionId)
            updateSession(sessionId) {
                $0.state = .done
                $0.verb = nil
            }
        default:
            break
        }
    }

    /// Claude Code's status line input: `rate_limits.five_hour` / `seven_day` ({used_percentage, resets_at}),
    /// `context_window` ({used_percentage} or {used, limit}), `cost.total_cost_usd`, `model.id`.
    private func handleStatusline(_ payload: JSONValue, sessionId sid: String) {
        let now = Date()
        func resets(_ value: JSONValue?) -> Date? {
            value?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        }

        let limits = payload["rate_limits"]
        let fiveHour = limits?["five_hour"]
        let week = limits?["seven_day"]
        var next = usage
        var gotLimits = false
        if let percent = fiveHour?["used_percentage"]?.doubleValue {
            next.fiveHourPercent = min(100, max(0, percent))
            next.fiveHourResetsAt = resets(fiveHour?["resets_at"])
            gotLimits = true
        }
        if let percent = week?["used_percentage"]?.doubleValue {
            next.weekPercent = min(100, max(0, percent))
            next.weekResetsAt = resets(week?["resets_at"])
            gotLimits = true
        }
        if gotLimits { limitsUpdatedAt = now }
        if next != usage { usage = next }

        let context = payload["context_window"]
        var facts = StatuslineFacts(updatedAt: now)
        facts.contextPercent = context?["used_percentage"]?.doubleValue.map { min(100, max(0, $0)) }
        facts.contextUsed = context?["used"]?.intValue
        facts.contextLimit = (context?["limit"] ?? context?["context_window_size"])?.intValue
        facts.costUSD = payload["cost"]?["total_cost_usd"]?.doubleValue
        facts.model = payload["model"]?["id"]?.stringValue
        let hasFacts = facts.contextPercent != nil || facts.contextUsed != nil || facts.costUSD != nil || facts.model != nil
        if hasFacts, sid != "unknown" { statusline[sid] = facts }

        recomputeUsage()
    }

    /// The 5-hour and weekly numbers are recent enough to show.
    var limitsAreFresh: Bool {
        guard let at = limitsUpdatedAt else { return false }
        return Date().timeIntervalSince(at) < Theme.Motion.limitsFreshWindow
    }

    // MARK: - Sessions

    private func touchSession(_ envelope: HookEnvelope) {
        let sid = envelope.resolvedSessionId
        let now = Date()
        if let index = sessions.firstIndex(where: { $0.id == sid }) {
            var s = sessions[index]
            s.lastEventAt = now
            var transcriptChanged = false
            if let path = envelope.resolvedTranscriptPath, path != s.transcriptPath {
                s.transcriptPath = path
                transcriptChanged = true
            }
            if let term = envelope.termProgram { s.termProgram = term }
            if let bundle = envelope.termBundleId { s.termBundleId = bundle }
            if let pid = envelope.pid { s.pid = pid }
            sessions[index] = s
            if transcriptChanged { reloadAgents(for: sid) }
            return
        }

        let cwd = envelope.resolvedCWD
        let name = cwd.isEmpty ? sid : URL(fileURLWithPath: cwd).lastPathComponent
        var transcript = envelope.resolvedTranscriptPath
        var branch: String?
        var repo: String?
        if readsLocalFiles && !cwd.isEmpty {
            branch = TranscriptReader.gitBranch(cwd: cwd)
            repo = TranscriptReader.repoName(cwd: cwd)
            if transcript == nil { transcript = TranscriptReader.latestTranscriptPath(forCWD: cwd) }
        }
        let session = Session(
            id: sid,
            cwd: cwd,
            worktreeName: name,
            repoName: repo,
            branch: branch,
            state: .idle,
            verb: nil,
            startedAt: now,
            lastEventAt: now,
            transcriptPath: transcript,
            termProgram: envelope.termProgram,
            termBundleId: envelope.termBundleId,
            pid: envelope.pid
        )
        sessions.append(session)
        if transcript != nil { reloadAgents(for: sid) }
    }

    /// SessionEnd: the session stays listed (idle) until it ages out, with its agents closed.
    /// It no longer counts as hook-driven, so the transcript watcher may revive it on new activity.
    private func endSession(_ sid: String) {
        for req in pending where req.sessionId == sid {
            resolve(req.id, with: HookReply(id: req.id, decision: .none))
        }
        hookSeenAt[sid] = nil
        endedAt[sid] = Date()
        turnStarts[sid] = nil
        turnFiles[sid] = nil
        turnLineCounts[sid] = nil
        clearNeedsYou(sid)
        openTurns.remove(sid)
        updateSession(sid) {
            $0.state = .idle
            $0.verb = nil
        }
        if let list = agents[sid], list.contains(where: { $0.isRunning }) {
            agents[sid] = TranscriptReader.closeAgents(list, at: Date())
        }
        if question?.sessionId == sid { question = nil }
        if !readsLocalFiles { forgetSession(sid) }
    }

    /// Drops a session and everything kept for it.
    private func forgetSession(_ sid: String) {
        sessions.removeAll { $0.id == sid }
        turnsBySession[sid] = nil
        turnStarts[sid] = nil
        turnTitles[sid] = nil
        turnFiles[sid] = nil
        turnLineCounts[sid] = nil
        statusline[sid] = nil
        clearNeedsYou(sid)
        openTurns.remove(sid)
        if let ended = agents.removeValue(forKey: sid) {
            let ids = Set(ended.map { $0.id })
            agentKeys = agentKeys.filter { !ids.contains($0.value) }
            unmatchedHookAgents.subtract(ids)
        }
        if question?.sessionId == sid { question = nil }
        if focusedSessionId == sid { focusedSessionId = nil }
        sessionCursor = min(sessionCursor, max(0, sessions.count - 1))
    }

    private func updateSession(_ id: String, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[index]
        change(&s)
        if s != sessions[index] { sessions[index] = s }
    }

    // MARK: - Needs you

    /// Claude says it waits on the owner, with no request of ours to answer. Lasts at most
    /// `needsYouLifetime`, and less if the session does anything in the meantime.
    private func markNeedsYou(_ sid: String) {
        let now = Date()
        needsYouSince[sid] = now
        updateSession(sid) { $0.state = .needsYou }
        needsYouTasks[sid]?.cancel()
        needsYouTasks[sid] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.needsYouLifetime))
            if Task.isCancelled { return }
            guard let self, self.needsYouSince[sid] == now else { return }
            self.settle(sid)
            self.refresh()
        }
    }

    private func clearNeedsYou(_ sid: String) {
        needsYouSince[sid] = nil
        needsYouTasks.removeValue(forKey: sid)?.cancel()
    }

    private func needsYouIsFresh(_ sid: String, now: Date = Date()) -> Bool {
        guard let since = needsYouSince[sid] else { return false }
        return now.timeIntervalSince(since) < Theme.Motion.needsYouLifetime
    }

    /// Makes `.needsYou` true or gone. A pending request always means needs you; otherwise it
    /// stays only while a fresh notification backs it, then falls back to working (turn still
    /// open) or done.
    private func settle(_ sid: String) {
        guard let s = session(id: sid) else { return }
        if pending.contains(where: { $0.sessionId == sid }) {
            if s.state != .needsYou { updateSession(sid) { $0.state = .needsYou } }
            return
        }
        guard s.state == .needsYou, !needsYouIsFresh(sid) else { return }
        clearNeedsYou(sid)
        if question?.sessionId == sid { question = nil }
        let working = openTurns.contains(sid)
        updateSession(sid) {
            $0.state = working ? .working : .done
            if !working { $0.verb = nil } else if $0.verb == nil { $0.verb = "Working" }
        }
    }

    private func reloadTurns(for sid: String) {
        guard readsLocalFiles, let path = session(id: sid)?.transcriptPath else { return }
        Task.detached(priority: .utility) { [weak self] in
            let turns = (try? TranscriptReader.turns(transcriptPath: path)) ?? []
            await self?.applyTurns(turns, for: sid)
        }
    }

    private func applyTurns(_ turns: [TranscriptTurn], for sid: String) {
        guard session(id: sid) != nil else { return }
        if turnsBySession[sid] != turns {
            turnsBySession[sid] = turns
            // New edits: the open preview's text and tints may have moved.
            if isCardOpen, selectedTab == .files, sid == focusedSession?.id { reloadOpenedPreview() }
        }
        // Sessions hooks never announced: the elapsed clock runs from the open turn.
        if !isHookDriven(sid), let open = turns.max(by: { $0.startedAt < $1.startedAt }), open.endedAt == nil {
            turnStarts[sid] = open.startedAt
        }
        recomputeUsage()
    }

    /// Limits and cost from the turns on hand. Limit percentages come from elsewhere (none yet,
    /// or the demo) and survive a recompute.
    static let standardContextLimit = 200_000
    static let extendedContextLimit = 1_000_000

    /// Context window per model id. The "[1m]" suffix and the 1M-context ids get a million; everything else 200k.
    /// Transcripts drop the "[1m]" suffix, so `recomputeUsage` also switches to a million when the
    /// context in use is already past 200k.
    static func contextLimit(forModel model: String?) -> Int {
        guard let m = model?.lowercased() else { return standardContextLimit }
        if m.contains("[1m]") || m.contains("-1m") || m.contains("1m-") { return extendedContextLimit }
        return standardContextLimit
    }

    func recomputeUsage() {
        let sid = focusedSession?.id
        let reported = sid.flatMap { statusline[$0] }
        let model = reported?.model ?? sid.flatMap { turnsBySession[$0]?.last?.model }
        let limit = AppState.contextLimit(forModel: model)
        var next = UsageCalculator.snapshot(sessionId: sid, turnsBySession: turnsBySession, contextLimit: limit)
        // The status line knows the real window; prefer it to our estimate.
        if let used = reported?.contextUsed { next.contextUsed = used }
        if let reportedLimit = reported?.contextLimit, reportedLimit > 0 { next.contextLimit = reportedLimit }
        if let used = next.contextUsed, used > (next.contextLimit ?? limit) {
            next.contextLimit = max(Self.extendedContextLimit, used)
        }
        if let cost = reported?.costUSD { next.sessionCostUSD = cost }
        if next.fiveHourPercent == nil {
            next.fiveHourPercent = usage.fiveHourPercent
            next.fiveHourResetsAt = usage.fiveHourResetsAt
        }
        if next.weekPercent == nil {
            next.weekPercent = usage.weekPercent
            next.weekResetsAt = usage.weekResetsAt
        }
        if next != usage { usage = next }
    }

    // MARK: - TranscriptWatcherSink

    private func isHookDriven(_ sid: String, now: Date = Date()) -> Bool {
        guard let seen = hookSeenAt[sid] else { return false }
        return now.timeIntervalSince(seen) < Theme.Motion.hookDrivenWindow
    }

    /// Merges sessions found on disk by id. Hooks win on state for sessions they drive.
    func transcriptsChanged(_ discovered: [DiscoveredSession]) {
        guard readsLocalFiles else { return }
        let now = Date()
        var changed: [String] = []

        // The newest transcript per folder tells the owner which of two same-folder sessions is theirs.
        var newest: [String: DiscoveredSession] = [:]
        for found in discovered where !found.cwd.isEmpty {
            if let best = newest[found.cwd], best.lastActivityAt >= found.lastActivityAt { continue }
            newest[found.cwd] = found
        }
        let newestIds = newest.mapValues { $0.id }
        if newestIds != newestSessionByCWD { newestSessionByCWD = newestIds }

        for found in discovered {
            // The transcript moved on after Claude said it needed the owner: it no longer does.
            if let since = needsYouSince[found.id],
               found.lastActivityAt > since.addingTimeInterval(Theme.Motion.needsYouActivityGrace) {
                clearNeedsYou(found.id)
                settle(found.id)
            }
            if let index = sessions.firstIndex(where: { $0.id == found.id }) {
                var s = sessions[index]
                if s.transcriptPath == nil { s.transcriptPath = found.transcriptPath }
                if !isHookDriven(found.id, now: now) {
                    let endedBefore = endedAt[found.id].map { found.lastActivityAt <= $0 } ?? false
                    if !endedBefore {
                        endedAt[found.id] = nil
                        s.state = found.state
                        s.verb = found.verb
                        if let prompt = found.lastPrompt, !prompt.isEmpty { turnTitles[found.id] = prompt }
                    }
                    if found.lastActivityAt > s.lastEventAt { s.lastEventAt = found.lastActivityAt }
                }
                if s != sessions[index] { sessions[index] = s }
            } else {
                guard now.timeIntervalSince(found.lastActivityAt) < Theme.Motion.sessionIdleCutoff else { continue }
                if let ended = endedAt[found.id], found.lastActivityAt <= ended { continue }
                let cwd = found.cwd
                sessions.append(Session(
                    id: found.id,
                    cwd: cwd,
                    worktreeName: cwd.isEmpty ? found.id : URL(fileURLWithPath: cwd).lastPathComponent,
                    repoName: cwd.isEmpty ? nil : TranscriptReader.repoName(cwd: cwd),
                    branch: cwd.isEmpty ? nil : TranscriptReader.gitBranch(cwd: cwd),
                    state: found.state,
                    verb: found.verb,
                    startedAt: found.startedAt,
                    lastEventAt: found.lastActivityAt,
                    transcriptPath: found.transcriptPath,
                    termProgram: nil,
                    termBundleId: nil,
                    pid: nil
                ))
                if let prompt = found.lastPrompt, !prompt.isEmpty { turnTitles[found.id] = prompt }
            }
            if lastSeenActivity[found.id] != found.lastActivityAt {
                lastSeenActivity[found.id] = found.lastActivityAt
                changed.append(found.id)
            }
        }

        // Sessions idle past the cutoff leave the list, unless hooks still drive them or they wait on the owner.
        let pendingIds = Set(pending.map { $0.sessionId })
        let stale = sessions.filter {
            !isHookDriven($0.id, now: now) && !pendingIds.contains($0.id)
                && now.timeIntervalSince($0.lastEventAt) > Theme.Motion.sessionIdleCutoff
        }
        for s in stale {
            forgetSession(s.id)
            lastSeenActivity[s.id] = nil
            endedAt[s.id] = nil
        }

        for sid in changed where session(id: sid) != nil {
            reloadTurns(for: sid)
            reloadAgents(for: sid)
        }
        // A background subagent can keep editing while the main transcript stays quiet:
        // re-read turns for every session with a running agent (cheap when nothing changed).
        let changedSet = Set(changed)
        for s in sessions where !changedSet.contains(s.id) && !runningAgents(for: s.id).isEmpty {
            reloadTurns(for: s.id)
        }
        if focusedSessionId == nil, isCardOpen { focusedSessionId = primarySession?.id }
        refresh()
    }

    // MARK: - Subagents

    private func reloadAgents(for sid: String) {
        guard readsLocalFiles, let path = session(id: sid)?.transcriptPath else { return }
        Task.detached(priority: .utility) { [weak self] in
            let found = TranscriptReader.agents(transcriptPath: path)
            await self?.mergeTranscriptAgents(found, for: sid)
        }
    }

    private func agentStarted(id: String, type: String, description: String?, sessionId sid: String, at date: Date) {
        if agentKeys[id] != nil { return }
        var list = agents[sid] ?? []
        if list.contains(where: { $0.id == id }) { agentKeys[id] = id; return }

        // The transcript may have seen this agent first under its tool_use id.
        if let index = list.firstIndex(where: { candidate in
            candidate.isRunning && candidate.type == type && !unmatchedHookAgents.contains(candidate.id)
                && !agentKeys.contains(where: { key in key.value == candidate.id && key.key != candidate.id })
                && abs(candidate.startedAt.timeIntervalSince(date)) < Theme.Motion.agentMatchWindow
        }) {
            agentKeys[id] = list[index].id
            if list[index].description == nil { list[index].description = description }
            agents[sid] = list
            return
        }

        list.append(Agent(id: id, sessionId: sid, type: type, description: description, startedAt: date, endedAt: nil))
        agentKeys[id] = id
        unmatchedHookAgents.insert(id)
        agents[sid] = list
    }

    /// Ends the matching running agent and returns it, or nil when none matched.
    @discardableResult
    private func agentStopped(id: String, type: String?, sessionId sid: String, at date: Date) -> Agent? {
        guard var list = agents[sid] else { return nil }
        let stored = agentKeys[id] ?? id
        var index = list.firstIndex(where: { $0.id == stored && $0.isRunning })
        if index == nil, let type {
            // Unknown id: end the oldest running agent of that type.
            index = list.firstIndex(where: { $0.isRunning && $0.type == type })
        }
        guard let index else { return nil }
        list[index].endedAt = date
        agents[sid] = list
        return list[index]
    }

    private func mergeTranscriptAgents(_ found: [Agent], for sid: String) {
        guard session(id: sid) != nil else { return }
        var list = agents[sid] ?? []
        for incoming in found {
            if let stored = agentKeys[incoming.id], let index = list.firstIndex(where: { $0.id == stored }) {
                apply(incoming, to: &list[index])
                continue
            }
            if let index = list.firstIndex(where: { $0.id == incoming.id }) {
                agentKeys[incoming.id] = incoming.id
                apply(incoming, to: &list[index])
                continue
            }
            // Same agent seen by the hook under its agent_id.
            if let index = list.firstIndex(where: {
                unmatchedHookAgents.contains($0.id) && $0.type == incoming.type
                    && abs($0.startedAt.timeIntervalSince(incoming.startedAt)) < Theme.Motion.agentMatchWindow
            }) {
                unmatchedHookAgents.remove(list[index].id)
                agentKeys[incoming.id] = list[index].id
                apply(incoming, to: &list[index])
                continue
            }
            var copy = incoming
            copy.sessionId = sid
            list.append(copy)
            agentKeys[incoming.id] = incoming.id
        }
        list.sort { $0.startedAt < $1.startedAt }
        if list != (agents[sid] ?? []) { agents[sid] = list }
        refresh()
    }

    /// Fills what the transcript knows. A stop seen by the hook is never undone by an older transcript.
    private func apply(_ incoming: Agent, to agent: inout Agent) {
        if agent.description == nil { agent.description = incoming.description }
        if agent.isRunning, let ended = incoming.endedAt { agent.endedAt = ended }
    }

    // MARK: - Pending requests

    private func enqueue(_ request: PendingRequest, reply: @escaping ReplyHandler) {
        if handlers[request.id] != nil {
            // Same id twice: answer the old one so it is never left hanging.
            resolve(request.id, with: HookReply(id: request.id, decision: .none))
        }
        handlers[request.id] = reply
        pending.append(request)
        if pending.count == 1 { requestRowCursor = 0 }
        if prefs.systemNotifications {
            SystemNotifier.post(
                title: request.kind == .commit ? "Commit?" : "Allow \(request.tool)?",
                subtitle: session(id: request.sessionId)?.displayFull,
                body: request.kind == .commit ? request.title : request.detail,
                id: request.id
            )
        }

        let id = request.id
        let delay = max(0, request.deadline.timeIntervalSinceNow)
        deadlineTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            self?.resolve(id, with: HookReply(id: id, decision: .none), timedOut: true)
        }
    }

    /// Replies exactly once and forgets the request. An answer means Claude moves on; a lapsed
    /// deadline means Claude Code's own terminal prompt now waits, which still needs the owner
    /// for a short while.
    private func resolve(_ id: String, with reply: HookReply, timedOut: Bool = false) {
        guard let handler = handlers[id] else { return }
        let sid = dropPending(id)
        handler(reply)
        if let sid {
            if reply.decision != .none {
                clearNeedsYou(sid)
            } else if timedOut, !pending.contains(where: { $0.sessionId == sid }) {
                markNeedsYou(sid)
            }
        }
        afterPendingChange(sessionId: sid)
    }

    /// Forgets a request and its reply handler without replying. Returns its session id.
    @discardableResult
    private func dropPending(_ id: String) -> String? {
        guard handlers.removeValue(forKey: id) != nil else { return nil }
        deadlineTasks.removeValue(forKey: id)?.cancel()
        let sid = pending.first(where: { $0.id == id })?.sessionId
        pending.removeAll { $0.id == id }
        SystemNotifier.remove(id: id)
        return sid
    }

    /// State and card follow-up after a request left the queue.
    private func afterPendingChange(sessionId sid: String?) {
        if let sid { settle(sid) }
        if requestDiff != nil, requestDiff?.requestId != currentPending?.id {
            requestDiff = nil
            requestRowCursor = 0
        }
        if pending.isEmpty && isCardOpen && (selectedTab == .permission || selectedTab == .commit) {
            isCardOpen = false
            selectedTab = .sessions
        } else if let next = currentPending, isCardOpen {
            selectedTab = next.kind == .commit ? .commit : .permission
        }
        refresh()
    }

    // MARK: - Peek

    /// "Done · ponyfish" with the turn's file count and line totals. Falls back to the newest
    /// transcript turn when no PostToolUse was seen (the app started mid-turn).
    private func donePeek(for sid: String) -> Peek {
        let name = session(id: sid)?.displayFull ?? ""
        var fileCount = turnFiles[sid]?.count ?? 0
        var added = turnLineCounts[sid]?.added ?? 0
        var removed = turnLineCounts[sid]?.removed ?? 0
        if fileCount == 0, let last = turns(for: sid).first,
           turnStarts[sid].map({ last.startedAt >= $0.addingTimeInterval(-Theme.Motion.turnMatchSlack) }) ?? true {
            fileCount = last.files.count
            added = last.files.reduce(0) { $0 + $1.added }
            removed = last.files.reduce(0) { $0 + $1.removed }
        }
        let title = name.isEmpty ? "Done" : "Done" + Theme.Glyphs.separator + name
        guard fileCount > 0 else { return Peek(kind: .done, sessionId: sid, title: title) }
        return Peek(kind: .done, sessionId: sid, title: title, added: added, removed: removed, detail: Format.files(fileCount))
    }

    /// A click on a peek: a finished turn opens that session's Changes, a finished subagent its
    /// Sessions lane. A pending request still takes the card first.
    func tapPeek(_ tapped: Peek) {
        guard currentPending == nil, session(id: tapped.sessionId) != nil else {
            toggleFromNotchTap()
            return
        }
        peekTask?.cancel()
        peek = nil
        focusedSessionId = tapped.sessionId
        switch tapped.kind {
        case .done, .edit: openCard(tab: .changes)
        case .agent: openCard(tab: .sessions)
        }
    }

    private func showPeek(_ newPeek: Peek) {
        guard prefs.showPeeks else { return }
        peek = newPeek
        peekTask?.cancel()
        let peekId = newPeek.id
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.prefs.peekSeconds ?? Theme.Motion.peekLifetime))
            if Task.isCancelled { return }
            guard let self, self.peek?.id == peekId else { return }
            self.peek = nil
            self.refresh()
        }
        refresh()
    }

    // MARK: - Mode

    private func refresh() {
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
        return Date().timeIntervalSince(s.lastEventAt) < Theme.Motion.sessionIdleCutoff
    }

    /// A session that keeps the wings up: not ended, and driven by hooks, busy, or recently active.
    private func isLive(_ s: Session) -> Bool {
        if endedAt[s.id] != nil { return false }
        if isHookDriven(s.id) || s.state != .idle { return true }
        return Date().timeIntervalSince(s.lastEventAt) < Theme.Motion.liveSessionWindow
    }

    private func cycleTab(by step: Int) {
        let tabs = CardTab.browsable
        let current = tabs.firstIndex(of: selectedTab) ?? 0
        let next = (current + step + tabs.count) % tabs.count
        selectTab(tabs[next])
    }

    // MARK: - Parsing helpers

    static func urgency(_ state: SessionState) -> Int {
        switch state {
        case .needsYou: return 3
        case .working: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    static func verb(forTool tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running"
        case "Read", "Grep", "Glob": return "Reading"
        default: return "Thinking"
        }
    }

    static func permissionTitle(tool: String) -> String {
        switch tool {
        case "Bash": return "Run a command?"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit a file?"
        case "Write": return "Write a file?"
        case "Read": return "Read a file?"
        case "WebFetch": return "Fetch a page?"
        case "WebSearch": return "Search the web?"
        default: return "Use \(tool)?"
        }
    }

    static func permissionDetail(tool: String, input: JSONValue?) -> String {
        guard let input else { return tool }
        let keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path"]
        for key in keys {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return tool
    }

    /// Why the request is shown: the tool's own description, the payload's message, or what
    /// "Always" would remember (from `permission_suggestions`).
    static func permissionReason(payload: JSONValue) -> String? {
        if let text = payload["tool_input"]?["description"]?.stringValue, !text.isEmpty { return text }
        if let text = payload["message"]?.stringValue, !text.isEmpty { return text }
        guard let suggestion = payload["permission_suggestions"]?.arrayValue?.first else { return nil }
        let destination: String? = {
            switch suggestion["destination"]?.stringValue {
            case "session": return "for this session"
            case "localSettings": return "in this project's local settings"
            case "projectSettings": return "in this project's settings"
            case "userSettings": return "in your user settings"
            default: return nil
            }
        }()
        var text: String?
        switch suggestion["type"]?.stringValue {
        case "setMode":
            if suggestion["mode"]?.stringValue == "acceptEdits" { text = "Always accepts edits" }
        case "addRules":
            let rules = suggestion["rules"]?.arrayValue ?? []
            let names = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                if let content = rule["ruleContent"]?.stringValue, !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            if !names.isEmpty { text = "Always allows " + names.joined(separator: ", ") }
        case "addDirectories":
            let dirs = (suggestion["directories"]?.arrayValue ?? []).compactMap { $0.stringValue }
            if !dirs.isEmpty { text = "Always adds " + dirs.joined(separator: ", ") }
        default:
            break
        }
        guard let text else { return nil }
        return [text, destination].compactMap { $0 }.joined(separator: " ") + "."
    }

    /// The diff an Edit / Write / MultiEdit / NotebookEdit request would make, and the card title.
    static func proposedChange(tool: String, input: JSONValue?, cwd: String, readsDisk: Bool) -> (file: FileChange, title: String)? {
        guard let input else { return nil }
        switch tool {
        case "Edit":
            guard let path = input["file_path"]?.stringValue,
                  let old = input["old_string"]?.stringValue,
                  let new = input["new_string"]?.stringValue else { return nil }
            let file = DiffBuilder.forEdit(cwd: cwd, filePath: path, oldString: old, newString: new,
                                           replaceAll: input["replace_all"]?.boolValue ?? false, readsDisk: readsDisk)
            let title = file.kind == "new" ? "Write a new file?" : "Edit \(Format.fileName(file.path))?"
            return (file, title)
        case "Write":
            guard let path = input["file_path"]?.stringValue,
                  let content = input["content"]?.stringValue else { return nil }
            let file = DiffBuilder.forWrite(cwd: cwd, filePath: path, content: content, readsDisk: readsDisk)
            let title = file.kind == "new" ? "Write a new file?" : "Rewrite \(Format.fileName(file.path))?"
            return (file, title)
        case "MultiEdit":
            guard let path = input["file_path"]?.stringValue,
                  let list = input["edits"]?.arrayValue else { return nil }
            let edits = list.compactMap { edit -> (old: String, new: String, replaceAll: Bool)? in
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
                return (old, new, edit["replace_all"]?.boolValue ?? false)
            }
            guard !edits.isEmpty else { return nil }
            let file = DiffBuilder.forMultiEdit(cwd: cwd, filePath: path, edits: edits, readsDisk: readsDisk)
            let name = Format.fileName(file.path)
            let title = file.kind == "new" ? "Write a new file?"
                : edits.count > 1 ? "Edit \(edits.count) places in \(name)?" : "Edit \(name)?"
            return (file, title)
        case "NotebookEdit":
            // The notebook on disk is JSON, not the cell: show the new cell source as added lines.
            guard let path = input["notebook_path"]?.stringValue ?? input["file_path"]?.stringValue,
                  let source = input["new_source"]?.stringValue else { return nil }
            var file = DiffBuilder.forWrite(cwd: cwd, filePath: path, content: source, readsDisk: false)
            file.kind = "edit"
            return (file, "Edit \(Format.fileName(file.path))?")
        default:
            return nil
        }
    }

    /// Pulls the subject line out of `git commit -m "..."` or a heredoc message.
    static func commitSubject(from command: String) -> String? {
        let heredocMarkers = ["<<'EOF'", "<<\"EOF\"", "<<EOF", "<< 'EOF'", "<< EOF"]
        for marker in heredocMarkers {
            if let range = command.range(of: marker) {
                let rest = command[range.upperBound...]
                for line in rest.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty && text != "EOF" && !text.hasPrefix(")") { return text }
                }
            }
        }
        guard let flag = command.range(of: "-m ") else { return nil }
        var rest = command[flag.upperBound...].drop(while: { $0 == " " })
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        let message = rest[..<end]
        guard let first = message.split(separator: "\n").first else { return nil }
        let subject = first.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? nil : subject
    }

    /// Counts added and removed lines in a Claude Code `structuredPatch`.
    static func patchCounts(_ patch: JSONValue?) -> (added: Int, removed: Int)? {
        guard let hunks = patch?.arrayValue else { return nil }
        var added = 0
        var removed = 0
        for hunk in hunks {
            for line in hunk["lines"]?.arrayValue ?? [] {
                guard let text = line.stringValue else { continue }
                if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }
}
