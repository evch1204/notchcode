# notchcode plan

## What it is

A menu-bar-less agent app that draws a black shape over the MacBook notch. Closed, it is invisible. It is sidecar-pane for the notch: the companion pane that normally needs a second terminal split shows up on top instead. Four jobs:

1. **Traffic light.** From any app or space you can see whether Claude Code is running, blocked on you, or done, across every session.
2. **Doorbell.** When Claude is blocked, the notch grows to two rows and says what it wants (Attention state). One key unblocks it: allow, deny, commit.
3. **Companion.** Press the notch any time and the card opens on Sessions (grouped by repository, one row per worktree, subagent lanes), then Changes (each turn, its files including subagent edits, the diff under its row), Files (the repository tree with a scrollable preview), Usage (limits, context, tokens, cost). Tabs in that order: Sessions · Changes · Files · Usage. Read from Claude Code's own session files, the same data contract as sidecar-pane. In Files, `⌘B` or the sidebar pill in the preview header folds the tree away so the preview fills the well (remembered across launches; with no file open the tree always shows), and a Markdown file (.md, .markdown, .mdx) opens rendered, with a Preview · Code switch on `P` held per session (owner, 2026-09-28).
4. **Teleport.** Press a session and land in its terminal window. With worktrees this is the main reason to use it.

Big diffs scroll inside the card. A snippet under 8 lines opens inline by default. Full review still belongs to the editor, and `⌥⏎` jumps there.

## Design

Direction: Island chrome with Claude CLI content, and the toolbar when open. Settled 2026-09-27; the toolbar chosen 2026-09-27 evening from three redesigns (Terminal, Toolbar, Aperture; canvas pages "Redesign · …").
Canvas, "Final" page: https://claude.ai/artifact/AChgFMt8kby2qukkVNxwrn. Toolbar boards: the "Redesign · Toolbar" page (B1–B13, BM1–BM4).

- One black shape that morphs. Closed 180×32 pt. Wings grow sideways first, the card grows down last. Springs, not eases. Closing runs backwards, faster.
- Nothing is ever drawn over the centre 180 pt; that is the camera. Content lives in the two wings and, when open, below the notch.
- SF Pro for text, SF Mono for commands and paths, tabular numbers. Clay `#D97757` and the asterisk spinner for Claude identity, and the same clay family for "needs you" (the triangle glyph, the two-row shape and the words carry the distinction; amber was tried and dropped on 2026-09-27). Green for done, white pill for the primary action.
- Every button carries a keycap hint. `⌥ space` focuses the notch from anywhere, `⏎` primary, `⌫` deny, `A` always, `1–4` options, `esc` closes.
- Reduce Motion is respected: crossfades instead of springs.

### Toolbar decisions (owner, 2026-09-27 evening)

The open card is a toolbar window hanging from the notch; the collapsed states stay quiet.

- **Collapsed while working: unchanged.** Spark, verb, one dot per session, elapsed or agent count. Small movement only (the spark pulse, the agent squares). The tools never replace the wings on their own.
- **Hover on a collapsed strip (click-to-open owners):** after the same 250 ms dwell as the rim, the right wing crossfades from the dots to the four tool icons, unfolding from behind the camera (30 ms stagger). A press opens the card straight on that tool. Leaving puts the dots back. Hover-to-open owners get the card, as before.
- **Needs you keeps its two-row size change** (the shape growing is what makes it visible). Row 1 as today: triangle, "Needs you", session, clock. Row 2: the request ("Allow Bash?" + the command, middle-truncated) on the left; Deny · Always · Allow as toolbar segments on the right (Skip · Edit · Commit for a commit), Allow white and primary, the 58 s countdown draining along Allow's bottom edge. One press answers without opening anything. Click on row 1, or `⌥ space`, opens the card with the request in the well.
- **Open card = the toolbar.** The strip stays on top: status segment on the left (two lines: name, then branch · model · verb · agents), the four tools with the selected one filled on the right, a rule, the gear. The selection fill and the keyboard focus ring glide between tools (`⇥`, `1–4`). Under the strip a hairline with a short bridge beneath the selected tool, then the content well (a lighter inset holding the pane, the request card, the question, or Settings), then a footer with that tool's keys, `esc`, and the 5-hour bar. Panel height per tool (Sessions, Changes, Files, Usage, Settings each have their own), re-targeted with one spring when the tool changes; the pane slides 48 pt toward its new anchor with parallax. Segments lift on hover and depress on press. Panes themselves (Sessions, Changes, Files, Usage, Settings with Quit) are the current ones, inside the well.
- **Peek and resting: unchanged** (the check draws on, counts count up; the dim resting row).
- **Light outside the notch.** The hardware notch covers the centre 180 pt, so any light that only runs along the inside of the bottom edge disappears in the middle. Every glow is drawn as a halo *outside* the black silhouette: the hover rim sits on the outer edge of the shape (not inset) with its glow spilling 8–12 pt below and around the wings; the clay bleed sits below the bottom edge and is wider than the notch so both wings carry it; the done peek's green and the working state's spark live in the wings. No light effect carries information only under the camera.

## States

| State | Shape | Content | Leaves when |
|---|---|---|---|
| Closed | notch only | nothing | a session starts (or always, if the owner picks "pure notch" when idle) |
| Resting | 420×32 pt, dim | a static dot in the session's colour + the worktree name at 60% · nothing moving. Hover brightens it and lights the rim. Click opens the card | a session works again, or every session is idle 2 h (then closed) |
| Wings | 470×32 pt | state glyph + the focused worktree name · on the right "N agents" while subagents run, else a state word only for Needs you / Done, then "+N sessions" for other live sessions · hover: the right wing shows the four tools and the left wing names the one under the mouse | the last session ends |
| Attention, needs you | 640×72 pt (wider when the notch is), two rows, clay | row 1: Needs you · session · clock; row 2: "Allow Bash?" + the command, then Deny · Always · Allow segments, the countdown draining along Allow · click row 1 or `⌥ space` opens the card | the event is answered |
| Peek | 460×32 pt | one line: file and ±counts, or the question's first line | 4 s |
| Card | 640 pt wide (wider when the notch is, so the tools fit), grows down to the tool's height | the toolbar: strip on top, bridge, well, footer (see Toolbar decisions) | answered, or `esc` |

Wings never grow taller for passive events. Only blocking events open the card by themselves.

## Events

| Event | Kind | Source hook | Card shows | Actions |
|---|---|---|---|---|
| Permission request | blocking | `PermissionRequest` | tool, command or path, reason, countdown. For Edit / Write / MultiEdit the real diff, built from the hook's old and new text, opens inside the card with `D` and scrolls | Allow, Always, Deny |
| Commit proposed | blocking | `PreToolUse` on `Bash(git commit *)` | message, files, ±counts; each file row opens its diff in place | Commit (allow), Edit, Skip (deny) |
| Question | preview only | `Notification` + transcript | the question and its options | Answer in terminal (teleport). No hook can answer a question from outside. |
| Edit landed | silent | `PostToolUse` on Edit/Write | no peek by default (a setting turns per-file peeks on). Updates the verb and the Changes tab | — |
| Shell command changed files | silent | `PostToolUse` on Bash (baseline from `UserPromptSubmit`) | no peek. Updates the Changes tool: the files show under the turn, tagged "shell", diff against HEAD | — |
| Turn finished | passive | `Stop`, `Notification` idle_prompt | peek: Done · session · files and ± totals of the turn. Click opens Changes | Open in terminal |
| Subagent finished | passive | `SubagentStop` | peek: ■ type finished · session | — |
| Session start / end | silent | `SessionStart`, `SessionEnd` | updates the session list | — |

Permission timeout: 58 s (the app and the socket share one deadline; the hook itself waits 59 s), then the hook returns nothing and Claude Code's own terminal prompt continues. Nothing is denied on the owner's behalf.

Commit means letting Claude's own `git commit` through. Push never happens from the notch.

## Subagents

`SubagentStart` / `SubagentStop` hooks plus the transcript (Agent tool calls) give one `Agent` per subagent. Running agents show as a count in the wings and as lanes under their session in the Sessions tab; finished ones collapse into "3 done".

## Preferences

A Settings page inside the card (gear, or ⌘, while the card is open). Never a separate macOS window: one surface, one set of keys. Idle style (agents in the notch, or pure notch), attention style (two-row, or wings only), peeks on/off and their length, open on click or hover, the ⌥ space hotkey, agents in the wings, and an optional macOS notification for blocking events. Stored as one JSON blob in UserDefaults. Settings also holds Connect / Disconnect.

**Rule exception, decided 2026-09-27:** the app may edit `~/.claude/settings.json`, and only that file, and only to add or remove its own hook entries, after a backup. Everything else stays hook-only.

## Data: session files first, hooks on top

Like sidecar-pane, the app reads `~/.claude/projects/<cwd>/<session>.jsonl` directly and polls for changes every 2 s. That alone gives sessions, prompts, files, full diffs (`structuredPatch`), tokens, and estimated cost, with no setup and for sessions that started before the app. Hooks add what the files never record: the live permission and commit decisions, and precise start/stop timing. When both know a session, hooks win on state.

## Sessions the list must not show, and edits it cannot see (2026-09-28)

- **Helper runs.** Claude Code starts short runs of its own in a session's folder (naming a branch when a worktree is made, summarising). They write a transcript beside the real one, fire the same hooks, and ended up as a second "seadevil" row: Done, no files. Their lines carry `entrypoint: "sdk-cli"` (the owner's carry `"cli"`); the watcher marks such transcripts headless and the app drops any row with that id. Decided and built 2026-09-28.
- **Edits made through Bash show in Changes.** Changes reads `Edit`, `Write` and `MultiEdit` tool calls from the transcripts, but a session in bypass-permissions mode edits with `sed`, heredocs and scripts, so its turns said "no file changes" although the tree changed. Decided 2026-09-28 and built: the `PostToolUse` hook also matches `Bash`. On a Bash call, and on `UserPromptSubmit` (the turn's baseline), the hook script runs read-only git in the session's cwd (`GIT_OPTIONAL_LOCKS=0`): `git status --porcelain=v1 --untracked-files=all`, `git diff HEAD`, and each untracked file (first 20) diffed against `/dev/null`, capped at 256 KB. Both texts go base64 in the envelope's `tree` object (root, HEAD sha, status, diff, truncated). Outside a git work tree, or without git, nothing is added. About 0.2 s on this repo. The app keeps one baseline per session: the prompt's report replaces it; each Bash report is compared file by file (status code, ± counts, a hash of the diff body), and every file that is new, changed, or back to HEAD is attributed to the session's current turn, then the report becomes the baseline. A file already dirty at the prompt counts only when its diff changes; staging alone does not count; after a commit (HEAD moved) files that left the list are not counted. Attributed files are FileChanges of kind "shell" whose diff is the file's whole diff against HEAD (not just that command's part), listed after the turn's transcript files (the transcript wins on the same path), with a small "shell" tag after the name. They count toward the done peek. No peek of their own. With no baseline (the app started mid-turn) the first Bash report only becomes the baseline. The baseline is dropped on SessionEnd. The app itself still never runs a command; the hook does. Two sessions sharing one worktree can see each other's edits as their own; accepted.

## Sessions and worktrees

A session is a worktree plus a branch. Named by the worktree folder (`ponyfish`), with the repo and branch underneath. Collapsed, the wings show the most urgent state and one dot per session. The sessions card lists them: state, verb, elapsed. `⏎` on a row teleports.

Teleport: the hook forwards `TERM_PROGRAM` and the session's process id. iTerm2 and Terminal.app can focus the exact window through AppleScript. VS Code and Cursor: `code --reuse-window <cwd>`. Ghostty: activate the app only, until it grows a scripting interface.

## Feasibility (checked against the Claude Code docs, 2026-09-27)

| Need | Status | Note |
|---|---|---|
| Allow / deny a permission from the app | yes | `PermissionRequest` hook, `hookSpecificOutput.decision.behavior` allow/deny. No output = terminal prompt continues. |
| Gate `git commit` | yes | `PreToolUse`, matcher Bash, `permissionDecision` allow/deny. |
| Answer a multiple-choice question from the app | no | No hook can answer `AskUserQuestion`. The card previews and teleports. |
| Know when Claude needs input or finished | yes | `Notification` types `permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`; `Stop`. |
| Session id and cwd in every hook | yes | every payload carries `session_id`, `cwd`, `transcript_path`. |
| Which terminal runs the session | partial | not in the payload; hooks inherit the environment, so the script forwards `TERM_PROGRAM` and friends. |
| Edit diffs | partial | the payload has the file path; the hook runs `git diff --numstat` for counts and grabs a snippet. |
| Context size and cost | yes | statusline JSON: `context_window`, `cost`. |
| 5-hour and weekly usage percent | yes, via the status line | Claude Code passes `rate_limits` to the `statusLine` command. Our script forwards it to the socket and chains the previous status line (Orca, sidecar) so nothing breaks. No keychain, no API calls. |
| Buttons over the notch | yes | a non-activating panel at status-bar level, positioned from `NSScreen.safeAreaInsets`; the same trick Boring Notch uses. Clicks land, focus stays in the terminal. |
| Long-running hook without blocking Claude | yes | hooks support `async: true`; the permission hook waits up to 60 s on a Unix socket. |

## Install

Three ways in, shortest first: the Claude Code plugin (`plugin/`, one `claude plugin install`), the Settings → Connect button, or `node scripts/connect.mjs`. Two pieces either way.

- The app: a signed, notarised `.app` from GitHub Releases, also as a Homebrew cask.
- Usage limits: Connect (Settings or `connect.mjs`) also makes `hooks/notchcode-statusline.sh` the `statusLine`. It forwards the status line JSON as kind `statusline` (at most every 5 s per session) and runs the previous status line, saved in `~/Library/Application Support/notchcode/statusline-chain.json` as `{"previous": …}`, with the same stdin. Disconnect restores it. Plugins cannot set `statusLine`, so plugin users also run Connect for limits.
- The hooks: a Claude Code plugin (`hooks/hooks.json`) installed with `claude plugin install notchcode@<marketplace>`. Plugin hooks merge alongside the owner's existing hooks; nothing in `settings.json` is overwritten. A `SessionStart` hook launches the app if it is not running.

## Build plan

Layout of the repo:

- `project.yml`: XcodeGen spec. `xcodegen generate` writes `notchcode.xcodeproj` (ignored by git). Needs the Xcode licence accepted first: `sudo xcodebuild -license accept`.
- `Sources/notchcode/Model/Contract.swift`: the one shared contract: wire types, sessions, pending requests, file changes, turns, usage. Everything else talks through it.
- `Sources/notchcode/App`, `Notch`, `Views`, `Theme.swift`: the window over the notch, the shape and its morph, the states, the cards and companion tabs.
- `Sources/notchcode/Transport/SocketServer.swift`: Unix socket listener, one JSON line per event, replies for blocking events, deadline handling.
- `Sources/notchcode/Sessions/TranscriptReader.swift`: turns, files and tokens from `~/.claude/projects/<cwd>/<session>.jsonl`.
- `hooks/notchcode-hook.sh`: the single hook script, called with the event kind as its argument. Prints nothing unless the app replied.
- `scripts/connect.mjs`, `scripts/disconnect.mjs`: add or remove only our hooks in `~/.claude/settings.json`, beside the owner's own hooks. `scripts/send-test-event.sh`: fires a fake event at the socket.

Milestones:

1. **See it** (today): the shape over the notch, closed / wings / attention / peek / card, springs, a `--demo` flag that walks the states with sample data, the permission card with working Allow / Deny / Always buttons.
2. **Feel it**: the socket, the hook script, connect and disconnect; a real permission round-trip; Stop and Notification drive the wings.
3. **Use it**: transcript reader feeding Changes and Usage; Sessions with teleport; commit gate.
4. **Ship it**: plugin packaging, notarised build, Homebrew cask.

## Transport

Unix socket at `~/Library/Application Support/notchcode/notchcode.sock`. Hook scripts write one JSON line and, for blocking events, read one line back. Scripts are plain `sh`, print nothing, exit 0 when the app is absent.

## Not doing

- Music, calendar, file shelf, or anything the existing notch apps already do.
- Editing files, running commands, or pushing from the app.
- Full diff review in the notch.
- Displays without a notch. Later: a floating pill at top centre.

## References

- Boring Notch (open source) for window placement and the expand animation.
- `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` for the notch geometry.
- Claude Code hooks: https://code.claude.com/docs/en/hooks-guide.md
- Claude Code plugins: https://code.claude.com/docs/en/plugins/components.md
- Claude Code statusline: https://code.claude.com/docs/en/statusline.md
- Design canvas: https://claude.ai/artifact/AChgFMt8kby2qukkVNxwrn

## Motion decisions (owner, 2026-09-27)

Implement now: hover rim light on the closed and resting notch for click-to-open owners (hover-to-open owners get the card on the same dwell, so no rim); attention arrival with the clay bleed (the breath was dropped 2026-09-27 evening: on top of the height spring it read as a bounce); tab slide with parallax; done peek with the check drawing on and counts counting up; the simple teleport fold (card folds into the notch over 0.28 s, terminal activated at 0.15 s, no scale, no blur). No blur anywhere: content fades and rises 10 pt. The rest of the table below is later, or never.

After Done: 4 s, then the Resting state (see States). Never a bare notch while a session exists, unless the owner chose pure notch.

Toolbar motion (owner, 2026-09-27 evening), all in Theme: tools unfold from behind the camera (offset 16 pt toward the centre + opacity, spring 0.28/1.0, 100 ms + 30 ms per tool); segment hover lift (fill 9%) and press depress (scale 0.94, 0.12 s); selection fill and focus ring glide with `matchedGeometryEffect` (spring 0.30/0.88); the bridge slides with the same spring; panel height re-target in one spring (0.40/0.94); pane re-anchor slide 48 pt + parallax 40%; Allow pops in (0.92 → 1.08 → 1) and its countdown bar drains from the deadline date in a `TimelineView`. Reduce Motion: crossfades, no offsets, no press scale, the bar steps once a second.

**Settled, no bounce (owner, 2026-09-27 late).** The toolbar build bounced more than `main`: the wider, taller card made the 0.72 width spring overshoot visibly, the breath played on attention, and opening often ran the re-target spring instead of the sequenced ones (mode and card height changed together, and the second change replaced the first animation). Now every shape spring is damped at 0.9 or more: width 0.42/0.9, height 0.48/0.9, close at 0.7× those responses (30% faster), re-target 0.40/0.94 and only when the target actually changed. Tool names: a caption pill under the strip, centred under the tool, after 150 ms at rest (it follows the mouse between tools at once), and for 1.2 s after `⇥` or `1–4`. On the collapsed strip there is no room below (outside the black) or beside the tools, so the left wing shows the name instead.

## Usage tab layout (owner, 2026-09-27)

One page, no scrolling, fixed heights. Row 1: two big tiles, 5-hour and Week (percent, bar, resets in / at). Row 2: three small tiles, Context (36% of 1M · 357k), This session (tokens · ~$), Today (tokens · ~$). Row 3: one thin four-part token bar with inline legend chips. Footer: one tertiary line, "cost estimated from tokens · limits updated 3m ago" (or "as of 2:14 PM"). Limits keep their last known value between status line reports, since the status line only reports when Claude Code redraws; a window whose reset time has passed dims its number and says "reset at …". Only before the first report do the big tiles show "—" and "connect the status line", and the footer says "limits from Claude Code's status line". The layout never changes.

Changed-file rows (Changes, the commit card, the Files preview header): the file name only, in ink, middle-truncated when long, the full path on hover; the cells and counts always stay visible at the right (owner, 2026-09-28).

Changes tool (owner, 2026-09-28, replaces both earlier passes today; the Final-board sizes read too small next to the other tools): the Toolbar layout (the Toolbar page's Changes board, B10) in the app's shared type scale and row metrics. No font, size, padding or radius exists only for Changes. Turns and files are one flat list inside the well, no boxes around them, `spaceXS` apart. A turn row is a Sessions row: chevron (the shared chevron font), prompt in body semibold (13 pt), then "3 files", "+48 −9", and the duration or "Working 4:12" in caption (12 pt; "Working" caption medium), row padding 8 / 6 pt, 10 pt corner, the keyboard cursor's fill. Its files follow, indented one chevron column (the Sessions `chevronColumn`, 14 pt) so their chevrons sit under the turn's title; a file row has the same padding, corner and fill: chevron, file name only in mono caption (12 pt, the Files tab's mono size; full path on hover), the five cells, "+12 −3" in mono caption. A diff sits in a rounded box (the snippet radius, 8 pt, on the inset white) under its open file row: 16 pt lines in the Files preview's mono (11 pt) with its padding and gutter, two dim number columns (old, new), the +/− prefix, added lines green on faint green, removed red on faint red, context grey, hunks blue; capped at 220 pt, it scrolls and its last line says "… 9 more lines · scroll" in caption. The permission and commit cards use the same row and box.

## Motion

Canvas, "Motion" page: https://claude.ai/artifact/AChgFMt8kby2qukkVNxwrn (seven looping boards). Rules: one shape, never two. Width before height on open, height before width on close, close 30% faster. Content waits 120 ms then blurs in from 8 px; rows stagger 40 ms. Wing text slides out from behind the camera. Every shape move is interruptible: a new target retargets the spring mid-flight; content transitions finish on their own. Reduce Motion: 200 ms crossfades, no overshoot, no breath, no shimmer; rings and counters jump.

What exists today: width/height springs (open 0.45/0.72 and 0.55/0.78, close 0.34/0.86 and 0.30/0.90), a delayed content fade, the peek edge line, glyph pulse and breathe. Everything else below is new.

| Transition | Duration · curve | Delay | Interruptible | Reduce Motion |
|---|---|---|---|---|
| Closed → wings (width) | spring 0.45 s, damping 0.72 | 0 | yes | crossfade 0.2 s |
| Wings → attention (height +40 pt) | spring 0.5 s, damping 0.65, plus a 3% scale breath from the top edge | 0 | yes | crossfade |
| Attention → card (height) | spring 0.55 s, damping 0.78 | 0 | yes | crossfade |
| Any → closed | height spring 0.30/0.90 then width 0.34/0.86 | 0 | yes | crossfade |
| Content in | opacity 0→1, blur 8→0 pt, 0.2 s ease-out | 120 ms after the shape starts | no | opacity only |
| Card rows | translateY 10→0 pt, opacity, 0.22 s ease-out | 120 ms + 40 ms per row | no | opacity only |
| Wing text | translateX ±30 pt → 0 (from behind the camera), 0.25 s ease-out | 120 ms | no | none |
| Amber bleed (attention) | radial glow under the notch, 0→100% in 0.3 s, settles to 40% by 1 s | 0 | yes | static 40% |
| Countdown ring + edge line | linear drain over the 58 s deadline, driven by the deadline date, not a timer tick | 0 | yes | ring only, no line |
| Done peek: check | circle pops 0.3 s with 15% overshoot; stroke draws on 0.35 s ease-out | 150 ms | no | appear |
| Done peek: counts | +N / −N count up 0.6 s ease-out | 250 ms | no | jump |
| Done peek: retract | width spring 0.34/0.86 | at 4 s | yes | crossfade |
| Agent square appears | scale 0→1.25→1, 0.3 s | 0 | no | fade |
| Agent count | fade + 6 pt rise, 0.2 s | 60 ms | no | fade |
| Running lane shimmer | 8% white sweep, 2.4 s linear, repeats | 0 | yes | none |
| Agent finish | square → check, same pop | 0 | no | crossfade |
| Teleport | card content scales to 92%, blurs 6 pt and fades in 0.2 s; shape height collapses 0.28 s ease-in; width settles to wings with a small bounce 0.3 s; the terminal is activated at the 0.15 s mark so it rises behind | 0 | no | crossfade, activate at once |
| Tab switch | pill glides 0.32 s with 20% overshoot; outgoing pane slides 70 pt and fades 0.2 s; incoming slides in 0.32 s ease-out; inner groups move at 40% speed; bars fill 0.5 s after landing | 0 | yes | crossfade |
| Hover rim (hover-open only) | 2 pt rim light on the bottom edge, 0.18 s in, 0.25 s out, 12 px glow at 12% | after 250 ms at rest | yes | same, no glow |
| Button press | scale 0.97, 0.12 s ease-out, back on release | 0 | yes | none |

Mechanisms, SwiftUI on macOS 14:
- Shape: keep the single `NotchShape` and animate its frame with `withAnimation(.spring(response:dampingFraction:))`; two `withAnimation` blocks for width and height give the sequencing. No `matchedGeometryEffect`: it is one view.
- Content: `.transition(.opacity.combined(with: .blur(radius: 8)))` is not built in; compose `.opacity` with a `.modifier(ActiveBlur)` transition, delays via `.animation(.easeOut.delay(0.12 + 0.04 * index))`.
- Ring and edge line: `TimelineView(.animation)` reading the deadline date, so it stays correct after the app was busy.
- Counters: `Text(count).contentTransition(.numericText())` with `withAnimation(.easeOut(duration: 0.6))`.
- Pops and the breath: `keyframeAnimator` (macOS 14) with `SpringKeyframe`.
- Shimmer: a `LinearGradient` overlay moved by `TimelineView`, masked to the lane.
- Teleport: `phaseAnimator` over three phases (compress, fold, settle), activate the terminal in the second phase.
- Tabs: `.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))`; parallax by offsetting the inset group with a scaled version of the pane's offset.
- Reduce Motion: `Theme.Motion.reduceMotion` already gates the springs; extend it to every entry above.
