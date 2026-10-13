// DemoScript.cs
// Port of Sources/notchcode/Demo/DemoScript.swift.
// `--demo`: walks every state with sample data by feeding real HookEnvelopes through
// AppState.Receive, the same path the pipe uses. This file is the only place sample text lives.

using System.IO;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Demo;

public sealed class DemoScript
{
    private readonly AppState state;
    private CancellationTokenSource? task;

    private const string Ponyfish = "demo-ponyfish";
    private const string Bluefin = "demo-bluefin";
    private const string Sidecar = "demo-sidecar-pane";
    // Two worktrees of one repo and a plain checkout, under a generic ~\code.
    private readonly string ponyfishCwd = Home(@"code\notchcode\ponyfish");
    private readonly string bluefinCwd = Home(@"code\notchcode\bluefin");
    private readonly string sidecarCwd = Home(@"code\sidecar-pane");

    private static string Home(string relative)
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), relative);

    public DemoScript(AppState state)
    {
        this.state = state;
    }

    public void Start()
    {
        state.ReadsLocalFiles = false;
        task?.Cancel();
        task = new CancellationTokenSource();
        _ = Run(task.Token);
    }

    public void Stop() => task?.Cancel();

    // MARK: - Timeline

    private async Task Run(CancellationToken token)
    {
        try
        {
            await RunSteps(token);
        }
        catch (TaskCanceledException) { }
    }

    private async Task RunSteps(CancellationToken token)
    {
        // t0: closed.
        await Pause(1.5, token);

        // A session starts and begins thinking. A second one is already busy.
        Send(EventKind.SessionStart, Ponyfish, ponyfishCwd);
        state.MutateSession(Ponyfish, s => s with { Branch = "main", RepoName = "notchcode" });
        state.SetTurns(DemoTurns(), Ponyfish);
        SendDemoStatusline();
        Send(EventKind.UserPrompt, Ponyfish, ponyfishCwd, payload: Obj(("prompt", Str("Wire the permission card to the pipe"))));

        Send(EventKind.SessionStart, Sidecar, sidecarCwd);
        state.MutateSession(Sidecar, s => s with { Branch = "feat/staged-diff", RepoName = "sidecar-pane" });
        Send(EventKind.UserPrompt, Sidecar, sidecarCwd, payload: Obj(("prompt", Str("Render the staged diff in the pane"))));
        Send(EventKind.PreTool, Sidecar, sidecarCwd, payload: Obj(
            ("tool_name", Str("Read")),
            ("tool_input", Obj(("file_path", Str("src/pane.ts"))))));

        // A second worktree of notchcode, so the Sessions tab groups two rows under one repo.
        Send(EventKind.SessionStart, Bluefin, bluefinCwd);
        state.MutateSession(Bluefin, s => s with { Branch = "feat/pipe", RepoName = "notchcode" });
        state.SetTurns(BluefinTurns(), Bluefin);
        Send(EventKind.UserPrompt, Bluefin, bluefinCwd, payload: Obj(("prompt", Str("Retry the pipe connect with backoff"))));
        Send(EventKind.PreTool, Bluefin, bluefinCwd, payload: Obj(
            ("tool_name", Str("Edit")),
            ("tool_input", Obj(("file_path", Str("windows/src/Notchcode.App/Transport/PipeServer.cs"))))));

        // +3 s: editing, and an edit lands.
        await Pause(3, token);
        const string notchView = "windows/src/Notchcode.App/Notch/NotchRootView.xaml.cs";
        state.SeedTurnFiles(["windows/src/Notchcode.App/UI/Theme.cs", notchView, "windows/src/Notchcode.App/State/AppState.cs"], Ponyfish);
        Send(EventKind.PreTool, Ponyfish, ponyfishCwd, payload: Obj(
            ("tool_name", Str("Edit")),
            ("tool_input", Obj(("file_path", Str(notchView))))));
        await Pause(0.6, token);
        var hunk = Obj(("lines", JsonValue.Array(PatchLines(12, 3))));
        var response = Obj(("filePath", Str(notchView)), ("structuredPatch", JsonValue.Array(hunk)));
        Send(EventKind.PostTool, Ponyfish, ponyfishCwd, payload: Obj(
            ("tool_name", Str("Edit")),
            ("tool_input", Obj(("file_path", Str(notchView)))),
            ("tool_response", response)));
        Send(EventKind.PreTool, Ponyfish, ponyfishCwd, payload: Obj(
            ("tool_name", Str("Edit")),
            ("tool_input", Obj(("file_path", Str(notchView))))));

        // Two subagents start: the wings show "2 agents", the card's status names them, and the
        // Sessions tool shows two coloured lanes under ponyfish.
        await Pause(0.6, token);
        const string explore = "demo-agent-explore";
        const string finder = "demo-agent-finder";
        Send(EventKind.SubagentStart, Ponyfish, ponyfishCwd, payload: Obj(("agent_id", Str(explore)), ("agent_type", Str("Explore"))));
        Send(EventKind.SubagentStart, Ponyfish, ponyfishCwd, payload: Obj(("agent_id", Str(finder)), ("agent_type", Str("general-purpose"))));
        state.SetAgentDescription("Map how the transcript reader finds sessions", explore, Ponyfish);
        state.SetAgentDescription("Find where the notch geometry is read", finder, Ponyfish);

        // Explore finishes first: "1 agent", and "1 done" on the session row.
        await Pause(6, token);
        Send(EventKind.SubagentStop, Ponyfish, ponyfishCwd, payload: Obj(("agent_id", Str(explore)), ("agent_type", Str("Explore"))));

        // The second one a few seconds later.
        await Pause(4, token);
        Send(EventKind.SubagentStop, Ponyfish, ponyfishCwd, payload: Obj(("agent_id", Str(finder)), ("agent_type", Str("general-purpose"))));

        // +2 s: a permission request. Wait for the owner (or the deadline).
        await Pause(2, token);
        string permissionId = Guid.NewGuid().ToString().ToUpperInvariant();
        Send(EventKind.Permission, Ponyfish, ponyfishCwd, permissionId, Obj(
            ("tool_name", Str("Bash")),
            ("tool_input", Obj(
                ("command", Str("npm test -- --watch=false")),
                ("description", Str("Run the test suite once to check the pipe transport."))))));
        await WaitUntilAnswered(permissionId, token);

        Send(EventKind.PreTool, Ponyfish, ponyfishCwd, payload: Obj(
            ("tool_name", Str("Bash")),
            ("tool_input", Obj(("command", Str("npm test -- --watch=false"))))));

        // +3 s: an Edit that needs permission. The card shows its diff (D opens it).
        await Pause(3, token);
        string editId = Guid.NewGuid().ToString().ToUpperInvariant();
        string themePath = Path.Combine(ponyfishCwd, @"windows\src\Notchcode.App\UI\Theme.cs");
        Send(EventKind.Permission, Ponyfish, ponyfishCwd, editId, Obj(
            ("tool_name", Str("Edit")),
            ("tool_input", Obj(
                ("file_path", Str(themePath)),
                ("old_string", Str(ThemeEditOld)),
                ("new_string", Str(ThemeEditNew)))),
            ("permission_suggestions", JsonValue.Array(Obj(
                ("type", Str("setMode")),
                ("mode", Str("acceptEdits")),
                ("destination", Str("session")))))));
        // The demo reads no files, so the diff numbers from 1; move it to where the block really sits.
        if (state.Pending.FirstOrDefault(p => p.Id == editId) is { } request)
            state.SetFiles(request.Files.Select(f => Shifted(f, ThemeEditLine - 1)).ToList(), editId);
        await WaitUntilAnswered(editId, token);

        // +3 s: Claude finished a plan (ExitPlanMode). The card renders it as Markdown.
        await Pause(3, token);
        string planId = Guid.NewGuid().ToString().ToUpperInvariant();
        Send(EventKind.Permission, Ponyfish, ponyfishCwd, planId, Obj(
            ("permission_mode", Str("plan")),
            ("tool_name", Str("ExitPlanMode")),
            ("tool_input", Obj(
                ("plan", Str(DemoPlan)),
                ("planFilePath", Str(Home(@".claude\plans\add-permission-hook-quiet-harbor.md")))))));
        await WaitUntilAnswered(planId, token);

        // +3 s: a commit request with three files.
        await Pause(3, token);
        string commitId = Guid.NewGuid().ToString().ToUpperInvariant();
        Send(EventKind.PreTool, Ponyfish, ponyfishCwd, commitId, Obj(
            ("tool_name", Str("Bash")),
            ("tool_input", Obj(
                ("command", Str("git commit -m \"Add PermissionRequest hook and named pipe transport\"")),
                ("description", Str("Commit the hook and the transport."))))));
        state.SetFiles(CommitFiles(), commitId);
        await WaitUntilAnswered(commitId, token);

        // Stop: done peek.
        await Pause(1, token);
        Send(EventKind.Stop, Ponyfish, ponyfishCwd);

        // The second session finishes. Both sessions stay alive, so the notch settles on the
        // resting row, or on the pure notch when the owner picked that in Settings.
        await Pause(6, token);
        Send(EventKind.Stop, Sidecar, sidecarCwd);
        await Pause(3, token);
        Send(EventKind.Stop, Bluefin, bluefinCwd);
    }

    // MARK: - Plan request sample

    private const string DemoPlan = """
        # Plan: Add the PermissionRequest hook and the pipe transport

        ## Context
        Permission prompts only show in the terminal. The notch should answer them through a `PermissionRequest` hook that talks to the app over a named pipe.

        ## Steps
        1. Write `notchcode-hook.exe`, which sends one JSON line and waits for the reply.
           - Exit 0 with no output when the app is not running.
        2. Add `PipeServer` to the app and answer `none` at the 58 s deadline.
           - Keep the reply keys sorted so the hook can read them without a JSON library.
        3. Wire the permission card's Allow, Always and Deny to the reply handler.
           - Always echoes `permission_suggestions` back as `updated_permissions`.

        ## Verification
        - `scripts/send-test-event.ps1 permission` prints the reply line for each answer.
        - With the app quit, a tool call still reaches the terminal prompt.
        """;

    // MARK: - Edit request sample

    /// Where `ThemeEditOld` starts in Theme.cs.
    private const int ThemeEditLine = 916;

    private const string ThemeEditOld = """
                // Diff view: a rounded box, two line-number columns (old, new), then the line.
                // Its font, padding and gutter are the Files preview's.
                public const double DiffLineHeight = 16;
                public const double DiffMaxHeight = 220;
                /// One line-number column, wide enough for four digits at the mono size.
                public const double DiffLineNumberWidth = 30;
        """;

    private const string ThemeEditNew = """
                // Diff view: a rounded box, two line-number columns (old, new), then the line.
                // Its font, padding and gutter are the Files preview's.
                public const double DiffLineHeight = 16;
                public const double DiffMaxHeight = 240;
                /// One line-number column, wide enough for four digits at the mono size.
                public const double DiffLineNumberWidth = 30;
                /// Inside a request card the diff takes what is left above the footer, up to this.
                public const double RequestDiffMaxHeight = 260;
                /// ... and never less than this (a short diff is shorter still).
                public const double RequestDiffMinHeight = 72;
        """;

    /// The same diff `offset` lines further down the file: numbers and hunk headers move.
    private static FileChange Shifted(FileChange file, int offset)
    {
        List<DiffLine> Move(IReadOnlyList<DiffLine> lines) => lines.Select(line =>
        {
            var moved = line with
            {
                OldLine = line.OldLine is int o ? o + offset : null,
                NewLine = line.NewLine is int n ? n + offset : null,
            };
            if (line.Kind != DiffLineKind.Hunk) return moved;
            // "@@ -a,b +c,d @@"
            var parts = line.Text.Split(' ');
            if (parts.Length < 3) return moved;
            string Bump(string part)
            {
                string sign = part[..1];
                var fields = part[1..].Split(',');
                if (!int.TryParse(fields[0], out int start)) return part;
                return sign + (start + offset) + (fields.Length > 1 ? "," + fields[1] : "");
            }
            return moved with { Text = $"@@ {Bump(parts[1])} {Bump(parts[2])} @@" };
        }).ToList();
        return file with { Patch = Move(file.Patch), Snippet = Move(file.Snippet) };
    }

    /// The commit's three files, each with a patch the card can open.
    private static List<FileChange> CommitFiles() =>
    [
        File("windows/src/Notchcode.Hook/Program.cs", "new",
        [
            (0, 1,
            [
                "+// Program.cs",
                "+// notchcode hook: forwards Claude Code hook input to the app over a named pipe.",
                "+// Prints nothing, needs nothing, exits 0 even when the app is not running.",
                "+",
                "+var kind = args.FirstOrDefault() ?? \"\";",
                "+var pipe = new NamedPipeClientStream(\".\", PipeName, PipeDirection.InOut);",
                "+try { pipe.Connect(200); } catch (TimeoutException) { return 0; }",
                "+",
                "+var input = Console.In.ReadToEnd();",
                "+var id = Guid.NewGuid().ToString();",
                "+var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();",
                "+",
            ]),
        ], truncatedExtra: 36),
        File("windows/src/Notchcode.App/Transport/PipeServer.cs", "edit",
        [
            (1, 1,
            [
                " // PipeServer.cs",
                "-// Placeholder transport.",
                "+// Listens on a named pipe, one JSON envelope per line. Blocking kinds keep the",
                "+// connection open until the owner answers or the hook goes away.",
                " ",
                " using System.IO.Pipes;",
            ]),
            (58, 59,
            [
                "     public void Start()",
                "     {",
                "-        // TODO",
                "+        Directory.CreateDirectory(NotchcodePaths.SupportDirectory);",
                "+        listener = Task.Run(() => AcceptLoop(cancel.Token));",
                "     }",
            ]),
        ], truncatedExtra: 120),
        File("windows/src/Notchcode.App/State/AppState.cs", "edit",
        [
            (1029, 1029,
            [
                "     private void HandlePermission(HookEnvelope envelope, string sessionId, ReplyHandler reply)",
                "     {",
                "-        var tool = \"Tool\";",
                "+        var tool = envelope.Payload[\"tool_name\"]?.StringValue ?? \"Tool\";",
                "+        var input = envelope.Payload[\"tool_input\"];",
                "         var now = DateTime.UtcNow;",
            ]),
            (1044, 1045,
            [
                "         Enqueue(request, reply);",
                "-        State = SessionState.NeedsYou;",
                "+        UpdateSession(sessionId, s => s with { State = SessionState.NeedsYou });",
                "     }",
            ]),
        ]),
    ];

    // MARK: - Helpers

    private static Task Pause(double seconds, CancellationToken token) => Task.Delay(TimeSpan.FromSeconds(seconds), token);

    private async Task WaitUntilAnswered(string id, CancellationToken token)
    {
        while (state.Pending.Any(p => p.Id == id))
            await Task.Delay(TimeSpan.FromMilliseconds(250), token);
    }

    private static JsonValue Str(string value) => JsonValue.String(value);
    private static JsonValue Num(double value) => JsonValue.Number(value);
    private static JsonValue Obj(params (string Key, JsonValue Value)[] members) => JsonValue.Object(members);

    private void Send(EventKind kind, string session, string cwd, string? id = null, JsonValue? payload = null)
    {
        var envelope = new HookEnvelope
        {
            Kind = kind,
            Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
            SessionId = session,
            Cwd = cwd,
            TermProgram = "WindowsTerminal",
            Ts = ContractJson.ToUnixSeconds(DateTime.UtcNow),
            Payload = payload ?? Obj(),
        };
        state.ReceiveDemo(envelope);
    }

    private static IEnumerable<JsonValue> PatchLines(int added, int removed)
    {
        for (int i = 0; i < removed; i++) yield return Str($"-    old line {i + 1}");
        for (int i = 0; i < added; i++) yield return Str($"+    new line {i + 1}");
    }

    /// The limits arrive the way real ones do: a status line envelope through `Receive`, one
    /// per session (ponyfish on Fable, bluefin on Sonnet), with the same rate limits.
    private void SendDemoStatusline()
    {
        var now = DateTime.UtcNow;
        var rateLimits = Obj(
            ("five_hour", Obj(
                ("used_percentage", Num(61)),
                ("resets_at", Num(ContractJson.ToUnixSeconds(now.AddHours(1).AddMinutes(52)))))),
            ("seven_day", Obj(
                ("used_percentage", Num(34)),
                ("resets_at", Num(ContractJson.ToUnixSeconds(now.AddDays(3)))))));
        Send(EventKind.Statusline, Ponyfish, ponyfishCwd, payload: Obj(
            ("session_id", Str(Ponyfish)),
            ("model", Obj(("id", Str("claude-fable-5-1")), ("display_name", Str("Fable 5.1")))),
            ("context_window", Obj(
                ("context_window_size", Num(1_000_000)),
                ("used_percentage", Num(36)),
                ("total_input_tokens", Num(357_200)),
                ("current_usage", Obj(
                    ("input_tokens", Num(5_200)),
                    ("output_tokens", Num(2_100)),
                    ("cache_creation_input_tokens", Num(34_000)),
                    ("cache_read_input_tokens", Num(318_000)))))),
            ("cost", Obj(
                ("total_cost_usd", Num(1.42)),
                ("total_duration_ms", Num((3 * 3600 + 27 * 60) * 1000)),
                ("total_api_duration_ms", Num(12 * 60 * 1000)),
                ("total_lines_added", Num(2351)),
                ("total_lines_removed", Num(147)))),
            ("effort", Obj(("level", Str("high")))),
            ("thinking", Obj(("enabled", JsonValue.True))),
            ("fast_mode", JsonValue.False),
            ("exceeds_200k_tokens", JsonValue.True),
            ("rate_limits", rateLimits)));
        // bluefin's turns: the first started 18 minutes ago; one edit, +5 −1.
        Send(EventKind.Statusline, Bluefin, bluefinCwd, payload: Obj(
            ("session_id", Str(Bluefin)),
            ("model", Obj(("id", Str("claude-sonnet-5-5")), ("display_name", Str("Sonnet 5.5")))),
            ("context_window", Obj(
                ("context_window_size", Num(200_000)),
                ("used_percentage", Num(23)),
                ("total_input_tokens", Num(45_100)),
                ("current_usage", Obj(
                    ("input_tokens", Num(3_100)),
                    ("output_tokens", Num(1_400)),
                    ("cache_creation_input_tokens", Num(8_000)),
                    ("cache_read_input_tokens", Num(34_000)))))),
            ("cost", Obj(
                ("total_cost_usd", Num(0.07)),
                ("total_duration_ms", Num(18 * 60 * 1000)),
                ("total_api_duration_ms", Num(2 * 60 * 1000)),
                ("total_lines_added", Num(5)),
                ("total_lines_removed", Num(1)))),
            ("effort", Obj(("level", Str("high")))),
            ("thinking", Obj(("enabled", JsonValue.True))),
            ("fast_mode", JsonValue.False),
            ("exceeds_200k_tokens", JsonValue.False),
            ("rate_limits", rateLimits)));
        state.SeedDemoPlanUsage();
    }

    private static List<TranscriptTurn> DemoTurns()
    {
        var now = DateTime.UtcNow;
        return
        [
            new TranscriptTurn
            {
                Id = "demo-turn-1",
                Prompt = "Sketch the notch shape with concave ears and a spring morph",
                StartedAt = now.AddMinutes(-52),
                EndedAt = now.AddMinutes(-47),
                Files =
                [
                    File("windows/src/Notchcode.App/Notch/NotchShape.cs", "new",
                    [
                        (0, 1,
                        [
                            "+public static class NotchShapes",
                            "+{",
                            "+    public static (double Top, double Bottom) ClampedRadii(double top, double bottom, double width, double height)",
                            "+    {",
                            "+        double t = Math.Max(0, Math.Min(top, Math.Min(width / 4, height / 2)));",
                            "+        double bodyWidth = width - 2 * t;",
                            "+        double b = Math.Max(0, Math.Min(bottom, Math.Min(bodyWidth / 2, height - t)));",
                            "+        return (t, b);",
                            "+    }",
                            "+}",
                        ]),
                    ]),
                    File("windows/src/Notchcode.App/UI/Theme.cs", "edit",
                    [
                        (40, 40,
                        [
                            " public static partial class Radius",
                            " {",
                            "     public const double WingsBottom = 14;",
                            "-    public const double CardBottom = 22;",
                            "+    public const double CardBottom = 26;",
                            "+    public const double CardTop = 18;",
                        ]),
                    ]),
                ],
                Tokens = new TokenUsage { Input = 9_100, Output = 6_200, CacheRead = 180_000, CacheWrite = 22_000 },
                Model = "claude-fable-5-1",
            },
            new TranscriptTurn
            {
                Id = "demo-turn-2",
                Prompt = "Make the permission card answer through the hook with a 60 second deadline",
                StartedAt = now.AddMinutes(-31),
                EndedAt = now.AddMinutes(-24),
                Files =
                [
                    File("windows/src/Notchcode.App/State/AppState.cs", "edit",
                    [
                        (118, 118,
                        [
                            "     /// Replies exactly once and forgets the request.",
                            "     private void Resolve(string id, HookReply reply)",
                            "     {",
                            "-        Handlers[id]?.Invoke(reply);",
                            "+        if (!Handlers.Remove(id, out var handler)) return;",
                            "+        Pending = Pending.RemoveAll(p => p.Id == id);",
                            "+        handler(reply);",
                            "     }",
                        ]),
                    ]),
                    File("windows/src/Notchcode.App/Features/Requests/RequestCards.cs", "new",
                    [
                        (0, 1,
                        [
                            "+// RequestCards.cs",
                            "+",
                            "+public sealed class PermissionCard : StateView",
                            "+{",
                            "+    private const string FooterText = \"At 0:00 the terminal asks instead. Nothing is denied for you.\";",
                        ]),
                    ], truncatedExtra: 88),
                ],
                Tokens = new TokenUsage { Input = 12_300, Output = 8_800, CacheRead = 240_000, CacheWrite = 31_000 },
                Model = "claude-fable-5-1",
            },
            new TranscriptTurn
            {
                Id = "demo-turn-3",
                Prompt = "Wire the permission card to the pipe",
                StartedAt = now.AddMinutes(-3),
                EndedAt = null,
                Files =
                [
                    File("windows/src/Notchcode.App/Notch/NotchRootView.xaml.cs", "edit",
                    [
                        (18, 18,
                        [
                            "     private FrameworkElement Build(NotchMode mode, Size body)",
                            "     {",
                            "-        return new Grid();",
                            "+        return state.CurrentPending is { } request",
                            "+            ? new AttentionView(state, request, body)",
                            "+            : new WingsView(state, body);",
                            "     }",
                        ]),
                    ]),
                ],
                Tokens = new TokenUsage { Input = 4_200, Output = 2_100, CacheRead = 96_000, CacheWrite = 8_000 },
                Model = "claude-opus-5",
            },
        ];
    }

    /// bluefin: one finished turn without file changes, and the current one editing the pipe.
    private static List<TranscriptTurn> BluefinTurns()
    {
        var now = DateTime.UtcNow;
        return
        [
            new TranscriptTurn
            {
                Id = "demo-bluefin-1",
                Prompt = "Why does the hook sometimes time out on the first event?",
                StartedAt = now.AddMinutes(-18),
                EndedAt = now.AddMinutes(-16),
                Files = [],
                Tokens = new TokenUsage { Input = 3_100, Output = 1_400, CacheRead = 52_000, CacheWrite = 6_000 },
                Model = "claude-sonnet-5-5",
            },
            new TranscriptTurn
            {
                Id = "demo-bluefin-2",
                Prompt = "Retry the pipe connect with backoff",
                StartedAt = now.AddMinutes(-1),
                EndedAt = null,
                Files =
                [
                    File("windows/src/Notchcode.App/Transport/PipeServer.cs", "edit",
                    [
                        (88, 88,
                        [
                            "     public void Start()",
                            "     {",
                            "-        Bind();",
                            "+        var delay = 0.05;",
                            "+        while (!Bind() && delay < 2)",
                            "+        {",
                            "+            Thread.Sleep(TimeSpan.FromSeconds(delay));",
                            "+            delay *= 2;",
                            "+        }",
                            "     }",
                        ]),
                    ]),
                ],
                Tokens = new TokenUsage { Input = 2_000, Output = 900, CacheRead = 40_000, CacheWrite = 3_000 },
                Model = "claude-sonnet-5-5",
            },
        ];
    }

    /// A FileChange whose counts, snippet and patch all come from unified-diff style lines
    /// ("+added", "-removed", " context"), one hunk per (old start, new start, lines).
    /// `truncatedExtra` adds that many added lines the patch leaves out, as a long diff would.
    private static FileChange File(string path, string kind, IReadOnlyList<(int OldStart, int NewStart, string[] Lines)> hunks,
        int truncatedExtra = 0)
    {
        var patch = new List<DiffLine>();
        int added = 0, removed = 0;
        foreach (var (oldStart, newStart, lines) in hunks)
        {
            int oldCount = lines.Count(l => !l.StartsWith('+'));
            int newCount = lines.Count(l => !l.StartsWith('-'));
            patch.Add(new DiffLine { Kind = DiffLineKind.Hunk, Text = $"@@ -{oldStart},{oldCount} +{newStart},{newCount} @@" });
            int oldLine = Math.Max(oldStart, 1);
            int newLine = Math.Max(newStart, 1);
            foreach (var raw in lines)
            {
                string text = raw.Length > 0 ? raw[1..] : "";
                switch (raw.FirstOrDefault())
                {
                    case '+':
                        patch.Add(new DiffLine { Kind = DiffLineKind.Added, Text = text, NewLine = newLine++ });
                        added++;
                        break;
                    case '-':
                        patch.Add(new DiffLine { Kind = DiffLineKind.Removed, Text = text, OldLine = oldLine++ });
                        removed++;
                        break;
                    default:
                        patch.Add(new DiffLine { Kind = DiffLineKind.Context, Text = text, OldLine = oldLine++, NewLine = newLine++ });
                        break;
                }
            }
        }
        return new FileChange
        {
            Path = path,
            Added = added + truncatedExtra,
            Removed = removed,
            Kind = kind,
            Snippet = patch.Take(Theme.Limits.InlineSnippetMaxLines - 1).ToList(),
            Patch = patch,
            PatchTruncated = truncatedExtra > 0,
        };
    }
}
