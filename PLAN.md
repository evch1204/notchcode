# notchcode plan

## What it is

A menu-bar-less agent app that draws a black shape over the MacBook notch. Closed, it is invisible. It is sidecar-pane for the notch: the companion pane that normally needs a second terminal split shows up on top instead. Four jobs:

1. **Traffic light.** From any app or space you can see whether Claude Code is running, blocked on you, or done, across every session.
2. **Doorbell.** When Claude is blocked, the notch grows to two rows and says what it wants (Attention state). One key unblocks it: allow, deny, commit.
3. **Companion.** Press the notch any time and the card opens on Sessions (grouped by repository, one row per worktree, subagent lanes), then Changes (each turn, its files including subagent edits, the diff under its row), Files (the repository tree with a scrollable preview), Usage (limits, context, tokens, cost). Tabs in that order: Sessions · Changes · Files · Git · Usage (Git moved before Usage on 2026-09-28: the owner reads Usage least, so it sits last). Read from Claude Code's own session files, the same data contract as sidecar-pane. In Files, `⌘B` or the sidebar pill in the preview header folds the tree away so the preview fills the well (remembered across launches; with no file open the tree always shows), and a Markdown file (.md, .markdown, .mdx) opens rendered, with a Preview · Code switch on `P` held per session (owner, 2026-09-28).
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

Commit means letting Claude's own `git commit` through. Push is the Git tool's one write action (see Git tool).

## Subagents

`SubagentStart` / `SubagentStop` hooks plus the transcript (Agent tool calls) give one `Agent` per subagent. Running agents show as a count in the wings and as lanes under their session in the Sessions tab; finished ones collapse into "3 done".

## Preferences

A Settings page inside the card (gear, or ⌘, while the card is open). Never a separate macOS window: one surface, one set of keys. Idle style (agents in the notch, or pure notch), attention style (two-row, or wings only), peeks on/off and their length, open on click or hover, the ⌥ space hotkey, agents in the wings, and an optional macOS notification for blocking events. Stored as one JSON blob in UserDefaults. Settings also holds Connect / Disconnect.

**Rule exception, decided 2026-09-27:** the app may edit `~/.claude/settings.json`, and only that file, and only to add or remove its own hook entries, after a backup. Everything else stays hook-only.

## Data: session files first, hooks on top

Like sidecar-pane, the app reads `~/.claude/projects/<cwd>/<session>.jsonl` directly and polls for changes every 2 s. That alone gives sessions, prompts, files, full diffs (`structuredPatch`), tokens, and estimated cost, with no setup and for sessions that started before the app. Hooks add what the files never record: the live permission and commit decisions, and precise start/stop timing. When both know a session, hooks win on state.

## Git tool (owner, 2026-09-28)

The goal in the owner's words: vibe coders keep pressing approve on the notch instead of switching to the terminal or GitHub Desktop. So the notch shows what is uncommitted and lets them push. Nothing more: no staging, branches, merges or pull requests; that is GitHub Desktop's job and would bloat a notch.

- **A fifth tool, Git (`4`)**, before Usage, which moves to `5` (owner, 2026-09-28: Usage is read least, so it sits on the far right), symbol `arrow.triangle.branch`. Header: branch, then "3 commits to push", "not published yet", or "up to date with origin"; a white primary pill Push (or Publish when the branch has no upstream) with keycap `P`; `⏎` opens the selected file's diff. Below the header: the uncommitted files of the focused session's worktree as rows like Changes (name, cells, counts, diff under the row on `⏎`), then "Recent commits", the last five, each marked when not yet pushed. Empty state: "Nothing to commit · up to date".
- **Commit stays with Claude.** The commit gate already exists and the agent writes better messages. The page never commits.
- **Data**: git read commands in the focused worktree while the tool is open and once when the card opens: status, diff HEAD (and no-index diffs for new files), ahead/behind against the upstream, log -5. The hook's tree report refreshes it too.
- **Push**: `git push`, or `git push -u origin <branch>` when there is no upstream, only on an explicit press, with a confirm line first ("Push 3 commits to origin/seadevil? ⏎ Push · esc"). Progress and the result show inline in the header ("Pushed 3 commits", or git's error text). Credentials are whatever the keychain or the macOS ssh-agent gives a GUI app; when that fails, the error says so and the terminal is the fallback.
- **Rule exception, proposed 2026-09-28, owner to confirm**: the app may run `git`, and only `git`: read-only commands for the page, and `push` on an explicit press. This is the second exception after settings.json. "Push never happens from the notch" in Events is withdrawn. Everything else stays hook-only.
- **Two panes like Files (owner, 2026-09-28, built)**: under the header, which stays across the whole well, the Files split: on the left (`fileTreeShare`) "Uncommitted", one row per file (name, the five ± cells, the counts), then "Recent commits"; on the right the selected file's diff filling the pane, under a Files-style header (the `⌘B` pill, name, counts). A click or `↑↓` selects and shows the diff at once, the first file by default, as GitHub Desktop does; `⏎` only confirms a push. `⌘B` hides the list with the same preference as the Files tree. This replaces the rows that opened their diff underneath.
- **Worktree picker (owner, 2026-09-28, built; superseded by the branch picker below)**: a pill at the header's far left, "notchcode · seadevil ▾" with `W`, replaces the content with every repository a session runs in and all its worktrees (`git worktree list --porcelain`, read-only), each with its branch, "N uncommitted" or "clean", and a "session" tag; `⏎` makes that worktree the tool's target for status, diff, commits and push until the card closes (it follows the focused session until then, and says "not the focused session" when they differ); `esc` leaves the picker before the push confirm and before the card. No branch checkout.
- **Five tools fit (2026-09-28)**: the card and attention row are max(640, notch + 2 × max(tools wing, status wing)); the tools wing keeps 3 pt free on the camera side for the first tool's focus ring, the status wing is at least 204 pt. The collapsed resting and wings shapes widen so the five 20 pt hover tools fit whole.
- **Built 2026-09-28, small calls made while building**: the diff uses the hook's exact flags (`--no-renames`, `a/` `b/` prefixes) so one parser reads both; an unpublished branch tags as "not pushed" the commits on no remote (`rev-list --count HEAD --not --remotes`, one extra read); git runs with `GIT_TERMINAL_PROMPT=0` and stdin closed, so a credential prompt fails at once with "No credentials for origin here · push from the terminal"; a push is stopped after 90 s; a push error stays through the 5 s poll and clears on the next other refresh (the tool reopened, another session, a tree report, or P).

### Git picker and reviewer diff, Direction B (owner, 2026-09-28, built)

Canvas: https://claude.ai/artifact/X1n5uqeNZyXEaVHk1PnaRD (boards B0 to B5, plus word highlights from Direction A).

- **The page (B1)**: the target pill reads as a path, "notchcode › seadevil ▾ W" (repository dim, worktree in ink), then the branch in mono, the status and Push. Unchanged otherwise: uncommitted files and recent commits on the left, the diff on the right, `⌘B` hides the list.
- **Picker as a page (owner's change 2)**: `W` replaces the content, `W` or `esc` returns, as before.
- **Repositories as a dropdown (owner's change 1, replaces B2's segments)**: at the top of the picker a pill "notchcode ▾ R" with the main folder dim after it and "8 branches" on the right. It opens an inline list of repositories drawn in the well under the pill (the inset style over the flattened well colour, never an NSMenu or a window): `↑↓` and `⏎` pick, `esc` or `R` close, a click outside closes. With one repository the pill is static.
- **Rows = local branches (B2)**: `for-each-ref --sort=-committerdate refs/heads`, the newest 30 plus every checked-out one, joined with `git worktree list --porcelain`. The branch in mono; under it "worktree seadevil" (with a small window glyph), "main checkout", or "not checked out" in tertiary; "session" and "current" tags; on the right "33 uncommitted" or "clean" for a checkout, "↑3" ahead of the upstream, "↑1 of main" ahead of the default branch (main, else master) when there is no upstream, "in main" for a branch with nothing of its own.
- **Filter (B3)**: past eight branches a filter field shows above the rows; `/` focuses it, typing narrows by name with the match lit, "3 of 10" and "7 branches hidden by the filter". `esc` goes one layer at a time: the dropdown, then the filter, then the picker, then the push confirm, then the card.
- **Not checked out (B5)**: picking such a branch opens a read-only page read from the main folder: the pill names the branch ("notchcode › design/toolbar"), status "not checked out · 1 commit ahead of main", the list "Changes vs main" (`git diff main...branch --numstat`, `--name-status`, `-p`; against the upstream when there is one), the commits `main..branch` below, the diff on the right. Push works (`git push -u origin branch`, or `git push origin branch`) with the same confirm. No checkout, ever.
- **Reviewer diff (B4)**: both line-number columns, blue hunk headers, a header that stays on top (the `⌘B` pill, name, an M/A/D badge, counts; the hunk counter and ⌥↑ ⌥↓ were removed on 2026-09-28 (owner: people scroll)). A 6 pt minimap pinned to the pane's right edge draws the whole file (its length counted from the file on disk, or `git cat-file` for a branch page), green where lines were added, red where removed, with a ringed box over the rows on screen; a click or drag jumps there.
- **Sideways scroll (owner's change 3)**: the Git diff scrolls both ways like the Files preview; lines never wrap and are never clipped. The minimap and the header do not scroll with the lines.
- **Word highlights (from Direction A)**: inside each hunk a run of removed lines followed by a run of added lines is paired line by line; each pair is split into whitespace-separated words, and the words outside their longest common subsequence get a stronger tint (34 % against the line's 10 %). Unpaired lines, pairs with no word in common, and pairs over 200 words keep the line tint only.

## Sessions the list must not show, and edits it cannot see (2026-09-28)

- **Helper runs.** Claude Code starts short runs of its own in a session's folder (naming a branch when a worktree is made, summarising). They write a transcript beside the real one, fire the same hooks, and ended up as a second "seadevil" row: Done, no files. Their lines carry `entrypoint: "sdk-cli"` (the owner's carry `"cli"`); the watcher marks such transcripts headless and the app drops any row with that id. Decided and built 2026-09-28.
- **Edits made through Bash show in Changes.** Changes reads `Edit`, `Write` and `MultiEdit` tool calls from the transcripts, but a session in bypass-permissions mode edits with `sed`, heredocs and scripts, so its turns said "no file changes" although the tree changed. Decided 2026-09-28 and built: the `PostToolUse` hook also matches `Bash`. On a Bash call, and on `UserPromptSubmit` (the turn's baseline), the hook script runs read-only git in the session's cwd (`GIT_OPTIONAL_LOCKS=0`): `git status --porcelain=v1 --untracked-files=all`, `git diff HEAD`, and each untracked file (first 20) diffed against `/dev/null`, capped at 256 KB. Both texts go base64 in the envelope's `tree` object (root, HEAD sha, status, diff, truncated). Outside a git work tree, or without git, nothing is added. About 0.2 s on this repo. The app keeps one baseline per session: the prompt's report replaces it; each Bash report is compared file by file (status code, ± counts, a hash of the diff body), and every file that is new, changed, or back to HEAD is attributed to the session's current turn, then the report becomes the baseline. A file already dirty at the prompt counts only when its diff changes; staging alone does not count; after a commit (HEAD moved) files that left the list are not counted. Attributed files are FileChanges of kind "shell" whose diff is the file's whole diff against HEAD (not just that command's part), listed after the turn's transcript files (the transcript wins on the same path), with a small "shell" tag after the name. They count toward the done peek. No peek of their own. With no baseline (the app started mid-turn) the first Bash report only becomes the baseline. The baseline is dropped on SessionEnd. The app itself still never runs a command; the hook does. Two sessions sharing one worktree can see each other's edits as their own; accepted.

## Sessions and worktrees

A session is a worktree plus a branch. Named by the worktree folder (`ponyfish`), with the repo and branch underneath. Collapsed, the wings show the most urgent state and one dot per session. The sessions card lists them: state, verb, elapsed. `⏎` on a row teleports. Each session also shows its permission mode, read from the last `permissionMode` in its transcript (the hook's `permission_mode` as a fallback): a tag on its Sessions row and one more part of the open card's status line, `bypass` in clay, `plan` in blue, `accept edits` / `auto` / `don't ask` tertiary, nothing for default; the collapsed wings stay as they are.

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

Superseded by "Distribution and first run" below (2026-09-28): one primary path, the app's Connect.

Three ways in, shortest first: the Claude Code plugin (`plugin/`, one `claude plugin install`), the Settings → Connect button, or `node scripts/connect.mjs`. Two pieces either way.

- The app: a signed, notarised `.app` from GitHub Releases, also as a Homebrew cask.
- Usage limits: Connect (Settings or `connect.mjs`) also makes `hooks/notchcode-statusline.sh` the `statusLine`. It forwards the status line JSON as kind `statusline` (at most every 5 s per session) and runs the previous status line, saved in `~/Library/Application Support/notchcode/statusline-chain.json` as `{"previous": …}`, with the same stdin. Disconnect restores it. Plugins cannot set `statusLine`, so plugin users also run Connect for limits.
- The hooks: a Claude Code plugin (`hooks/hooks.json`) installed with `claude plugin install notchcode@<marketplace>`. Plugin hooks merge alongside the owner's existing hooks; nothing in `settings.json` is overwritten. A `SessionStart` hook launches the app if it is not running.

## Distribution and first run (proposed 2026-09-28, owner to decide)

The question: how does a user open notchcode, and do they ever type a terminal command? Once, at most. After install the app opens itself. Mockup of every board below: https://claude.ai/artifact/V2HFkMgJTpagrsjzd36v9n.

**How the app gets opened.** Three layers; a user never launches it by hand.

1. Open at login. A switch in Settings (Opening group), on by default, `SMAppService.mainApp.register()`. No Dock icon, no menu bar item, so at login it is a black notch until a session exists.
2. Woken by Claude Code. The `SessionStart` hook group gets a second command, `pgrep -xq notchcode || open -g -b com.evch.notchcode`. The plugin has it already (`LAUNCH_APP` in settings.mjs); Connect adds the same line to settings.json. Launch Services knows the bundle id once the app has been opened once from /Applications.
3. By hand: Spotlight, or `⌥ space` while it runs. The Quit row says "opens again at login, or with your next Claude Code session".

**First run.** Not connected → the card opens by itself on a Welcome page: "Connect to Claude Code" (`⏎`, white), "Open at login" (on), one caption saying what Connect touches and that Disconnect puts it back, `esc` for later. One press does hooks, status line and login item together; the page turns into "Connected · start a Claude Code session" and closes. Seen once; Settings keeps the same controls. On a display without a notch nothing draws today; v0.1 says so in the README, the floating pill stays "later".

**Stable hook paths.** Connect writes the path of the script inside the app bundle, so moving or rebuilding the app breaks every hook without a word, and `status()` still says Connected because it only looks for the marker. Fix: on every launch the app copies both scripts to `~/Library/Application Support/notchcode/bin/` (only when the bytes differ) and Connect points hooks and the status line there. Updates never break hooks. `status()` gains `.stale` (our entries point at a file that is not there, or not at the bin folder); Settings shows an amber "Reconnect".

**One way in.** The README presents one path: open the app, press Connect. `connect.mjs` moves to Development. The plugin stays in the repo for the marketplace later; it cannot set the status line and cannot install the app, so it is never the first step.

**Getting the app.**

- v0.1.0 on GitHub Releases as `notchcode.zip`, built by `scripts/release.sh`: xcodegen, Release config, `codesign` with a Developer ID, `notarytool submit --wait`, `stapler`. Needs an Apple Developer account ($99 a year). Without it, macOS 15 shows "Apple could not verify" and the user goes to Privacy & Security → Open Anyway; the README keeps "build it once" until then.
- Homebrew cask in a personal tap once a release exists; `brew upgrade` is the update path. No Sparkle in v0.1. An About group in Settings shows the version with a pill that opens the Releases page.
- The repo stays private for now, so the Release and the tap wait for it to go public.

**Build order, when the owner says go.**

1. Login item switch; the launch line in Connect's SessionStart group. Small.
2. Scripts copied to Application Support, `.stale`, Reconnect.
3. Welcome page, opened by itself while not connected.
4. `scripts/release.sh`, signing, notarisation, the first Release.
5. The cask.

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

Implement now: hover rim light on the closed and resting notch for click-to-open owners (hover-to-open owners get the card on the same dwell, so no rim). Rebuilt 2026-09-28 to the canvas board M7: a static 2 pt line along the bottom edge and both bottom corners only, just outside the black, fading out where each corner turns up (no sides, no top, so it no longer reads as an outline); the camera hides its centre, the wings carry it; attention arrival with the clay bleed (the breath was dropped 2026-09-27 evening: on top of the height spring it read as a bounce); tab slide with parallax; done peek with the check drawing on and counts counting up; the simple teleport fold (card folds into the notch over 0.28 s, terminal activated at 0.15 s, no scale, no blur). No blur anywhere: content fades and rises 10 pt. The rest of the table below is later, or never.

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
| Hover rim (click-to-open owners; 2026-09-28) | static 2 pt line at 50% white on the bottom edge and bottom corners, outside the black, fading up each corner; 0.18 s ease-out in, 0.25 s ease-in out; glow 4 pt wide, 2 pt drop, 6 pt blur (12 px CSS) at 12% | after 250 ms at rest | yes | same, no glow |
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
