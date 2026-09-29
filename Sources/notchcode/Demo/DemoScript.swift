// DemoScript.swift
// `--demo`: walks every state with sample data by feeding real HookEnvelopes
// through AppState.receive, the same path the socket uses. This file is the
// only place sample text lives.

import Foundation

@MainActor
final class DemoScript {
    private let state: AppState
    private var task: Task<Void, Never>?

    private let ponyfish = "demo-ponyfish"
    private let bluefin = "demo-bluefin"
    private let sidecar = "demo-sidecar-pane"
    // Two worktrees of one repo and a plain checkout, under a generic ~/code.
    private let ponyfishCWD = DemoScript.home("code/notchcode/ponyfish")
    private let bluefinCWD = DemoScript.home("code/notchcode/bluefin")
    private let sidecarCWD = DemoScript.home("code/sidecar-pane")

    private static func home(_ relative: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(relative)
    }

    init(state: AppState) {
        self.state = state
    }

    func start() {
        state.readsLocalFiles = false
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    // MARK: - Timeline

    private func run() async {
        // t0: closed.
        await pause(1.5)

        // A session starts and begins thinking. A second one is already busy.
        send(.sessionStart, session: ponyfish, cwd: ponyfishCWD, payload: [:])
        state.mutateSession(ponyfish) {
            $0.branch = "main"
            $0.repoName = "notchcode"
        }
        state.setTurns(demoTurns(), for: ponyfish)
        sendDemoStatusline()
        send(.userPrompt, session: ponyfish, cwd: ponyfishCWD, payload: [
            "prompt": .string("Wire the permission card to the socket"),
        ])

        send(.sessionStart, session: sidecar, cwd: sidecarCWD, payload: [:])
        state.mutateSession(sidecar) {
            $0.branch = "feat/staged-diff"
            $0.repoName = "sidecar-pane"
        }
        send(.userPrompt, session: sidecar, cwd: sidecarCWD, payload: [
            "prompt": .string("Render the staged diff in the pane"),
        ])
        send(.preTool, session: sidecar, cwd: sidecarCWD, payload: [
            "tool_name": .string("Read"),
            "tool_input": .object(["file_path": .string("src/pane.ts")]),
        ])

        // A second worktree of notchcode, so the Sessions tab groups two rows under one repo.
        send(.sessionStart, session: bluefin, cwd: bluefinCWD, payload: [:])
        state.mutateSession(bluefin) {
            $0.branch = "feat/socket"
            $0.repoName = "notchcode"
        }
        state.setTurns(bluefinTurns(), for: bluefin)
        send(.userPrompt, session: bluefin, cwd: bluefinCWD, payload: [
            "prompt": .string("Retry the socket connect with backoff"),
        ])
        send(.preTool, session: bluefin, cwd: bluefinCWD, payload: [
            "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string("Sources/notchcode/Transport/SocketServer.swift")]),
        ])

        // +3 s: editing, and an edit lands.
        await pause(3)
        let notchView = "Sources/notchcode/Views/NotchView.swift"
        state.seedTurnFiles([
            "Sources/notchcode/Theme.swift",
            notchView,
            "Sources/notchcode/Model/AppState.swift",
        ], for: ponyfish)
        send(.preTool, session: ponyfish, cwd: ponyfishCWD, payload: [
            "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string(notchView)]),
        ])
        await pause(0.6)
        send(.postTool, session: ponyfish, cwd: ponyfishCWD, payload: [
            "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string(notchView)]),
            "tool_response": .object([
                "filePath": .string(notchView),
                "structuredPatch": .array([
                    .object(["lines": .array(patchLines(added: 12, removed: 3))]),
                ]),
            ]),
        ])
        send(.preTool, session: ponyfish, cwd: ponyfishCWD, payload: [
            "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string(notchView)]),
        ])

        // Two subagents start. After the edit peek the wings show two coloured
        // squares (clay, blue) and "2", the card header names them, and the
        // Sessions tab shows two coloured lanes under ponyfish.
        await pause(0.6)
        let explore = "demo-agent-explore"
        let finder = "demo-agent-finder"
        send(.subagentStart, session: ponyfish, cwd: ponyfishCWD, payload: [
            "agent_id": .string(explore),
            "agent_type": .string("Explore"),
        ])
        send(.subagentStart, session: ponyfish, cwd: ponyfishCWD, payload: [
            "agent_id": .string(finder),
            "agent_type": .string("general-purpose"),
        ])
        state.setAgentDescription("Map how the transcript reader finds sessions", agentId: explore, sessionId: ponyfish)
        state.setAgentDescription("Find where the notch geometry is read", agentId: finder, sessionId: ponyfish)

        // Explore finishes first: "1 agent", and "1 done" on the session row.
        await pause(6)
        send(.subagentStop, session: ponyfish, cwd: ponyfishCWD, payload: [
            "agent_id": .string(explore),
            "agent_type": .string("Explore"),
        ])

        // The second one a few seconds later: the clock comes back.
        await pause(4)
        send(.subagentStop, session: ponyfish, cwd: ponyfishCWD, payload: [
            "agent_id": .string(finder),
            "agent_type": .string("general-purpose"),
        ])

        // +2 s: a permission request. Wait for the owner (or the deadline).
        await pause(2)
        let permissionId = UUID().uuidString
        send(.permission, session: ponyfish, cwd: ponyfishCWD, id: permissionId, payload: [
            "tool_name": .string("Bash"),
            "tool_input": .object([
                "command": .string("npm test -- --watch=false"),
                "description": .string("Run the test suite once to check the socket transport."),
            ]),
        ])
        await waitUntilAnswered(permissionId)
        if Task.isCancelled { return }

        send(.preTool, session: ponyfish, cwd: ponyfishCWD, payload: [
            "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("npm test -- --watch=false")]),
        ])

        // +3 s: an Edit that needs permission. The card shows its diff (D opens it).
        await pause(3)
        let editId = UUID().uuidString
        let themePath = (ponyfishCWD as NSString).appendingPathComponent("Sources/notchcode/Theme.swift")
        send(.permission, session: ponyfish, cwd: ponyfishCWD, id: editId, payload: [
            "tool_name": .string("Edit"),
            "tool_input": .object([
                "file_path": .string(themePath),
                "old_string": .string(themeEditOld),
                "new_string": .string(themeEditNew),
            ]),
            "permission_suggestions": .array([
                .object([
                    "type": .string("setMode"),
                    "mode": .string("acceptEdits"),
                    "destination": .string("session"),
                ]),
            ]),
        ])
        // The demo reads no files, so the diff numbers from 1; move it to where the block really sits.
        if let request = state.pending.first(where: { $0.id == editId }) {
            state.setFiles(request.files.map { shifted($0, by: themeEditLine - 1) }, forRequest: editId)
        }
        await waitUntilAnswered(editId)
        if Task.isCancelled { return }

        // +3 s: a commit request with three files.
        await pause(3)
        let commitId = UUID().uuidString
        send(.preTool, session: ponyfish, cwd: ponyfishCWD, id: commitId, payload: [
            "tool_name": .string("Bash"),
            "tool_input": .object([
                "command": .string("git commit -m \"Add PermissionRequest hook and Unix socket transport\""),
                "description": .string("Commit the hook and the transport."),
            ]),
        ])
        state.setFiles(commitFiles(), forRequest: commitId)
        await waitUntilAnswered(commitId)
        if Task.isCancelled { return }

        // Stop: done peek.
        await pause(1)
        send(.stop, session: ponyfish, cwd: ponyfishCWD, payload: [:])

        // The second session finishes. Both sessions stay alive, so the notch
        // settles on the idle agents view ("Done", two green dots), or on the
        // pure notch when the owner picked that in Settings.
        await pause(6)
        send(.stop, session: sidecar, cwd: sidecarCWD, payload: [:])
        await pause(3)
        send(.stop, session: bluefin, cwd: bluefinCWD, payload: [:])
    }

    // MARK: - Edit request sample

    /// Where `themeEditOld` starts in Theme.swift.
    private let themeEditLine = 364

    private let themeEditOld = """
            // Diff view.
            static let diffLineHeight: CGFloat = 16
            static let diffMaxHeight: CGFloat = 220
            static let diffLineNumberWidth: CGFloat = 30
            static let diffGutterSpacing: CGFloat = 4
            static let diffVPadding: CGFloat = 4
            static let groupHeaderTopPadding: CGFloat = 6
    """

    private let themeEditNew = """
            // Diff view.
            static let diffLineHeight: CGFloat = 16
            static let diffMaxHeight: CGFloat = 240
            static let diffLineNumberWidth: CGFloat = 30
            static let diffGutterSpacing: CGFloat = 4
            static let diffVPadding: CGFloat = 4
            static let groupHeaderTopPadding: CGFloat = 6
            /// Inside a request card the diff takes what is left above the pills, up to this.
            static let requestDiffMaxHeight: CGFloat = 260
            /// ... and never less than this (a short diff is shorter still).
            static let requestDiffMinHeight: CGFloat = 72
    """

    /// The same diff `offset` lines further down the file: numbers and hunk headers move.
    private func shifted(_ file: FileChange, by offset: Int) -> FileChange {
        func move(_ lines: [DiffLine]) -> [DiffLine] {
            lines.map { line in
                var line = line
                line.oldLine = line.oldLine.map { $0 + offset }
                line.newLine = line.newLine.map { $0 + offset }
                if line.kind == .hunk {
                    // "@@ -a,b +c,d @@"
                    let parts = line.text.split(separator: " ")
                    if parts.count >= 3 {
                        func bump(_ part: Substring) -> String {
                            let sign = part.prefix(1)
                            let fields = part.dropFirst().split(separator: ",")
                            guard let start = fields.first.flatMap({ Int($0) }) else { return String(part) }
                            return sign + String(start + offset) + (fields.count > 1 ? "," + fields[1] : "")
                        }
                        line.text = "@@ \(bump(parts[1])) \(bump(parts[2])) @@"
                    }
                }
                return line
            }
        }
        var file = file
        file.patch = move(file.patch)
        file.snippet = move(file.snippet)
        return file
    }

    /// The commit's three files, each with a patch the card can open.
    private func commitFiles() -> [FileChange] {
        [
            file("hooks/notchcode-hook.sh", kind: "new", hunks: [
                (0, 1, [
                    "+#!/bin/sh",
                    "+# notchcode hook: forwards Claude Code hook input to the app over a Unix socket.",
                    "+# Prints nothing, needs nothing, exits 0 even when the app is not running.",
                    "+",
                    "+kind=\"$1\"",
                    "+sock=\"$HOME/Library/Application Support/notchcode/notchcode.sock\"",
                    "+[ -S \"$sock\" ] || exit 0",
                    "+",
                    "+input=$(cat)",
                    "+id=$(uuidgen 2>/dev/null || date +%s%N)",
                    "+ts=$(date +%s)",
                    "+",
                ]),
            ], truncatedExtra: 36),
            file("Sources/notchcode/Transport/SocketServer.swift", kind: "edit", hunks: [
                (1, 1, [
                    " // SocketServer.swift",
                    "-// Placeholder transport.",
                    "+// Listens on a Unix domain socket, one JSON envelope per line. Blocking kinds",
                    "+// keep the connection open until the owner answers or the hook goes away.",
                    " ",
                    " import Foundation",
                ]),
                (58, 59, [
                    "     func start() throws {",
                    "-        // TODO",
                    "+        try FileManager.default.createDirectory(at: NotchcodePaths.supportDirectory,",
                    "+                                                withIntermediateDirectories: true)",
                    "+        unlink(NotchcodePaths.socketURL.path)",
                    "+        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)",
                    "+        guard fd >= 0 else { throw TransportError.socket(errno) }",
                    "     }",
                ]),
            ], truncatedExtra: 120),
            file("Sources/notchcode/Model/AppState.swift", kind: "edit", hunks: [
                (1029, 1029, [
                    "     private func handlePermission(_ envelope: HookEnvelope, sessionId: String, reply: @escaping ReplyHandler) {",
                    "         let payload = envelope.payload",
                    "-        let tool = \"Tool\"",
                    "+        let tool = payload[\"tool_name\"]?.stringValue ?? \"Tool\"",
                    "+        let input = payload[\"tool_input\"]",
                    "         let now = Date()",
                ]),
                (1044, 1045, [
                    "         enqueue(request, reply: reply)",
                    "-        state = .needsYou",
                    "+        updateSession(sessionId) { $0.state = .needsYou }",
                    "     }",
                ]),
            ]),
        ]
    }

    // MARK: - Helpers

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntilAnswered(_ id: String) async {
        while state.pending.contains(where: { $0.id == id }) {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func send(
        _ kind: EventKind,
        session: String,
        cwd: String,
        id: String = UUID().uuidString,
        payload: [String: JSONValue]
    ) {
        let envelope = HookEnvelope(
            kind: kind,
            id: id,
            sessionId: session,
            cwd: cwd,
            transcriptPath: nil,
            termProgram: "ghostty",
            termBundleId: "com.mitchellh.ghostty",
            pid: nil,
            ts: Date().timeIntervalSince1970,
            payload: .object(payload)
        )
        state.receiveDemo(envelope)
    }

    private func patchLines(added: Int, removed: Int) -> [JSONValue] {
        var lines: [JSONValue] = []
        for i in 0..<removed { lines.append(.string("-    old line \(i + 1)")) }
        for i in 0..<added { lines.append(.string("+    new line \(i + 1)")) }
        return lines
    }

    /// The limits arrive the way real ones do: a status line envelope through `receive`.
    private func sendDemoStatusline() {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(1 * 3600 + 52 * 60)
        let weekReset = now.addingTimeInterval(3 * 86400)
        send(.statusline, session: ponyfish, cwd: ponyfishCWD, payload: [
            "session_id": .string(ponyfish),
            "model": .object(["id": .string("claude-opus-5")]),
            "rate_limits": .object([
                "five_hour": .object([
                    "used_percentage": .number(61),
                    "resets_at": .number(fiveHourReset.timeIntervalSince1970),
                ]),
                "seven_day": .object([
                    "used_percentage": .number(34),
                    "resets_at": .number(weekReset.timeIntervalSince1970),
                ]),
            ]),
        ])
    }

    private func demoTurns() -> [TranscriptTurn] {
        let now = Date()
        return [
            TranscriptTurn(
                id: "demo-turn-1",
                prompt: "Sketch the notch shape with concave ears and a spring morph",
                startedAt: now.addingTimeInterval(-52 * 60),
                endedAt: now.addingTimeInterval(-47 * 60),
                files: [
                    file("Sources/notchcode/Notch/NotchShape.swift", kind: "new", hunks: [
                        (0, 1, [
                            "+import SwiftUI",
                            "+",
                            "+struct NotchShape: Shape {",
                            "+    var topRadius: CGFloat",
                            "+    var bottomRadius: CGFloat",
                            "+",
                            "+    var animatableData: AnimatablePair<CGFloat, CGFloat> {",
                            "+        get { AnimatablePair(topRadius, bottomRadius) }",
                            "+        set {",
                            "+            topRadius = newValue.first",
                            "+            bottomRadius = newValue.second",
                            "+        }",
                            "+    }",
                            "+",
                            "+    func path(in rect: CGRect) -> Path {",
                            "+        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))",
                            "+        let bodyWidth = rect.width - 2 * top",
                            "+        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))",
                            "+        var path = Path()",
                            "+        path.move(to: CGPoint(x: rect.minX, y: rect.minY))",
                            "+        // Left ear: concave, from the top edge down into the body.",
                            "+        path.addArc(tangent1End: CGPoint(x: rect.minX + top, y: rect.minY),",
                            "+                    tangent2End: CGPoint(x: rect.minX + top, y: rect.minY + top), radius: top)",
                            "+        return path",
                            "+    }",
                            "+}",
                        ]),
                    ]),
                    file("Sources/notchcode/Theme.swift", kind: "edit", hunks: [
                        (40, 40, [
                            " enum Radius {",
                            "     static let wingsBottom: CGFloat = 14",
                            "-    static let cardBottom: CGFloat = 22",
                            "+    static let cardBottom: CGFloat = 26",
                            "+    static let cardTop: CGFloat = 18",
                            " }",
                        ]),
                    ]),
                ],
                tokens: TokenUsage(input: 9_100, output: 6_200, cacheRead: 180_000, cacheWrite: 22_000),
                model: "claude-fable-5-1"
            ),
            TranscriptTurn(
                id: "demo-turn-2",
                prompt: "Make the permission card answer through the hook with a 60 second deadline",
                startedAt: now.addingTimeInterval(-31 * 60),
                endedAt: now.addingTimeInterval(-24 * 60),
                files: [
                    file("Sources/notchcode/Model/AppState.swift", kind: "edit", hunks: [
                        (118, 118, [
                            "     /// Replies exactly once and forgets the request.",
                            "     private func resolve(_ id: String, with reply: HookReply) {",
                            "-        let handler = handlers[id]",
                            "-        handler?(reply)",
                            "+        guard let handler = handlers.removeValue(forKey: id) else { return }",
                            "+        deadlineTasks.removeValue(forKey: id)?.cancel()",
                            "+        pending.removeAll { $0.id == id }",
                            "+        handler(reply)",
                            "     }",
                        ]),
                        (210, 212, [
                            "         let id = request.id",
                            "-        Task { await self.expire(id) }",
                            "+        let delay = max(0, request.deadline.timeIntervalSinceNow)",
                            "+        deadlineTasks[id] = Task { @MainActor [weak self] in",
                            "+            try? await Task.sleep(for: .seconds(delay))",
                            "+            if Task.isCancelled { return }",
                            "+            self?.resolve(id, with: HookReply(id: id, decision: .none))",
                            "+        }",
                        ]),
                    ]),
                    file("Sources/notchcode/Views/RequestCards.swift", kind: "new", hunks: [
                        (0, 1, [
                            "+import SwiftUI",
                            "+",
                            "+private let footerText = \"At 0:00 the terminal asks instead. Nothing is denied for you.\"",
                            "+",
                            "+@MainActor",
                            "+struct PermissionCard: View {",
                            "+    @ObservedObject var state: AppState",
                            "+    let request: PendingRequest",
                        ]),
                    ], truncatedExtra: 88),
                    file("Sources/notchcode/Views/Components.swift", kind: "edit", hunks: [
                        (60, 60, [
                            " struct Keycap: View {",
                            "-    let text: String",
                            "+    let label: String",
                            "+    var onLight = false",
                        ]),
                    ]),
                ],
                tokens: TokenUsage(input: 12_300, output: 8_800, cacheRead: 240_000, cacheWrite: 31_000),
                model: "claude-fable-5-1"
            ),
            TranscriptTurn(
                id: "demo-turn-3",
                prompt: "Wire the permission card to the socket",
                startedAt: now.addingTimeInterval(-3 * 60),
                endedAt: nil,
                files: [
                    file("Sources/notchcode/Views/NotchView.swift", kind: "edit", hunks: [
                        (18, 18, [
                            "     var body: some View {",
                            "-        Text(verb)",
                            "+        if let request = state.currentPending {",
                            "+            AttentionView(state: state, request: request)",
                            "+        } else {",
                            "+            WingsView(state: state)",
                            "+        }",
                            "     }",
                        ]),
                    ]),
                ],
                tokens: TokenUsage(input: 4_200, output: 2_100, cacheRead: 96_000, cacheWrite: 8_000),
                model: "claude-opus-5"
            ),
        ]
    }

    /// bluefin: one finished turn without file changes, and the current one editing the socket.
    private func bluefinTurns() -> [TranscriptTurn] {
        let now = Date()
        return [
            TranscriptTurn(
                id: "demo-bluefin-1",
                prompt: "Why does the hook sometimes time out on the first event?",
                startedAt: now.addingTimeInterval(-18 * 60),
                endedAt: now.addingTimeInterval(-16 * 60),
                files: [],
                tokens: TokenUsage(input: 3_100, output: 1_400, cacheRead: 52_000, cacheWrite: 6_000),
                model: "claude-sonnet-5-5"
            ),
            TranscriptTurn(
                id: "demo-bluefin-2",
                prompt: "Retry the socket connect with backoff",
                startedAt: now.addingTimeInterval(-60),
                endedAt: nil,
                files: [
                    file("Sources/notchcode/Transport/SocketServer.swift", kind: "edit", hunks: [
                        (88, 88, [
                            "     func start() {",
                            "-        bind()",
                            "+        var delay = 0.05",
                            "+        while !bind() && delay < 2 {",
                            "+            Thread.sleep(forTimeInterval: delay)",
                            "+            delay *= 2",
                            "+        }",
                            "     }",
                        ]),
                    ]),
                ],
                tokens: TokenUsage(input: 2_000, output: 900, cacheRead: 40_000, cacheWrite: 3_000),
                model: "claude-sonnet-5-5"
            ),
        ]
    }

    /// A FileChange whose counts, snippet and patch all come from unified-diff style lines
    /// ("+added", "-removed", " context"), one hunk per (old start, new start, lines).
    /// `truncatedExtra` adds that many added lines the patch leaves out, as a long diff would.
    private func file(
        _ path: String,
        kind: String,
        hunks: [(Int, Int, [String])],
        truncatedExtra: Int = 0
    ) -> FileChange {
        var patch: [DiffLine] = []
        var added = 0
        var removed = 0
        for (oldStart, newStart, lines) in hunks {
            let oldCount = lines.filter { !$0.hasPrefix("+") }.count
            let newCount = lines.filter { !$0.hasPrefix("-") }.count
            patch.append(DiffLine(kind: .hunk, text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@", oldLine: nil, newLine: nil))
            var oldLine = max(oldStart, 1)
            var newLine = max(newStart, 1)
            for raw in lines {
                let text = String(raw.dropFirst())
                switch raw.first {
                case "+":
                    patch.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newLine))
                    newLine += 1
                    added += 1
                case "-":
                    patch.append(DiffLine(kind: .removed, text: text, oldLine: oldLine, newLine: nil))
                    oldLine += 1
                    removed += 1
                default:
                    patch.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        return FileChange(
            path: path,
            added: added + truncatedExtra,
            removed: removed,
            kind: kind,
            snippet: Array(patch.prefix(Theme.Limits.inlineSnippetMaxLines - 1)),
            patch: patch,
            patchTruncated: truncatedExtra > 0
        )
    }
}
