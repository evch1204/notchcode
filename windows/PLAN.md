# notchcode for Windows plan

The same app, the same design, the same keys, on a Windows 11 PC that has no notch. The macOS app in `Sources/` is the reference and is never changed by this work. Everything under `windows/` is a second implementation of the one spec in the root `PLAN.md`: read that first; this file holds only what is different on Windows and how the port is built.

Decided 2026-10-12 (owner asked for a Windows version that looks and feels the same; Fable planned it, Opus agents build it in parallel).

## Is it possible

Yes. The hard parts have known answers on Windows:

| Need | macOS today | Windows |
|---|---|---|
| A black shape at the top centre over every app | NSPanel at status-bar level over the hardware notch | A borderless, per-pixel-transparent, topmost tool window (`WS_EX_LAYERED`, `WS_EX_TOOLWINDOW`, `WS_EX_NOACTIVATE`) at the top centre of the primary monitor. There is no camera; the closed shape is the notch. |
| Clicks land, focus stays in the terminal | non-activating panel | `WS_EX_NOACTIVATE` and `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`; the card takes the keys only while open, then hands focus back to the window it took it from. |
| Everything outside the shape is click-through | `hitTest` returns nil | `WM_NCHITTEST` → `HTTRANSPARENT` outside the drawn shape (same outer rect rule as `NotchContainerView`). |
| Hooks reach the app | Unix socket, one JSON line each way | A named pipe `\\.\pipe\notchcode-<username>`, one JSON line each way, same envelope and reply. The hook is a compiled exe, run by Claude Code in exec form (no shell). |
| Springs, morph, hover rim, bleed | SwiftUI springs | One per-frame spring animator (`CompositionTarget.Rendering`) driving the shape's width, height and radii, plus WPF storyboards for content. Response and damping values are the Theme's. |
| Global hotkey | ⌥ space via Carbon | `RegisterHotKey`. Alt+Space first; when another app owns it (PowerToys Run does), Ctrl+Alt+Space, and Settings says which one is live. |
| Transcripts, plans, usage cache | `~/.claude/...` | `%USERPROFILE%\.claude\...`, same layout. The project folder name is the cwd with every non-alphanumeric character replaced by `-` (`C--Users-evanc-Desktop-Personal-Projects-notchcode`). |
| Teleport to the terminal | AppleScript, `code --reuse-window` | Walk up from the hook's parent pid to the first ancestor with a top-level window (WindowsTerminal, Code, Cursor, conhost, wezterm, alacritty); `SetForegroundWindow` with the AttachThreadInput dance. VS Code and Cursor: `code --reuse-window <cwd>`. |
| Git tool | runs `git` | runs `git.exe` from PATH (Git for Windows, which Claude Code already needs), `GIT_TERMINAL_PROMPT=0`, stdin closed, same commands. |
| Usage | `claude -p /usage` | `claude.exe -p /usage` from PATH (`~/.local/bin/claude.exe`), same flags, same `~/.claude.json` cache. |
| Notifications | UNUserNotificationCenter | Windows toast through `ToastNotificationManagerCompat`-free fallback: a tray balloon via `Shell_NotifyIcon` (no package dependency). Off by default, as on macOS. |
| Reduce Motion | `accessibilityDisplayShouldReduceMotion` | `SystemParameters.ClientAreaAnimation == false` ("Show animations in Windows" off). |

What cannot be identical: there is no camera to hide behind, so the closed state is a visible 180×32 black shape with the same ears and corners, hanging from the top edge. That is the Windows notch. Fonts are Segoe UI Variable for text and Cascadia Mono for code and paths (both ship with Windows 11), tabular numerals on. Key names: ⌘ becomes Ctrl, ⌥ becomes Alt; keycaps read `Ctrl B`, `Alt ⏎`, `Ctrl ,`, `Ctrl Q`; ⏎ ⌫ esc ⇥ ↑↓ stay as they are.

## Stack

- **C# 12 on .NET (LTS SDK installed per user at `%LOCALAPPDATA%\Microsoft\dotnet`), WPF.** No Electron, no WebView2, no browser control anywhere. No NuGet packages in the app (System.Text.Json, System.IO.Pipes and WPF are in the box); xunit only in the test project.
- Why WPF and not WinUI 3: WinUI 3 cannot make a per-pixel transparent, non-rectangular, non-activating topmost window without unsupported tricks; WPF does it with `AllowsTransparency` and three extended styles, and its retained-mode DirectX rendering is smooth for this size of surface. Avalonia would work too but adds a dependency for no gain.
- One solution `windows/notchcode.sln`, three projects:
  - `src/Notchcode.App` (WPF, `OutputType WinExe`, the app; self-contained single-file publish for releases).
  - `src/Notchcode.Hook` (console, the hook and status line forwarder, self-contained single-file so it has no dependency on an installed runtime; copied by the app to `%LOCALAPPDATA%\notchcode\bin\` at every launch, as the macOS app copies its scripts).
  - `tests/Notchcode.Tests` (xunit: the diff parsers, the transcript reader, the settings.json merge, the envelope round trip, the spring maths).
- Per-monitor-v2 DPI awareness in `app.manifest`; every size in the Theme is in device-independent pixels, 1:1 with the macOS points.
- MVVM-light: `AppState` is one `INotifyPropertyChanged` class split into partial files, one per concern, exactly as the Swift extensions; views are WPF `UserControl`s in XAML with code-behind for motion. No framework.

## Paths and names on Windows

| macOS | Windows |
|---|---|
| `~/Library/Application Support/notchcode/` | `%LOCALAPPDATA%\notchcode\` |
| `notchcode.sock` | `\\.\pipe\notchcode-<username>` (named pipe; the user name keeps two accounts apart) |
| `bin/notchcode-hook.sh`, `bin/notchcode-statusline.sh` | `bin\notchcode-hook.exe` (`notchcode-hook.exe <kind>`, and `notchcode-hook.exe statusline` is the status line command) |
| `statusline-chain.json`, `statusline-stamps/`, `shell-changes/`, `usage/` | same names under `%LOCALAPPDATA%\notchcode\` |
| UserDefaults blob | `%LOCALAPPDATA%\notchcode\preferences.json` (same keys as `Preferences`) |
| `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` (`CLAUDE_CONFIG_DIR` honoured when set) |
| `~/.claude/projects`, `~/.claude/plans`, `~/.claude.json` | the same under `%USERPROFILE%` |
| `pgrep -xq notchcode \|\| open -g -b com.evch.notchcode` | `notchcode-hook.exe launch` (starts the app from the path saved beside the hook, if no instance owns the pipe) |

## Hooks on Windows (checked against the hooks docs on 2026-10-12)

- Claude Code on Windows runs a hook's `command` through Git Bash when it is installed, else PowerShell. The default therefore differs by machine. The port avoids the shell entirely: every entry uses the exec form, `"command": "C:/Users/<me>/AppData/Local/notchcode/bin/notchcode-hook.exe", "args": ["permission"]`, which Claude Code spawns directly (the docs require a real `.exe` here; forward slashes so Git Bash never eats backslashes). No `shell` field needed.
- stdin is the hook JSON; the exe reads it to the end. Decisions go to stdout as one line: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, deny with `"message"`, always with `"updatedPermissions"` (camelCase, the array verbatim), `PreToolUse` with `permissionDecision` / `permissionDecisionReason`. Byte-identical to what `hooks/notchcode-hook.sh` prints. Exit 0 always.
- `async: true` on the passive hooks only; blocking hooks (PermissionRequest, PreToolUse) must be synchronous and are, with the same timeouts (305 s and 65 s). The app answers "none" at 58 s / 298 s as on macOS.
- The tree report (`user_prompt`, Bash `post_tool`) runs the same read-only git commands with `GIT_OPTIONAL_LOCKS=0`, base64 in the envelope. Untracked files are diffed against `NUL` (`git diff --no-index -- NUL <file>` works on Git for Windows; the exe rewrites the `a/NUL` header to `a/dev/null` so one parser reads both platforms).
- The hook forwards `term_program` from `TERM_PROGRAM` when set (VS Code sets it; Windows Terminal sets `WT_SESSION`, which the exe maps to `term_program: "WindowsTerminal"`), `pid` = the parent process id (Claude Code's node process).
- The status line: `"statusLine": {"type":"command","command":"C:/Users/<me>/AppData/Local/notchcode/bin/notchcode-hook.exe statusline"}` (the status line has no exec form; this string is safe in both Git Bash and PowerShell). It forwards the JSON at most every 5 s per session, then runs the previous status line saved in `statusline-chain.json` with the same stdin through the shell named in the chain file (`bash` when Git Bash exists, else `powershell`), printing exactly its output.
- Connect edits only `~/.claude/settings.json`, only its own entries (marker: the command contains `notchcode-hook`), beside the owner's Orca, BurntToast and sidecar-pane hooks, after a backup. The existing entries on this PC use `"shell": "powershell"` and `-EncodedCommand`; ours never touch them. The status line is chained, never replaced.
- Workspace trust: until the owner accepts a folder's trust dialog Claude Code holds back every hook. Settings says "waiting for Claude Code" when a session is visible in the transcripts but no hook has arrived.

## Window and shape

- One `NotchWindow` (WPF `Window`, `WindowStyle None`, `AllowsTransparency True`, `Background Transparent`, `Topmost True`, `ShowInTaskbar False`, `ShowActivated False`, `ResizeMode NoResize`), `Theme.Size.panelWidth × panelHeight` (900×504 DIPs), centred on the primary monitor's top edge at y = 0. `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` added in `SourceInitialized`; `WM_NCHITTEST` returns `HTTRANSPARENT` outside the shape's outer rect plus `hitSlop`.
- The shape is a `NotchShape` `Geometry` built from the same path as `NotchShape.swift` (`clampedRadii`, ears, corners), filled pure black, no stroke, no shadow when closed. The card and attention states carry the Theme's shadow (a `DropShadowEffect` on the shape only, never on text).
- `ShapeAnimator`: width, height, topRadius and bottomRadius are four springs (response, damping from `Theme.Motion`); width leads and height follows by `axisDelay` on open, the reverse on close at `closeShare`; a new target retargets mid-flight. Spring maths: the closed-form under-damped solution for `response` → stiffness `(2π/response)²`, damping `2·ζ·√k`. Reduce Motion: a 0.2 s ease.
- Hover rim (M7 mirrored outward), the clay bleed, the done peek's check and counts, the wing unfold, tool label caption, segment lift and press: all as the Motion table in the root PLAN, implemented with storyboards or the animator; constants only from `Theme`.
- Keys: `KeyboardController` maps WPF `Key` + modifiers to `NotchKey` exactly as `KeyboardController.swift`, with ⌘ → Ctrl and ⌥ → Alt. While the card is open the window takes focus (`SetForegroundWindow` after a click or the hotkey, both of which grant it); on close it calls `SetForegroundWindow` on the window it remembered, unless a teleport took over.
- The tray icon: Windows has no "open at login" convention for a window-less app and no way to quit one without a menu, so a tray icon with Open · Settings · Quit is on by default, with a switch in Settings to hide it. Everything else is in the card.
- Open at login: a `Run` registry value under HKCU, the switch in Settings' Opening group (default on, as the macOS plan says).

## Layout of `windows/`

Mirrors `Sources/notchcode` one to one so a reader of either finds the other. The file rule is the same: a feature's value types in `<Feature>Model.cs`, its state in `AppState.<Feature>.cs` (partial), its root view in `<Feature>Tab.xaml`.

```
windows/
  PLAN.md                     this file
  README.md                   build, run, connect on Windows
  notchcode.sln
  Directory.Build.props       TargetFramework, LangVersion, Nullable, ImplicitUsings
  scripts/
    dev.ps1                   build Debug and launch (dev.ps1 -Demo)
    send-test-event.ps1       the same events as scripts/send-test-event.sh, over the pipe
    connect.ps1 / disconnect.ps1   dev path; the app's Connect is primary
  src/Notchcode.App/
    App/            App.xaml(.cs), HotKey.cs, KeyboardController.cs, SystemNotifier.cs, TrayIcon.cs, DebugLog.cs, Startup (login item)
    Core/           Contract.cs, JsonValue.cs, Paths.cs, Format.cs, GitDir.cs, HookText.cs, IsoDate.cs, PreferencesStore.cs, ProcessRunner.cs, TextLines.cs, Diff/{DiffBuilder,UnifiedDiff,WordDiff}.cs
    ClaudeCode/     HooksInstaller.cs, OrderedJson.cs, JsonLines.cs, TranscriptReader.cs, TranscriptTurns.cs, TranscriptAgents.cs, TranscriptWatcher.cs
    Transport/      PipeServer.cs
    State/          AppState.cs, AppState.{HookEvents,Requests,Sessions,Card,Peek,Teleport}.cs, NotchTypes.cs
    UI/             Theme.cs, Glyphs.cs, Keycaps.cs, Motion/{Spring,ShapeAnimator,Transitions}.cs, Components, Controls, Segments, ChipFlow, Diff/{DiffView,CodeLines,DiffMinimap,FileRows,ReviewerDiff}
    Notch/          NotchWindow.cs, NotchGeometry.cs, NotchShape.cs, NotchRootView.xaml, WingsView, RestingView, PeekView, AttentionView, CardView, StripView
    Features/       Sessions, Changes, Files (+ MarkdownParser, MarkdownView, RepoFiles), Git (header, rail, stage, picker, GitRunner, writes), Usage, Requests, Settings
    Demo/           DemoScript.cs, AppState.Demo.cs
  src/Notchcode.Hook/  Program.cs (kinds, tree report, pipe client, statusline chain, launch)
  tests/Notchcode.Tests/
```

Shared code between the app and the hook (the envelope, the tree report) lives in the app project and is linked into the hook project as files (`<Compile Include="../Notchcode.App/Core/Contract.cs" />`), so there is one definition and the hook stays a single small exe.

## Build plan: waves, in parallel

Fable orchestrates; each item is one Opus agent in its own worktree, building only the files listed, against the Swift source as the spec. Every agent reads the root `PLAN.md`, this file, and the Swift files it ports, and must `dotnet build` clean before it finishes. Integration is Fable's.

**Wave 0, the seams (2 agents, parallel).** Everything later compiles against these.

- 0a **Scaffold + Contract + State core**: solution, props, three csproj, `app.manifest`; `Core/Contract.cs` (every type in `Contract.swift`, same JSON names), `Core/JsonValue.cs`, `Core/Paths.cs`, `State/NotchTypes.cs`, `State/AppState.cs` (the stored state, derived values and `Refresh()` from `AppState.swift`; the per-concern partials come later and are declared as `partial void`-free stubs so the project builds), `Core/PreferencesStore.cs`, `Core/Format.cs`, `Core/IsoDate.cs`, `Core/TextLines.cs`, `Core/ProcessRunner.cs`, `Core/GitDir.cs`. A `dotnet build` that produces an exe that opens nothing yet.
- 0b **Theme + Glyphs + Motion primitives**: `UI/Theme.cs` with every name from `Theme.swift` (Colors, Radius, Size, Opacity, Motion, Timing, Limits, Fonts, Keys, Glyphs) as static members of nested static classes, `UI/Glyphs.cs` (each glyph as a `Geometry` from the Swift paths), `UI/Motion/Spring.cs` (the solver), `UI/Motion/ShapeAnimator.cs`, `UI/Keycaps.cs`. Builds as a class library stand-in until merged.

**Wave 1, the parts (4 agents, parallel, after wave 0).**

- 1a **Core + Transport + Hook + Tests**: `Core/Diff/*`, `Core/HookText.cs`, `ClaudeCode/*` (reader, turns, agents, watcher, hooks installer with Windows paths and the exec-form entries, ordered JSON), `Transport/PipeServer.cs`, the whole `Notchcode.Hook` exe, `scripts/send-test-event.ps1`, `scripts/connect.ps1`, `scripts/disconnect.ps1`, and tests for each parser and the settings merge (including a copy of this PC's settings.json shape with `shell: powershell` entries that must survive untouched).
- 1b **Shell**: `Notch/*` (window, geometry, shape, rim, root view, wings, resting, peek, attention, card frame with strip, bridge, well, footer), `App/*` (hotkey, keyboard, tray, login item, notifier), `UI/Components`, `Controls`, `Segments`, `ChipFlow`, `Motion/Transitions`, `Demo/*` so `dev.ps1 -Demo` walks every state with sample data. The well shows a placeholder pane per tool until wave 2.
- 1c **Panes A**: `Features/Sessions`, `Features/Changes` (timeline, Direction G), `Features/Files` (tree, preview, Markdown parser and view), `Features/Usage` (calculator, PlanUsage reader and runner, the fixed-height page), each with its `AppState.<Feature>.cs` partial and `<Feature>Model.cs`.
- 1d **Panes B**: `Features/Git` (header, rail, stage, dock and form, branch picker, GitRunner, writes, Direction F motion), `Features/Requests` (permission, commit, plan cards, actions), `UI/Diff/*` (diff view, code lines, minimap, file rows, reviewer diff), `Features/Settings` (every group, Connect / Disconnect / Reconnect states).

**Wave 2, integration (Fable + 1 agent).** Merge the worktrees, wire `AppState.HookEvents / Requests / Sessions / Card / Peek / Teleport`, make the solution build, run `dev.ps1 -Demo`, run `send-test-event.ps1 all` against the running app, fix what the merge broke, screenshot each state.

**Wave 3, review (2 agents, parallel).** One reviews fidelity against the Swift app surface by surface (sizes, colours, keys, motion) and lists every gap; one reviews correctness (pipe deadlines, settings merge safety, git argument safety, DPI, focus return). Fable fixes or files the rest here under "Known gaps".

## Rules for the port

- Never edit anything outside `windows/`, except the three places this plan names: the root `PLAN.md` (a pointer to this file), `CLAUDE.md` (the Windows rules), `.gitignore` (`windows/**/bin/`, `windows/**/obj/`, `windows/.vs/`).
- Every colour, radius, size, spring, duration, font and key label comes from `UI/Theme.cs`; no literal in a view.
- The hook exe prints nothing except a decision line, has no dependency beyond itself, and exits 0 even when the app is not running (pipe absent: return at once).
- The app may act on the owner's behalf only through hooks, plus the two macOS exceptions: it edits only its own entries in `settings.json`, and it runs only `git` (and `claude -p /usage`).
- Closed state: pure black, `closedTop` ears, `closedBottom` corners, no shadow, no chrome, 180×32.
- Reduce Motion respected everywhere a spring runs.
- No `async void` except event handlers; the pipe server and watchers run off the UI thread and marshal to it with `Dispatcher`.

## Checks before a commit

```powershell
cd windows; dotnet build notchcode.sln -c Debug; dotnet test tests/Notchcode.Tests
```

## Built (2026-10-12)

Waves 0 to 3 ran the same day: five Opus agents in parallel for wave 1, four reviewers for wave 3, each in its own worktree, merged by file path (the worktrees were cut from `main`, so each unpacked `windows/` from the branch first). The result on the `windows-port` branch: 146 tests, the demo walks every state, the real app lists this PC's sessions and limits, every test event round-trips through the pipe, the hook publishes as one 16.5 MB exe that starts in about 27 ms, the app publishes self-contained. Not yet pressed on this PC: Connect (it edits the live settings.json; the installer's round trip is proven on a temp copy of the real file instead).

Departures from the Swift worth knowing:

- The hook writes its envelope by hand (no shared Contract.cs link): a trimmed exe must not carry reflection JSON. `HookExeTests` runs the exe against the real `PipeServer`, so the two cannot drift.
- Disconnect removes `"hooks"` when taking ours out leaves it empty, so a file that had no hooks comes back byte for byte; an owner's own empty `"hooks": {}` from before Connect is not restored (disconnect.mjs keeps it).
- A chained status line runs through its own `"shell"` when the chain file names one, else Git Bash when installed, else PowerShell.
- The diff-body hash ignores a trailing newline, so the exe and the parser agree whether or not the last file's diff ends in one.
- Teleport walks from the hook's parent pid (claude.exe) up to the first ancestor with a visible window: Windows Terminal, VS Code, Cursor, Orca, WezTerm, Alacritty, mintty. VS Code and Cursor get `--reuse-window <cwd>`.
- `git.exe` is resolved to an absolute path from fully qualified PATH entries in both the app and the hook: a bare name would be searched in the session's repository first.
- The panes keep a few controls of their own with no shared twin (`Features/StandIns.cs`: VRule, PaneTint, ChevronTurn, BarFill; `UI/Diff/PanesBKit.cs`: RowStack, ColumnStack, TrimText, RollingText) and the Files preview keeps its own virtualised line view (the shared one builds every row).
- The first-run Welcome page is marked seen with a file `%LOCALAPPDATA%\notchcode\welcome-seen`.

## Known gaps

- Multiple monitors: primary only. A Settings choice later.
- Fullscreen exclusive apps draw over the notch (Windows gives no way around it).
- Windows Terminal cannot focus one tab from outside; teleport brings the window up. A classic console reached through Windows Terminal's default-terminal handoff falls back to the first Windows Terminal window.
- With nothing to return focus to (the card opened from the tray), the notch window stays the active window after it closes.
- The attention row's tooltip says "Alt space" even when the fallback chord Ctrl+Alt+Space is the live one.
- Blur radii (rim glow, bleed, shadow) are WPF `BlurEffect` at twice the SwiftUI value: a judgment call until the two run side by side.
- The request card's hero has no letter tracking and its footer does not shrink to fit; the request diff's open and close use the shape springs, not `Theme.Motion.RequestDiff`.
- A symlinked settings.json is handled but untested here (symlinks need Developer Mode).
- Project folders past 200 characters are matched by prefix; two long paths sharing the first 200 characters can collide.
- Transcript prompts with pasted text show the raw `<pasted_content>` tag (the same on macOS).
- After a relaunch with a usage cache under 5 minutes old, Usage shows "from /usage" instead of the behaviour lines until the next run (the same on macOS).
- Login item: Debug builds only log it; a Release build writes the `Run` value.
