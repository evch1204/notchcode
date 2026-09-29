// TranscriptWatcher.swift
// Finds live Claude Code sessions with no hooks at all, by polling
// ~/.claude/projects/<encoded cwd>/<session_id>.jsonl every 2 s (the way sidecar-pane does).
//
// Per file it reads the head once (cwd, first timestamp) and, whenever the file's size or
// mtime changes, only its last 64 KB (last prompt, last conversation line). State is then
// derived from that cached tail on every pass, so "working" decays to idle without new writes.
//
// State rules, from the last non-sidechain user / assistant line (every other line type,
// such as system, attachment, mode, last-prompt, is ignored):
//   assistant with a tool_use block, < 3 min old          -> working, verb from the tool
//   assistant mid-turn (stop_reason tool_use or none yet), < 3 min -> working "Thinking"
//   assistant that ended its turn (end_turn etc.), < 10 min -> done
//   user prompt / tool result / task notification, < 3 min -> working "Thinking"
//   interruption, local command output, anything older      -> idle
// Age is measured from that line's own timestamp.
//
// Permission mode ("default", "plan", "bypassPermissions", "acceptEdits", "auto", ...) comes from
// the last non-sidechain line that carries `permissionMode`: every prompt line, and the
// `permission-mode` line Claude Code writes when the owner switches modes mid-session.

import Foundation

final class TranscriptWatcher {
    private weak var sink: TranscriptWatcherSink?
    private let lookback: TimeInterval
    private let queue = DispatchQueue(label: "notchcode.transcript-watcher", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Touched only on `queue`.
    private var files: [String: FileInfo] = [:]
    private var lastDelivered: [DiscoveredSession]?

    static let interval: TimeInterval = 2
    static let tailBytes = 64 * 1024
    static let headBytes = 64 * 1024
    static let workingWindow: TimeInterval = 3 * 60
    static let doneWindow: TimeInterval = 10 * 60

    init(sink: TranscriptWatcherSink, lookback: TimeInterval = 6 * 3600) {
        self.sink = sink
        self.lookback = lookback
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.poll() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: Polling

    private struct Head {
        var cwd: String?
        var startedAt: Date?
        var entrypoint: String?         // "cli" for the owner's sessions, "sdk-cli" for Claude Code's own helper runs
    }

    /// The `entrypoint` Claude Code writes on the lines of a run it started for itself (naming a
    /// branch, summarising) in the same folder as a real session. Those never reach the list.
    static let headlessEntrypoint = "sdk-cli"

    private enum LastLine {
        case none
        case toolUse(name: String, at: Date)
        case midTurn(at: Date)          // assistant text / thinking that will be followed by more
        case turnEnded(at: Date)
        case userActive(at: Date)       // prompt, tool result, task notification
        case userIdle                   // interruption, local command output
    }

    private struct FileInfo {
        var stamp: FileStamp
        var head: Head
        var last: LastLine
        var lastPrompt: String?
        var fallbackCWD: String?        // a cwd seen in the tail, for heads that have none
        var permissionMode: String?     // the last one written, raw
        // The whole file was already searched for a prompt / a mode (this inode): a file
        // with none is not re-read in full on every change.
        var scannedWholeForPrompt = false
        var scannedWholeForMode = false
    }

    private func poll() {
        let now = Date()
        var seen = Set<String>()
        var sessions: [DiscoveredSession] = []

        for (path, stamp) in listTranscripts(now: now) {
            seen.insert(path)
            var info: FileInfo
            if let old = files[path], old.stamp == stamp {
                info = old
            } else if let fresh = scan(path: path, stamp: stamp, previous: files[path]) {
                info = fresh
                files[path] = fresh
            } else {
                continue
            }
            let (state, verb) = Self.state(for: info.last, now: now)
            let url = URL(fileURLWithPath: path)
            sessions.append(DiscoveredSession(
                id: url.deletingPathExtension().lastPathComponent,
                cwd: info.head.cwd ?? info.fallbackCWD ?? "",
                transcriptPath: path,
                startedAt: info.head.startedAt ?? stamp.modified,
                lastActivityAt: stamp.modified,
                state: state,
                verb: verb,
                lastPrompt: info.lastPrompt,
                permissionMode: info.permissionMode,
                isHeadless: info.head.entrypoint == Self.headlessEntrypoint))
        }
        for path in files.keys where !seen.contains(path) {
            files[path] = nil
            // Past the lookback or deleted: the reader's caches for it go too.
            TranscriptReader.forget(transcriptPath: path)
        }

        sessions.sort { a, b in
            a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id < b.id
        }
        guard sessions != lastDelivered else { return }
        lastDelivered = sessions
        let list = sessions
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.sink?.transcriptsChanged(list)
            }
        }
    }

    /// `~/.claude/projects/*/*.jsonl` modified within `lookback`. Subagent transcripts live one
    /// level deeper (`<session>/subagents/`), so they are never listed.
    private func listTranscripts(now: Date) -> [(String, FileStamp)] {
        let fm = FileManager.default
        let root = NotchcodePaths.claudeProjectsDirectory.path
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var result: [(String, FileStamp)] = []
        for project in projects where !project.hasPrefix(".") && project != "subagents" {
            let dir = root + "/" + project
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") && !name.hasPrefix(".") {
                let path = dir + "/" + name
                guard let stamp = FileStamp(path: path),
                      now.timeIntervalSince(stamp.modified) <= lookback else { continue }
                result.append((path, stamp))
            }
        }
        return result
    }

    // MARK: Reading one file

    private func scan(path: String, stamp: FileStamp, previous: FileInfo?) -> FileInfo? {
        // Transcripts only grow; a shrink or a new inode means a different file.
        let sameFile = previous.map { $0.stamp.inode == stamp.inode && stamp.size >= $0.stamp.size } ?? false

        var head = sameFile ? previous!.head : Head()
        if head.cwd == nil || head.startedAt == nil {
            head = readHead(path: path, into: head)
        }

        let offset = max(0, stamp.size - Int64(Self.tailBytes))
        guard let data = try? JSONLines.read(path, from: offset, length: Self.tailBytes) else { return nil }
        var tail = TailScan()
        var body = data
        if offset > 0, let nl = data.firstIndex(of: 0x0A) {
            body = data.subdata(in: data.index(after: nl)..<data.endIndex)   // drop the cut line
        }
        let consumed = JSONLines.forEachCompleteLine(body) { tail.consume($0) }
        if consumed < body.count, let last = JSONLines.parse(body.subdata(in: consumed..<body.count)) {
            tail.consume(last)
        }

        // A new inode starts over; the same file keeps what it already searched.
        var scannedForPrompt = sameFile && previous!.scannedWholeForPrompt
        var scannedForMode = sameFile && previous!.scannedWholeForMode

        var lastPrompt = tail.lastPrompt
        if lastPrompt == nil {
            if sameFile, let old = previous?.lastPrompt {
                lastPrompt = old                     // no new prompt since the last pass
            } else if offset > 0, !scannedForPrompt {
                lastPrompt = Self.lastPromptInWholeFile(path)   // once, for a large file
                scannedForPrompt = true
            }
        }

        var mode = tail.permissionMode
        if mode == nil {
            if sameFile, let old = previous?.permissionMode {
                mode = old                           // no mode written since the last pass
            } else if offset > 0, !scannedForMode {
                mode = Self.permissionModeInWholeFile(path)
                scannedForMode = true
            }
        }

        return FileInfo(stamp: stamp,
                        head: head,
                        last: tail.last,
                        lastPrompt: lastPrompt,
                        fallbackCWD: tail.cwd ?? previous?.fallbackCWD,
                        permissionMode: mode,
                        scannedWholeForPrompt: scannedForPrompt,
                        scannedWholeForMode: scannedForMode)
    }

    private func readHead(path: String, into head: Head) -> Head {
        var head = head
        guard let data = try? JSONLines.read(path, from: 0, length: Self.headBytes) else { return head }
        JSONLines.forEachCompleteLine(data) { line in
            if head.cwd == nil, let c = line["cwd"] as? String, !c.isEmpty { head.cwd = c }
            if head.startedAt == nil, let d = TranscriptDates.parse(line["timestamp"]) { head.startedAt = d }
            if head.entrypoint == nil, let e = line["entrypoint"] as? String, !e.isEmpty { head.entrypoint = e }
        }
        return head
    }

    private static func lastPromptInWholeFile(_ path: String) -> String? {
        guard let data = try? JSONLines.read(path, from: 0) else { return nil }
        var prompt: String?
        JSONLines.forEachCompleteLine(data) { line in
            if (line["isSidechain"] as? Bool) != true, let p = JSONLines.promptText(line) { prompt = p }
        }
        return prompt
    }

    private static func permissionModeInWholeFile(_ path: String) -> String? {
        guard let data = try? JSONLines.read(path, from: 0) else { return nil }
        var mode: String?
        JSONLines.forEachCompleteLine(data) { line in
            if (line["isSidechain"] as? Bool) != true, let m = line["permissionMode"] as? String, !m.isEmpty { mode = m }
        }
        return mode
    }

    private struct TailScan {
        var last: LastLine = .none
        var lastPrompt: String?
        var cwd: String?
        var permissionMode: String?

        mutating func consume(_ line: [String: Any]) {
            if (line["isSidechain"] as? Bool) == true { return }
            if let c = line["cwd"] as? String, !c.isEmpty { cwd = c }
            if let m = line["permissionMode"] as? String, !m.isEmpty { permissionMode = m }
            let date = TranscriptDates.parse(line["timestamp"]) ?? .distantPast
            switch line["type"] as? String {
            case "assistant":
                guard let message = line["message"] as? [String: Any] else { return }
                let blocks = message["content"] as? [[String: Any]] ?? []
                if let tool = blocks.last(where: { ($0["type"] as? String) == "tool_use" }) {
                    last = .toolUse(name: tool["name"] as? String ?? "", at: date)
                } else {
                    let stop = message["stop_reason"] as? String
                    if stop == nil || stop == "tool_use" {
                        last = .midTurn(at: date)
                    } else {
                        last = .turnEnded(at: date)
                    }
                }
            case "user":
                if let p = JSONLines.promptText(line) {
                    lastPrompt = p
                    last = .userActive(at: date)
                } else if let text = JSONLines.userText(line) {
                    let idle = text.hasPrefix("[Request interrupted")
                        || text.hasPrefix("<local-command-")
                        || text.hasPrefix("<command-name>")      // local slash commands answer with stdout next
                    last = idle ? .userIdle : .userActive(at: date)
                    // A slash command that goes to Claude is still a prompt; promptText caught it above.
                } else {
                    last = .userActive(at: date)                 // a tool result: Claude is thinking again
                }
            default:
                break
            }
        }
    }

    private static func state(for last: LastLine, now: Date) -> (SessionState, String?) {
        func recent(_ d: Date, _ window: TimeInterval) -> Bool { now.timeIntervalSince(d) < window }
        switch last {
        case .toolUse(let name, let at) where recent(at, workingWindow):
            return (.working, verb(forTool: name))
        case .midTurn(let at) where recent(at, workingWindow),
             .userActive(let at) where recent(at, workingWindow):
            return (.working, "Thinking")
        case .turnEnded(let at) where recent(at, doneWindow):
            return (.done, nil)
        default:
            return (.idle, nil)
        }
    }

    static func verb(forTool name: String) -> String {
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running"
        case "Read", "Grep", "Glob": return "Reading"
        case "Agent", "Task": return "Delegating"
        default: return "Working"
        }
    }
}
