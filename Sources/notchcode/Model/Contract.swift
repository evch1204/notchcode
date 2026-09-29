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
    case postTool = "post_tool"    // PostToolUse hook (Edit / Write / MultiEdit). Passive.
    case notification        // Notification hook (idle_prompt, permission_prompt, agent_needs_input, ...). Passive.
    case stop                // Stop hook: Claude finished a turn. Passive.
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case userPrompt = "user_prompt"  // UserPromptSubmit: a new turn began.
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

    enum CodingKeys: String, CodingKey {
        case v, kind, id, cwd, ts, pid, payload
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
    var pid: Int?
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

/// What the owner can change. Persisted in UserDefaults by the UI; the keys are the property names.
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
    var showAgentsInWings: Bool = true         // subagent count and lanes in the collapsed state
    var systemNotifications: Bool = false      // also post a macOS notification for blocking events
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
    var receivedAt: Date
    var deadline: Date
}

struct FileChange: Identifiable, Equatable, Codable {
    var id: String { path }
    var path: String                // relative to cwd when possible
    var added: Int
    var removed: Int
    var kind: String                // "edit", "write", "new"
    var snippet: [DiffLine] = []    // the first few lines, for peeks and small inline previews (< 8 lines)
    var patch: [DiffLine] = []      // the whole diff as Claude Code recorded it (structuredPatch), capped at 400 lines
    var patchTruncated: Bool = false
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
    var assistantSummary: String?   // first assistant text, trimmed
    var files: [FileChange]
    var tokens: TokenUsage
    var model: String?
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
    /// A helper run Claude Code started for itself (`entrypoint: sdk-cli`, such as naming a
    /// branch): never one of the owner's sessions. Reported so a hook-made row can be dropped.
    var isHeadless: Bool = false
}

/// Watches the projects directory and reports sessions active in the last few hours.
/// Delivered on the main actor. Implemented in Sessions/TranscriptWatcher.swift.
@MainActor
protocol TranscriptWatcherSink: AnyObject {
    func transcriptsChanged(_ sessions: [DiscoveredSession])
}

/// One entry of a repository's file tree, for the Files tab. Built by Sessions/RepoFiles.swift.
struct FileTreeNode: Identifiable, Equatable {
    var id: String { path }
    var path: String                // relative to the session's cwd
    var name: String
    var isDirectory: Bool
    var children: [FileTreeNode] = []
}

/// A file's text for the preview pane, capped. Built by Sessions/RepoFiles.swift.
struct FilePreview: Equatable {
    var path: String
    var lines: [String]
    var truncated: Bool
    var isBinary: Bool
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
    var costIsEstimate: Bool = true // true when computed from tokens with our rate table, not reported by Claude
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
    var intValue: Int? { doubleValue.map { Int($0) } }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
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
}
