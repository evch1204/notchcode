// Contract.swift
// The shared contract between the hook scripts, the socket transport, the
// transcript reader and the UI. Every other file in the app talks through
// the types in this file. Change it only by agreement; the hook scripts in
// hooks/ encode the same JSON.
//
// Wire format, one JSON object per line over a Unix domain socket at
// ~/Library/Application Support/notchcode/notchcode.sock
//
//   hook -> app   HookEnvelope
//   app  -> hook  HookReply     (only for kinds that block: permission, preTool)
//
// A hook that gets no reply within its own timeout prints nothing and exits 0,
// so Claude Code's normal terminal prompt continues.

import Foundation

// MARK: - Wire types

enum EventKind: String, Codable {
    case permission          // PermissionRequest hook. Blocking.
    case preTool = "pre_tool"      // PreToolUse hook (used for Bash git commit). Blocking.
    case postTool = "post_tool"    // PostToolUse hook (Edit / Write / MultiEdit / Bash). Passive. On Bash it carries `tree`.
    case notification        // Notification hook (idle_prompt, permission_prompt, agent_needs_input, ...). Passive.
    case stop                // Stop hook: Claude finished a turn. Passive.
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case userPrompt = "user_prompt"  // UserPromptSubmit: a new turn began. Carries `tree` (the turn's baseline).
    case subagentStart = "subagent_start"  // SubagentStart hook: payload has agent_id, agent_type. Passive.
    case subagentStop = "subagent_stop"    // SubagentStop hook. Passive.
    case statusline                        // Claude Code's status line input, forwarded by our status line script. Passive.
                                           // payload.rate_limits.five_hour / seven_day: { used_percentage, resets_at (unix s) },
                                           // plus context_window, cost, model, session_id. This is where the real limits come from.
}

/// What a hook script sends. `payload` is the raw JSON Claude Code gave the hook on stdin,
/// embedded verbatim. The hook script is plain sh with no JSON tooling, so it does not
/// extract session_id / cwd / transcript_path itself: read them through the `resolved*`
/// accessors, which fall back to the payload.
///
/// `tree` is present on `user_prompt`, and on `post_tool` when the tool was Bash, if the
/// session's cwd is inside a git work tree:
///
///   "tree": { "root": "<git toplevel>", "head": "<HEAD sha, or empty>",
///             "status_b64": base64 of `git status --porcelain=v1 --untracked-files=all`,
///             "diff_b64":   base64 of `git diff HEAD` plus each untracked file (first 20)
///                           diffed against /dev/null, capped at 256 KB,
///             "truncated":  true when that cap cut the diff }
///
/// Paths inside both texts are relative to `root`.
struct HookEnvelope: Codable {
    var v: Int = 1
    var kind: EventKind
    var id: String                  // UUID made by the hook script, echoed back in the reply
    var sessionId: String?
    var cwd: String?
    var transcriptPath: String?
    var termProgram: String?        // TERM_PROGRAM as inherited by the hook (ghostty, iTerm.app, Apple_Terminal, vscode, ...)
    var termBundleId: String?       // __CFBundleIdentifier if present
    var pid: Int?                   // the Claude Code process id (parent of the hook)
    var ts: Double                  // unix seconds
    var payload: JSONValue
    var tree: TreeReport? = nil     // the working tree, see above

    enum CodingKeys: String, CodingKey {
        case v, kind, id, cwd, ts, pid, payload, tree
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case termProgram = "term_program"
        case termBundleId = "term_bundle_id"
    }

    var resolvedSessionId: String { sessionId ?? payload["session_id"]?.stringValue ?? "unknown" }
    var resolvedCWD: String { cwd ?? payload["cwd"]?.stringValue ?? "" }
    var resolvedTranscriptPath: String? { transcriptPath ?? payload["transcript_path"]?.stringValue }
    var isBlocking: Bool { kind == .permission || kind == .preTool }
}

/// The working-tree report a hook attaches to `user_prompt` and Bash `post_tool` envelopes,
/// with the base64 texts decoded. Parsed into per-file entries by Core/Diff/UnifiedDiff.swift.
struct TreeReport: Equatable, Codable {
    var root: String                // git toplevel
    var head: String?               // HEAD's sha; nil in a repository with no commit yet
    var status: [String]            // `git status --porcelain=v1` lines: "XY path"
    var diff: String                // unified diff against HEAD, untracked files as new
    var truncated: Bool             // the hook's 256 KB cap cut `diff`

    enum CodingKeys: String, CodingKey {
        case root, head, truncated
        case statusB64 = "status_b64"
        case diffB64 = "diff_b64"
    }

    init(root: String, head: String?, status: [String], diff: String, truncated: Bool) {
        self.root = root
        self.head = head
        self.status = status
        self.diff = diff
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(String.self, forKey: .root)
        let sha = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        head = sha.isEmpty ? nil : sha
        let statusText = Self.unbase64(try c.decodeIfPresent(String.self, forKey: .statusB64))
        status = statusText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        diff = Self.unbase64(try c.decodeIfPresent(String.self, forKey: .diffB64))
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(root, forKey: .root)
        try c.encode(head ?? "", forKey: .head)
        try c.encode(Data((status.joined(separator: "\n")).utf8).base64EncodedString(), forKey: .statusB64)
        try c.encode(Data(diff.utf8).base64EncodedString(), forKey: .diffB64)
        try c.encode(truncated, forKey: .truncated)
    }

    /// Base64 to text. The 256 KB cap can split a UTF-8 sequence; that byte decodes to U+FFFD.
    private static func unbase64(_ text: String?) -> String {
        guard let text, let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Decision: String, Codable {
    case allow
    case deny
    case none   // no opinion: the hook prints nothing and the terminal prompt continues
}

/// What the app sends back for a blocking event.
struct HookReply: Codable {
    var id: String
    var decision: Decision
    var always: Bool = false        // allow and remember (the hook emits updatedPermissions)
    var reason: String? = nil
}

typealias ReplyHandler = (HookReply?) -> Void

/// The UI side implements this. The transport calls `receive` on the main actor.
/// For blocking kinds the sink MUST eventually call `reply`, or the transport
/// replies `.none` itself when the hook's deadline passes.
@MainActor
protocol HookEventSink: AnyObject {
    func receive(_ envelope: HookEnvelope, reply: @escaping ReplyHandler)
    /// The hook went away before a reply (the owner answered in the terminal, or Claude Code timed out).
    /// The sink drops the pending request and must not call its reply handler afterwards.
    func cancel(requestId: String)
    /// The transport replied "none" at its deadline. The sink drops the request without
    /// replying and treats it as unanswered (Claude Code's terminal prompt now waits).
    func timedOut(requestId: String)
}

// MARK: - Model derived from envelopes and transcripts

enum SessionState: String, Codable {
    case idle
    case working
    case needsYou
    case done
}

struct Session: Identifiable, Equatable {
    var id: String                  // session_id
    var cwd: String
    var worktreeName: String        // last path component of cwd ("ponyfish")
    var repoName: String?           // git toplevel name if different from worktree ("notchcode")
    var branch: String?
    var state: SessionState
    var verb: String?               // "Editing", "Running tests", "Thinking"
    var startedAt: Date
    var lastEventAt: Date
    var transcriptPath: String?
    var termProgram: String?
    var termBundleId: String?
    var permissionMode: String? = nil  // raw: "default", "plan", "bypassPermissions", "acceptEdits", "auto"; the transcript is the source of truth
}

/// A subagent Claude started inside a session (Agent tool). Shown as a lane under its session.
struct Agent: Identifiable, Equatable {
    var id: String                  // agent_id from the hook, or the tool_use id from the transcript
    var sessionId: String
    var type: String                // agent_type: "Explore", "general-purpose", "claude", ...
    var description: String?        // the Agent tool's short description when known from the transcript
    var startedAt: Date
    var endedAt: Date?
    var isRunning: Bool { endedAt == nil }
}

/// What the owner can change. Persisted in UserDefaults by the UI; the keys are the property
/// names. A key missing from the stored blob (a choice added later) takes its default.
struct Preferences: Equatable, Codable {
    enum IdleStyle: String, Codable, CaseIterable { case closed, wings }
    enum AttentionStyle: String, Codable, CaseIterable { case twoRow, wings }
    enum OpenGesture: String, Codable, CaseIterable { case click, hover }

    var idleStyle: IdleStyle = .wings          // what shows when sessions exist but nothing needs you
    var attentionStyle: AttentionStyle = .twoRow
    var showPeeks: Bool = true                 // passive events peek for a few seconds
    var peekSeconds: Double = 4
    var openGesture: OpenGesture = .click
    var hotkeyEnabled: Bool = true             // ⌥ space
    var showAgentsInWings: Bool = true         // the running subagent count in the closed state's wings
    var systemNotifications: Bool = false      // also post a macOS notification for blocking events
    /// Peek every file edit, not only completed turns and subagents.
    var peekEdits: Bool = false
    /// The Files tool's tree is collapsed so the preview takes the whole well (⌘B).
    var filesTreeHidden: Bool = false
    /// The small keycaps beside buttons and pills inside the card. The footer's key row and
    /// the attention row keep theirs either way; the shortcuts work either way.
    var keycapsBesideButtons: Bool = true
    /// Run `claude -p /usage` every 15 minutes for the per-model week and the limits breakdown.
    var planUsageRefresh: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        idleStyle = try c.decodeIfPresent(IdleStyle.self, forKey: .idleStyle) ?? d.idleStyle
        attentionStyle = try c.decodeIfPresent(AttentionStyle.self, forKey: .attentionStyle) ?? d.attentionStyle
        showPeeks = try c.decodeIfPresent(Bool.self, forKey: .showPeeks) ?? d.showPeeks
        peekSeconds = try c.decodeIfPresent(Double.self, forKey: .peekSeconds) ?? d.peekSeconds
        openGesture = try c.decodeIfPresent(OpenGesture.self, forKey: .openGesture) ?? d.openGesture
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        showAgentsInWings = try c.decodeIfPresent(Bool.self, forKey: .showAgentsInWings) ?? d.showAgentsInWings
        systemNotifications = try c.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? d.systemNotifications
        peekEdits = try c.decodeIfPresent(Bool.self, forKey: .peekEdits) ?? d.peekEdits
        filesTreeHidden = try c.decodeIfPresent(Bool.self, forKey: .filesTreeHidden) ?? d.filesTreeHidden
        keycapsBesideButtons = try c.decodeIfPresent(Bool.self, forKey: .keycapsBesideButtons) ?? d.keycapsBesideButtons
        planUsageRefresh = try c.decodeIfPresent(Bool.self, forKey: .planUsageRefresh) ?? d.planUsageRefresh
    }
}

/// A blocking request waiting for the owner.
struct PendingRequest: Identifiable, Equatable {
    enum Kind: Equatable { case permission, commit }
    var id: String                  // envelope id
    var kind: Kind
    var sessionId: String
    var tool: String                // "Bash", "Edit", ...
    var title: String               // "Run the tests?" / commit subject
    var detail: String              // the command, the path, or the commit body
    var reason: String?
    var files: [FileChange] = []    // commit only
    /// What "Always" would add: one line per `permission_suggestions` entry, all of which are sent back.
    var alwaysRules: [String] = []
    /// The payload's `tool_use_id`: the plugin and Connect both installed send one call twice.
    var toolUseId: String? = nil
    var receivedAt: Date
    var deadline: Date
}

struct FileChange: Identifiable, Equatable, Codable {
    var id: String { path }
    var path: String                // relative to cwd when possible
    var added: Int
    var removed: Int
    var kind: String                // "edit", "write", "new", or "shell" (a Bash command changed it; the diff is against HEAD)
    var snippet: [DiffLine] = []    // the first few lines, for peeks and small inline previews (< 8 lines)
    var patch: [DiffLine] = []      // the whole diff as Claude Code recorded it (structuredPatch), capped at 400 lines
    var patchTruncated: Bool = false
    /// The subagent that made the change (its agentId), when only subagents touched the file.
    var agentId: String? = nil
}

struct DiffLine: Equatable, Codable {
    enum Kind: String, Codable { case context, added, removed, hunk }
    var kind: Kind
    var text: String
    var oldLine: Int?
    var newLine: Int?
}

struct TokenUsage: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var total: Int { input + output + cacheRead + cacheWrite }
}

/// One prompt the owner sent and what happened after it, read from the transcript.
struct TranscriptTurn: Identifiable, Equatable {
    var id: String                  // uuid of the user message
    var prompt: String
    var startedAt: Date
    var endedAt: Date?
    var files: [FileChange]
    var tokens: TokenUsage
    var model: String?
    /// Input + cache read + cache write of the turn's last main-thread assistant message:
    /// the context size after it. Nil when the transcript did not say (demo turns).
    var contextTokens: Int? = nil
}

/// A session found by reading `~/.claude/projects` directly, with no hook involved.
/// The UI merges these with hook-driven sessions by id. Hooks win on state when both exist.
struct DiscoveredSession: Identifiable, Equatable {
    var id: String                  // session_id (the transcript file name)
    var cwd: String
    var transcriptPath: String
    var startedAt: Date
    var lastActivityAt: Date
    var state: SessionState         // inferred: working if the last line is recent and mid-turn, done if a turn just ended, idle otherwise
    var verb: String?               // from the last tool_use: "Editing", "Running", "Reading", "Thinking"
    var lastPrompt: String?
    var permissionMode: String? = nil  // raw, from the last line that carries `permissionMode`
    /// A helper run Claude Code started for itself (`entrypoint: sdk-cli`, such as naming a
    /// branch): never one of the owner's sessions. Reported so a hook-made row can be dropped.
    var isHeadless: Bool = false
}

/// Watches the projects directory and reports sessions active in the last few hours.
/// Delivered on the main actor. Implemented in ClaudeCode/TranscriptWatcher.swift.
@MainActor
protocol TranscriptWatcherSink: AnyObject {
    func transcriptsChanged(_ sessions: [DiscoveredSession])
}

/// One entry of a repository's file tree, for the Files tab. Built by Features/Files/RepoFiles.swift.
struct FileTreeNode: Identifiable, Equatable {
    var id: String { path }
    var path: String                // relative to the session's cwd
    var name: String
    var isDirectory: Bool
    var children: [FileTreeNode] = []
}

/// A file's text for the preview pane, capped. Built by Features/Files/RepoFiles.swift.
struct FilePreview: Equatable {
    var path: String
    var lines: [String]
    var truncated: Bool
    var isBinary: Bool
}

/// One of Claude Code's per-model weekly windows ("Fable"), from its usage cache.
struct ModelWeek: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var percent: Double
    var resetsAt: Date?
}

/// A share with a name: "Claude Code 98%" (the week breakdown), from the usage cache.
struct NamedShare: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var percent: Double
}

/// A gateway spend limit from the status line. Present only behind a gateway.
struct SpendLimit: Equatable {
    var percent: Double
    var resetsAt: Date?
    var usedUSD: Double?
    var limitUSD: Double?
    var period: String?
}

/// Limits and cost, when a source provides them. Every field optional: the UI degrades.
struct UsageSnapshot: Equatable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weekPercent: Double?
    var weekResetsAt: Date?
    var contextUsed: Int?
    var contextLimit: Int?
    var sessionCostUSD: Double?
    var todayCostUSD: Double?
    var todayTokens: TokenUsage?
    var sessionTokens: TokenUsage?
    /// Today's tokens and estimated cost on Fable models, from the transcripts' model ids.
    /// Claude Code's status line carries no per-model limit, so there is no Fable percent.
    var todayFableTokens: TokenUsage?
    var todayFableCostUSD: Double?
    var costIsEstimate: Bool = true // true when computed from tokens with our rate table, not reported by Claude
    /// Per-model weekly windows and where the week went, from Claude Code's usage cache.
    var modelWeeks: [ModelWeek] = []
    var weekBreakdown: [NamedShare] = []
    /// The status line's `rate_limits.spend_limit`, behind a gateway only.
    var spendLimit: SpendLimit?
}

// MARK: - JSONValue

/// A small dynamic JSON type so raw hook payloads survive decoding untouched.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    /// Nil for a number no Int can hold (Int(_:) would trap on it); a fraction is cut toward zero.
    var intValue: Int? { doubleValue.flatMap { Int(exactly: $0.rounded(.towardZero)) } }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

// MARK: - Paths

enum NotchcodePaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("notchcode", isDirectory: true)
    }
    static var socketURL: URL { supportDirectory.appendingPathComponent("notchcode.sock") }
    static var claudeProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }
    /// Claude Code's own config, which caches the last `/usage` answer (`cachedUsageUtilization`).
    static var claudeConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    /// The working folder of the headless `claude -p /usage` run, so its transcript has a project of its own.
    static var usageRunDirectory: URL { supportDirectory.appendingPathComponent("usage", isDirectory: true) }
}
