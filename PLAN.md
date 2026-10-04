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
- Every button carries a keycap hint (in the open card's strip, a segment whose keycap does not fit leaves it to the footer: the middle action, and a plan's Revise). `⌥ space` focuses the notch from anywhere, `⏎` primary, `⌫` deny, `A` always, `1–4` options, `esc` closes.
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
| Commit proposed | blocking | `PreToolUse` on `Bash(git commit *)`, only a plain `git commit` (2026-09-28: Commit allows the whole command, so anything chained onto it goes to the permission card) | message, files, ±counts; each file row opens its diff in place | Commit (allow), Edit, Skip (deny) |
| Plan ready | blocking | `PermissionRequest` on `ExitPlanMode` | the plan as Markdown, its first heading as the title, scrolling in the well; the attention row reads "Plan ready · <heading>" | Approve (allow), Auto-accept (allow + `setMode acceptEdits` for the session), Revise (deny: Claude keeps planning and asks what to change) |
| Question | preview only | `Notification` + transcript | the question and its options | Answer in terminal (teleport). No hook can answer a question from outside. |
| Edit landed | silent | `PostToolUse` on Edit/Write | no peek by default (a setting turns per-file peeks on). Updates the verb and the Changes tab | — |
| Shell command changed files | silent | `PostToolUse` on Bash (baseline from `UserPromptSubmit`) | no peek. Updates the Changes tool: the files show under the turn, tagged "shell", diff against HEAD | — |
| Turn finished | passive | `Stop`, `Notification` idle_prompt | peek: Done · session · files and ± totals of the turn. Click opens Changes | Open in terminal |
| Subagent finished | passive | `SubagentStop` | peek: ■ type finished · session | — |
| Session start / end | silent | `SessionStart`, `SessionEnd` | updates the session list | — |

Permission timeout: 58 s (the socket enforces it and the card counts down to the same moment; the hook itself waits 59 s), then the hook returns nothing and Claude Code's own terminal prompt continues. Nothing is denied on the owner's behalf. A plan waits 298 s (the hook 299 s, the hook entry's `timeout` 305 s): reading a plan takes longer than reading a command. One PermissionRequest entry covers both; the hook script picks its wait from the payload's tool name.

Commit here means letting Claude's own `git commit` through. The Git tool's own writes (commit, push, pull, fetch, undo) are listed under Git tool.

## Subagents

`SubagentStart` / `SubagentStop` hooks plus the transcript (Agent tool calls) give one `Agent` per subagent. Running agents show as a count in the wings and as lanes under their session in the Sessions tab; finished ones collapse into "3 done".

## Preferences

A Settings page inside the card (gear, or ⌘, while the card is open). Never a separate macOS window: one surface, one set of keys. Idle style (agents in the notch, or pure notch), attention style (two-row, or wings only), peeks on/off and their length, open on click or hover, the ⌥ space hotkey, agents in the wings, and an optional macOS notification for blocking events. Stored as one JSON blob in UserDefaults. Settings also holds Connect / Disconnect.

- Keys group (owner, 2026-09-28): a switch, on by default, hides the keycaps beside buttons inside the card because they crowd it; the footer keys and the attention row keep theirs; shortcuts work either way. ⌥ space moved into this group.
- Usage group (2026-10-01): a switch, on by default, lets the app run `claude -p /usage` every 15 minutes for the Fable week and the limits breakdown (see Usage tab layout).

**Rule exception, decided 2026-09-27:** the app may edit `~/.claude/settings.json`, and only that file, and only to add or remove its own hook entries, after a backup. Everything else stays hook-only.

## Data: session files first, hooks on top

Like sidecar-pane, the app reads `~/.claude/projects/<cwd>/<session>.jsonl` directly and polls for changes every 2 s. That alone gives sessions, prompts, files, full diffs (`structuredPatch`), tokens, and estimated cost, with no setup and for sessions that started before the app. Hooks add what the files never record: the live permission and commit decisions, and precise start/stop timing. When both know a session, hooks win on state.

## Git tool (owner, 2026-09-28)

The goal in the owner's words: vibe coders keep pressing approve on the notch instead of switching to the terminal or GitHub Desktop. So the notch shows what is uncommitted and lets them push. Extended 2026-09-30 (owner): the page is a small GitHub Desktop. It commits the checked files with a summary and description, pulls fast-forward only, fetches quietly, and undoes the newest unpushed commit. Still out, decided 2026-09-30: adding or cloning repositories (the tool follows Claude Code's sessions; a repository with no session has no terminal to land in), creating or switching branches, merge and rebase, stash, discard, and pull requests. Discard and stash are the next candidates if the owner wants them.

- **A fifth tool, Git (`4`)**, before Usage, which moves to `5` (owner, 2026-09-28: Usage is read least, so it sits on the far right), symbol `arrow.triangle.branch`. Header: branch, then "not published yet", "up to date with origin" or "2 behind" (the count moved into the pill on 2026-09-28: it reads "Push 3" or "Publish 4"); a white primary pill Push (or Publish when the branch has no upstream) with keycap `P`; `⏎` opens the selected file's diff. Below the header: the uncommitted files of the focused session's worktree as rows like Changes (name, cells, counts, diff under the row on `⏎`), then "Recent commits", the last five, each marked when not yet pushed (Recent commits removed 2026-09-30 by Direction F below). Empty state: "Nothing to commit · up to date".
- **Commit from the card (owner, 2026-09-30, built; reshaped by Direction F below)**: every uncommitted file has a checkbox, all on by default (new files too); the "Uncommitted · 4" header (or "Uncommitted · 3 of 4") has a tri-state box that puts every file in or takes every one out (a dash when some are in) and the checked files' totals ("+38 −6"; the Commit pill that sat here became the dock, Direction F). `space` toggles the cursor's file; a click on a box toggles without moving the cursor; an unchecked file's name and cells dim. `C` or a click on the dock's summary field opens the form in the stage in place of the diff, the field travelling there, under a header "Commit to main": the summary (its length shows past 50 characters, red past 72; with one file checked its prompt is GitHub Desktop's prefill "Create x", "Delete x" or "Update x", used when the summary is left empty), the description filling the pane, the co-authors when shown, git's error in red when the commit failed, then "Commit 3 ⏎" (the header names the branch; the footer carries "⏎ commit" or "⌘⏎ commit"), "@ Co-author", and Cancel (esc). `⏎` in the summary or `⌘⏎` anywhere commits; while a field has the keys only esc and ⌘⏎ stay with the card. Esc backs out (after the picker layers, before a confirm); a click on a file shows its diff; the draft (text and checks) is kept per target until committed or the card closes. The command: `git add -- <paths>` (stages new files and deletions), then `git commit --only --quiet -m <summary> [-m <description>] [-m <Co-authored-by trailers>] -- <paths>`, 60 s timeout for hooks, then `git log -1 --format=%h%x1f%s` for the dock's receipt. `--only` commits exactly those paths' working-tree state and leaves the index of unchecked files as it was, never reset (GitHub Desktop resets the index; this does not). "Committed 3 files" shows in the header's status for 3 s. Errors stay in the form: "No git identity · set user.name and user.email in the terminal", "A commit hook said no · <its line>", else git's first line. The commit gate for Claude's own commits is unchanged.
- **Data**: git read commands in the focused worktree while the tool is open and once when the card opens: status, diff HEAD (and no-index diffs for new files), ahead/behind against the upstream, log -1 (the newest commit, for undo and the receipt), and the Co-authored-by trailers of the last 100 commits (the co-author suggestions). The hook's tree report refreshes it too.
- **Sync pill (2026-09-30, built)**: the header's pill offers one thing, first match wins, GitHub Desktop's order: nothing (disabled "Push") without a branch or a remote; "Publish N" without an upstream; "Pull N" when behind (a checkout only; a branch page never pulls); "Push N" when ahead; else a dark "Fetch". `P` for all four. Pull asks first ("Pull 2 commits from origin/main?", "⏎ or Pull again") and runs `git pull --ff-only --no-rebase -- <remote> <upstream branch>` (90 s): fast-forward only, because a merge or rebase from a notch has no way to resolve a conflict; a diverged branch says "Pull needs a merge · pull from the terminal", local edits in the way "Uncommitted changes in the way · pull from the terminal". Fetch runs at once, `git fetch --prune -- <remote>`; "Fetched · up to date" holds when nothing came, else the fresh counts speak. The tool also fetches quietly when it opens or a branch is picked, at most every 5 minutes per repository (30 s timeout), without touching the pill; failures are only logged. All writes share one phase per target, so two never run at once; the pill pulses "Pushing", "Pulling", "Fetching", "Committing" or "Undoing" and shows a check with "Pushed", "Pulled" or "Fetched" while the result holds.
- **Undo (2026-09-30, built; moved to the dock by Direction F)**: the newest commit, when it is not on the remote and has a parent, can be undone with `U`, and after a commit from the card with the Undo pill in the dock's receipt; no confirm, since a mixed reset loses nothing. It works during the commit's own 3 s result too (the reset acts on the real HEAD, the commit just made), not while composing (the refill would replace the draft). It reads the message (`git log -1 --format=%B`), runs `git reset --quiet HEAD~1`, and, as GitHub Desktop does, the changes come back to the rail and the message refills the form (summary, description, and the Co-authored-by lines as co-author chips) with every file checked. "Undid "…"" shows in the status.
- **Push**: `git push -- <remote> refs/heads/<b>:refs/heads/<upstream branch>`, or `git push -u -- <remote> refs/heads/<b>:refs/heads/<b>` when there is no upstream (full refs, decided 2026-09-28: a plain `git push` follows push.default and pushRemote and can go elsewhere; a bare name is ambiguous with a tag; the confirm names exactly that remote and branch), only on an explicit press, with a confirm first, asked in the right pane in place of the diff or the clean note (owner, 2026-09-28): the question, "⏎ or Push again" and Cancel (esc); the header's Push pill stays put under the pointer, pops once and shows ⏎, and a second press pushes. While git pushes the header pill pulses and the card says "Pushing to origin/…"; the result shows inline in the header ("Pushed 3 commits", or git's error text). Credentials are whatever the keychain or the macOS ssh-agent gives a GUI app; when that fails, the error says so and the terminal is the fallback.
- **Rule exception, proposed 2026-09-28, widened 2026-09-30, owner to confirm**: the app may run `git`, and only `git`: read-only commands for the page, and on an explicit press push, pull (fast-forward only), fetch, commit of the checked files, and a mixed reset of the newest unpushed commit; the quiet fetch runs without a press. This is the second exception after settings.json. CLAUDE.md's rule sentence still says the app acts only through hooks; the owner should decide whether to reword it. "Push never happens from the notch" in Events is withdrawn. Everything else stays hook-only.
- **Two panes like Files (owner, 2026-09-28, built; now the rail and the stage of Direction F)**: under the header, which stays across the whole well, the Files split: on the left (`fileTreeShare`) "Uncommitted", one row per file (name, the five ± cells, the counts), then "Recent commits"; on the right the selected file's diff filling the pane, under a Files-style header (the `⌘B` pill, name, counts). A click or `↑↓` selects and shows the diff at once, the first file by default, as GitHub Desktop does; `⏎` only confirms a push. `⌘B` hides the list with the same preference as the Files tree. This replaces the rows that opened their diff underneath.
- **Worktree picker (owner, 2026-09-28, built; superseded by the branch picker below)**: a pill at the header's far left, "notchcode · seadevil ▾" with `W`, replaces the content with every repository a session runs in and all its worktrees (`git worktree list --porcelain`, read-only), each with its branch, "N uncommitted" or "clean", and a "session" tag; `⏎` makes that worktree the tool's target for status, diff, commits and push until the card closes (it follows the focused session until then, and says "not the focused session" when they differ); `esc` leaves the picker before the push confirm and before the card. No branch checkout.
- **Five tools fit (2026-09-28)**: the card and attention row are max(640, notch + 2 × max(tools wing, status wing)); the tools wing keeps 3 pt free on the camera side for the first tool's focus ring, the status wing is at least 204 pt. The collapsed resting and wings shapes widen so the five 20 pt hover tools fit whole.
- **Built 2026-09-28, small calls made while building**: the diff uses the hook's exact flags (`--no-renames`, `a/` `b/` prefixes) so one parser reads both; an unpublished branch tags as "not pushed" the commits on no remote (`rev-list --count HEAD --not --remotes`, one extra read); git runs with `GIT_TERMINAL_PROMPT=0` and stdin closed, so a credential prompt fails at once with "No credentials for origin here · push from the terminal"; a push is stopped after 90 s (SIGTERM, then SIGKILL 2 s later); a push error stays through the 5 s poll and clears on the next other refresh (the tool reopened, another session, a tree report, or P).

### Direction F · Dock and Stage (owner, 2026-09-30, built)

Canvas boards D0–D5, E0–E5 and F0–F2: https://claude.ai/artifact/X1n5uqeNZyXEaVHk1PnaRD. Direction E's rail and stage, with Direction D's docked summary field at the foot of the rail instead of a Commit pill in the rail header; the field itself travels into the stage to become the form; the receipt with Undo lives in the dock until the commit is pushed; and co-authors, GitHub Desktop's feature.

- **Three fixed regions**: header, rail, stage. Nothing appears from nowhere; the thing pressed travels to where the next step is. The header's status line is the one place results land ("Committed 3 files", "Undid "…"", "Pushed 3 commits", git's error in red), each for `gitResultHold` (3 s) or, for an error, until a refresh.
- **Rail** (`fileTreeShare` of the width): a 20 pt header, "☑ Uncommitted · 4" (or "3 of 4", its count rolling), then the checked files' totals "+38 −6"; a branch page reads "Changes vs main · 6" with no box and no totals. Rows of 20 pt, 2 pt apart: checkbox, name, cells, counts; the cursor's fill is one shape that glides between rows. **No Recent commits**: the sync pill's count is the unpushed count ("Push 3"), and Undo lives in the dock's receipt and on `U` while the newest commit is unpushed. The snapshot still reads the newest commit (`gitRecentCommits` = 1) for undo and the receipt.
- **The dock** (checkouts only), pinned to the rail's foot under the scrolling rows, full rail width, 26 pt, `filterFill`, three looks: the **field** (a pen, the draft's summary or its prompt, `C`; the whole box is a button that opens the form; disabled with "Nothing to commit" when there are no files), **nothing** while composing (the field has gone to the stage; the slot keeps its height so the rail does not reflow, and shows no outline: owner, 2026-09-30 evening), and the **receipt** after a card commit (`quietFill`, a green check, "Committed · <subject>", an Undo pill with `U`), shown while that commit is the newest and unpushed; it gives way to the field when the commit is pushed, another commit lands, or `C` opens a fresh form. It lives in the draft, so closing the card drops it (`U` still works).
- **The travel**: one `matchedGeometryEffect` pair, the dock's box in the rail and the form's summary box at the top of the stage, same fill, radius and height, so the box glides up and right and stretches as one box (it never fades; only its text fades in where it lands), drawn over the rail, and the summary takes the keys on arrival. The dock's slot stays empty while the box is away. The diff and the stage header drop out before the new ones rise, and the form's parts wait for the box to land: the description at 180 ms, the co-author row at 220 ms, the bottom row at 260 ms; esc drops them at once. Esc reverses with the text kept. A commit sends the box back, where it lands as the receipt (its check pops); the committed rows fold away top down, 40 ms apart; the sync pill's count pops. Undo (`U` or the receipt's pill) sends the receipt back up as the refilled form, and the rows unfold bottom up. The form's bottom row does not travel: "Commit 3 ⏎" (pulsing "Committing" while git runs, the fields at 60 %), "@ Co-author", Cancel.
- **The sync pill stays in the header** (owner, 2026-09-30 evening: one place to press; the travel into the stage was tried the same day and dropped). P arms it where it is: it pops once and its keycap crossfades P → ⏎ ("Push 3 ⏎"); the stage takes the confirm in place of the diff: the question centred at 40 % of the stage's height, "⏎ or Push again" (or Pull, Publish) under it, Cancel (esc) under that. ⏎ or the pill runs it and the pill pulses; the stage says "Pushing to origin/…" and then the diff comes back. A failed sync shakes the pill once (±3 pt, 2 × 60 ms). Fetch runs at once, no confirm.
- **Folded rail (⌘B)**: instead of hiding, the rail folds to 22 pt, its checkbox column: names, cells, totals and the dock fade (0.08 s), the width springs, the boxes stay put, the stage widens. Space and ↑↓ still work folded (the stage header names the file); `C` unfolds it first, since the dock lives there. Same preference as the Files tree.
- **Stage**: a 20 pt header (the ⌘B pill, then the file with its M/A/D badge and counts, "Commit to" and the branch while composing, nothing for a confirm) over the diff, the form, the confirm or the clean note, trading places with a 6 pt drop and a 10 pt rise, never a slide.
- **Checkboxes**: the check draws itself as a 90 ms stroke; unticking shrinks the fill to 60 % as it fades in 80 ms; the name and cells dim in 120 ms. The header's box ticks every row 20 ms apart, top down, capped at 8.
- **Co-authors**: the "@ Co-author" pill in the form's bottom row (no key; ⇥ reaches it) shows a field between the description and the bottom row: "@", the added co-authors as mono chips with ×, a field "Co-author · name <email>", "⏎ adds"; under it "recent" and up to six suggestions, the first ringed. ⏎ with text adds it, ⏎ with nothing typed adds the ringed suggestion, a click adds any, ⌫ in the empty field removes the last chip. Accepted: "Name <email>", "<email>" or a bare email; normalised to "Name <email>", the email's local part standing in for a missing name; anything else shakes the field and stays typed. With co-authors the pill reads "@ 2". Suggestions come from `git log -100 --format=%(trailers:key=Co-authored-by,valueonly,separator=%x1f)`, newest first, each once (case-insensitive), at most 12, filtered by what is typed (name or email) minus the ones added. The commit gets one more `-m` paragraph, "Co-authored-by: Name <email>" per line, which git reads as trailers. Undo turns those lines back into chips. The co-authors stay with the draft (per target, until committed or the card closes).
- **Keys**: a row click or ↑↓ while a confirm is up cancels it and shows the diff; `C` while a confirm is up cancels it and opens the form; `W` cancels it too; `P` while composing with no field focused closes the form (draft kept) and arms the sync; `U` does nothing while composing. Footer: idle "↑↓ file · space include · C commit · U undo (when allowed) · W branch · ⌘B rail · P push · ⇥ next tool" (⇥ only while at most five hints), composing "⏎ commit · ⌘⏎ commit · ⇥ description" (the description: "⌘⏎ commit · ⇥ next field"; the co-author field: "⏎ add · ⌫ remove · ⌘⏎ commit"), confirm "⏎ push" with "esc cancel".

### Git picker and reviewer diff, Direction B (owner, 2026-09-28, built)

Canvas: https://claude.ai/artifact/X1n5uqeNZyXEaVHk1PnaRD (boards B0 to B5, plus word highlights from Direction A).

- **The page (B1)**: the target pill reads as a path, "notchcode › seadevil ▾ W" (repository dim, worktree in ink), then the branch in mono, the status and Push. Unchanged otherwise: uncommitted files and recent commits on the left, the diff on the right, `⌘B` hides the list.
- **Picker as a page (owner's change 2)**: `W` replaces the content, `W` or `esc` returns, as before.
- **Repositories as a dropdown (owner's change 1, replaces B2's segments)**: at the top of the picker a pill "notchcode ▾ R" with the main folder dim after it and "8 branches" on the right. It opens an inline list of repositories drawn in the well under the pill (the inset style over the flattened well colour, never an NSMenu or a window): `↑↓` and `⏎` pick, `esc` or `R` close, a click outside closes. With one repository the pill is static.
- **Rows = local branches (B2)**: `for-each-ref --sort=-committerdate refs/heads`, the newest 30 plus every checked-out one, joined with `git worktree list --porcelain`. The branch in mono; under it "worktree seadevil" (with a small window glyph), "main checkout", or "not checked out" in tertiary; "session" and "current" tags; on the right "33 uncommitted" or "clean" for a checkout, "↑3" ahead of the upstream, "↑1 of main" ahead of the default branch (main, else master) when there is no upstream, "in main" for a branch with nothing of its own.
- **Filter (B3)**: past eight branches a filter field shows above the rows; `/` focuses it, typing narrows by name with the match lit, "3 of 10" and "7 branches hidden by the filter". `esc` goes one layer at a time: the dropdown, then the filter, then the picker, then the push confirm, then the card.
- **Not checked out (B5)**: picking such a branch opens a read-only page read from the main folder: the pill names the branch ("notchcode › design/toolbar"), status "not checked out · 1 commit ahead of main", the list "Changes vs main" (`git diff -p main...branch`, which gives the counts and kinds too; against the upstream when there is one), the commits `main..branch` below, the diff on the right. Push works (`git push -u -- origin refs/heads/b:refs/heads/b`, or `git push -- origin refs/heads/b:refs/heads/<upstream branch>`) with the same confirm. No checkout, ever.
- **Reviewer diff (B4)**: both line-number columns, blue hunk headers, a header that stays on top (the `⌘B` pill, name, an M/A/D badge, counts; the hunk counter and ⌥↑ ⌥↓ were removed on 2026-09-28 (owner: people scroll)). A 6 pt minimap pinned to the pane's right edge draws the whole file (its length counted from the file on disk, or `git cat-file` for a branch page), green where lines were added, red where removed, with a ringed box over the rows on screen; a click or drag jumps there.
- **Sideways scroll (owner's change 3)**: the Git diff scrolls both ways like the Files preview; lines never wrap and are never clipped. The minimap and the header do not scroll with the lines.
- **Word highlights (from Direction A)**: inside each hunk a run of removed lines followed by a run of added lines is paired line by line; each pair is split into whitespace-separated words, and the words outside their longest common subsequence get a stronger tint (34 % against the line's 10 %). Unpaired lines, pairs with no word in common, and pairs over 200 words keep the line tint only.
- **Fixed 2026-10-02 after a bug pass**: git runs with `GIT_LITERAL_PATHSPECS=1` so a checked path such as `app/[id]/page.tsx` cannot stage its glob matches; undo resets only while HEAD is still the commit the card showed, else "HEAD moved; refresh and try again"; push names the branch ref, not HEAD; the write phase is kept per target, so switching targets mid-write can neither start a second write nor lose the first one's result, and a confirm belongs to the target on screen; a staged rename (`R old -> new`) commits both paths and shows an R badge; snapshots are dropped when the card closes except the next target's, and with a forgotten session.

## Plan review (owner, 2026-10-04)

Picked from a brainstorm of developer tools that survive the move to a notch (the others: a checks verdict read from Claude's own test and build runs, task progress in the wing; a free-form command box was rejected because the notch has no terminal for the output). Plan mode is where the owner most needs to read before pressing, and the card showed "Allow ExitPlanMode?" with nothing to read.

- **Event**: the `PermissionRequest` hook already installed fires for `ExitPlanMode` when Claude finishes a plan. Verified with a scripted interactive session on Claude Code 2.1.287: `tool_input.plan` holds the plan's Markdown, `tool_input.planFilePath` the file Claude wrote under `~/.claude/plans/<slug>.md`; `permission_mode` is `plan`; there is no `tool_use_id` and no `permission_suggestions`. A headless `claude -p` session never offers `ExitPlanMode`, so the test had to drive the terminal UI.
- **A third request kind, plan**, beside permission and commit. Title: the plan's first heading (its `#` marks and a leading "Plan:" dropped), else "Plan ready". Body: the rest of the Markdown. When `plan` is empty the file at `planFilePath` is read (the demo reads no disk); when both are empty the card says the plan is in the terminal.
- **Attention row**: unchanged shape. Row 2 reads "Plan ready" and the heading, then the segments Revise · Auto-accept · Approve, the countdown draining along Approve. (Built 2026-10-04: "Keep planning" fit the attention row but not the open card's right wing, which has the camera on one side; "Revise" fits there once the open card drops that segment's `⌫` keycap, which the footer carries.)
- **Card**: the heading as the hero with the countdown ring, then the plan rendered by the Files tool's Markdown renderer in a snippet box that takes the room above the footer and scrolls (`↑↓` move it by blocks, each landing one margin below the box's edge; the wheel works too; "more below · scroll" or "end of plan" at the box's foot when it does not fit), then the request footer ("At 0:00 the terminal asks instead", "Open in <terminal>"). Height `planCardHeight`, the expanded request height. Past `planMaxLines` the body is cut with "… N more lines · open in the terminal". No diff, no `D`.
- **Answers**: `⏎` Approve sends a plain allow, so Claude Code leaves plan mode in the mode the session had before (manual approval for most sessions). `A` Auto-accept sends allow with `updatedPermissions: [{type: setMode, mode: acceptEdits, destination: session}]`, the hooks guide's own example; the reply carries the array explicitly instead of echoing `permission_suggestions`, which a plan does not have. `⌫` Revise ("Keep planning" in its tooltip) sends deny with "The owner read the plan in notchcode and wants changes. Ask them what to change, then plan again.", so Claude stays in plan mode and asks in the terminal. No text field in the card for now: the question Claude asks is where the owner types. `Ctrl+G` (edit the plan in an editor) stays a terminal thing; the teleport link is the way there.
- **Time**: a plan waits 298 s in the app, the hook 299 s, the hook entry's `timeout` 305 s (was 65). One PermissionRequest entry serves both deadlines: the script reads the tool name from the payload. A settings.json whose entry still says 65 reads as stale, so Reconnect fixes it; until then Claude Code cuts the hook at 65 s and the terminal asks, which is the same fallback as a timeout.
- **Demo and test events**: the demo script raises a plan after the Edit permission; `scripts/send-test-event.sh plan` sends one with the captured payload shape.
- **Not doing now**: a reason field for Revise (Claude asks instead); showing the plan file in Files; a peek when a plan is approved; choosing auto mode or bypass from the notch.

## Sessions the list must not show, and edits it cannot see (2026-09-28)

- **Helper runs.** Claude Code starts short runs of its own in a session's folder (naming a branch when a worktree is made, summarising). They write a transcript beside the real one, fire the same hooks, and ended up as a second "seadevil" row: Done, no files. Their lines carry `entrypoint: "sdk-cli"` (the owner's carry `"cli"`); the watcher marks such transcripts headless and the app drops any row with that id. Decided and built 2026-09-28.
- **Edits made through Bash show in Changes.** Changes reads `Edit`, `Write` and `MultiEdit` tool calls from the transcripts, but a session in bypass-permissions mode edits with `sed`, heredocs and scripts, so its turns said "no file changes" although the tree changed. Decided 2026-09-28 and built: the `PostToolUse` hook also matches `Bash`. On a Bash call, and on `UserPromptSubmit` (the turn's baseline), the hook script runs read-only git in the session's cwd (`GIT_OPTIONAL_LOCKS=0`): `git status --porcelain=v1 --untracked-files=all`, `git diff HEAD`, and each untracked file (first 20) diffed against `/dev/null`, capped at 256 KB. Both texts go base64 in the envelope's `tree` object (root, HEAD sha, status, diff, truncated). Outside a git work tree, or without git, nothing is added. About 0.2 s on this repo. The app keeps one baseline per session: the prompt's report replaces it; each Bash report is compared file by file (status code, ± counts, a hash of the diff body), and every file that is new, changed, or back to HEAD is attributed to the session's current turn, then the report becomes the baseline. A file already dirty at the prompt counts only when its diff changes; staging alone does not count; after a commit (HEAD moved) files that left the list are not counted. Attributed files are FileChanges of kind "shell" whose diff is the file's whole diff against HEAD (not just that command's part), listed after the turn's transcript files (the transcript wins on the same path), with a small "shell" tag after the name. They count toward the done peek. No peek of their own. With no baseline (the app started mid-turn) the first Bash report only becomes the baseline. The baseline is dropped on SessionEnd. The app itself still never runs a command; the hook does. Two sessions sharing one worktree can see each other's edits as their own; accepted. 2026-09-28, after background agents' Bash edits went missing: a `UserPromptSubmit` whose `source` is not "user" (a wakeup: task notification, loop, schedule; no `source` counts as a prompt) does not start a turn, so the turn's files, tallies and tree baseline carry on, matching the transcript reader, which does not count those lines as turns either; shell changes still held for want of a turn attach to the newest transcript turn on the next real prompt instead of being dropped; a Stop while agents still run keeps the session working with no done peek, and the last SubagentStop finishes the turn (done peek, tallies cleared).
- **Subagent edits land on their turn (2026-09-30).** Changes said "no file changes" on turns whose background agents had changed files. Checked against this repo's own transcript: the reader did find every agent (the Agent tool_use → agentId mapping, async launches included, and `visited` were fine). The cause was that those agents edited with `python3` heredocs and `sed` through Bash, so their transcripts hold no Edit or Write call to read; the hook's Bash path saw them, but its attributions lived only in memory and every relaunch of the app (each frame recording kills it) dropped them. Fixed on both paths: the shell changes are saved per session under `~/Library/Application Support/notchcode/shell-changes/<session>.json` (the app's own state; read back once per session, dropped after 7 days unused), and the hook's `agent_id` marks a subagent's Bash changes. In the reader, every subagent Edit / Write now goes to the turn whose window (its prompt until the next prompt) holds the edit's timestamp, not the turn that launched the agent, so an agent that outlives its turn or is continued by SendMessage in a later turn puts its edits where they happened; an agent is read once for the session; its tokens stay with the launching turn. A file only subagents touched carries the first agent's id (`FileChange.agentId`), and its chip shows that agent's colour square. Edits made while the app was not running at all still cannot be recovered.

## Sessions and worktrees

A session is a worktree plus a branch. Named by the worktree folder (`ponyfish`), with the repo and branch underneath. Collapsed, the wings show the most urgent state and one dot per session. The sessions card lists them: state, verb, elapsed. `⏎` on a row teleports. Each session also shows its permission mode, read from the last `permissionMode` in its transcript (the hook's `permission_mode` as a fallback): a tag on its Sessions row and one more part of the open card's status line, `bypass` in clay, `plan` in blue, `accept edits` / `auto` / `don't ask` tertiary, nothing for default; the collapsed wings stay as they are.

Teleport: the hook forwards `TERM_PROGRAM` and the session's process id. iTerm2 and Terminal.app can focus the exact window through AppleScript. VS Code and Cursor: `code --reuse-window <cwd>`. Ghostty: activate the app only, until it grows a scripting interface.

## Feasibility (checked against the Claude Code docs, 2026-09-27)

| Need | Status | Note |
|---|---|---|
| Allow / deny a permission from the app | yes | `PermissionRequest` hook, `hookSpecificOutput.decision.behavior` allow/deny. No output = terminal prompt continues. |
| Gate `git commit` | yes | `PreToolUse`, matcher Bash, `permissionDecision` allow/deny. |
| Approve or send back a plan from the app | yes | `PermissionRequest` fires for `ExitPlanMode` (captured on 2.1.287, 2026-10-04): `tool_input.plan` is the Markdown, `tool_input.planFilePath` the file under `~/.claude/plans/`; no `tool_use_id`, no `permission_suggestions`. Allow leaves plan mode in the mode from before; `updatedPermissions` `setMode` picks another; deny with a message keeps planning. |
| Answer a multiple-choice question from the app | no | No hook can answer `AskUserQuestion`. The card previews and teleports. |
| Know when Claude needs input or finished | yes | `Notification` types `permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`; `Stop`. |
| Session id and cwd in every hook | yes | every payload carries `session_id`, `cwd`, `transcript_path`. |
| Which terminal runs the session | partial | not in the payload; hooks inherit the environment, so the script forwards `TERM_PROGRAM` and friends. |
| Edit diffs | partial | the payload has the file path; the hook runs `git diff --numstat` for counts and grabs a snippet. |
| Context size and cost | yes | statusline JSON: `context_window`, `cost`. |
| 5-hour and weekly usage percent | yes, via the status line | Claude Code passes `rate_limits` to the `statusLine` command. Our script forwards it to the socket and chains the previous status line (Orca, sidecar) so nothing breaks. No keychain, no API calls. Per-model weekly windows (Fable) and the week breakdown come from Claude Code's own usage cache in `~/.claude.json`, refreshed by a headless `claude -p /usage` run (Settings → Usage). |
| Buttons over the notch | yes | a non-activating panel at status-bar level, positioned from `NSScreen.safeAreaInsets`; the same trick Boring Notch uses. Clicks land, focus stays in the terminal. |
| Long-running hook without blocking Claude | yes | hooks support `async: true`; the permission hook waits up to 60 s on a Unix socket. |

## Install

Superseded by "Distribution and first run" below (2026-09-28): one primary path, the app's Connect.

Three ways in, shortest first: the Claude Code plugin (`plugin/`, one `claude plugin install`), the Settings → Connect button, or `node scripts/connect.mjs`. Two pieces either way.

- The app: a signed, notarised `.app` from GitHub Releases, also as a Homebrew cask.
- Usage limits: Connect (Settings or `connect.mjs`) also makes `hooks/notchcode-statusline.sh` the `statusLine`. It forwards the status line JSON as kind `statusline` (at most every 5 s per session) and runs the previous status line, saved in `~/Library/Application Support/notchcode/statusline-chain.json` as `{"previous": …}`, with the same stdin. Disconnect restores it. Plugins cannot set `statusLine`, so plugin users also run Connect for limits. Connect points hooks and the status line at `~/Library/Application Support/notchcode/bin/`, copies the app refreshes at every launch, so moving or updating the app never breaks them; a settings.json that still names an old path shows Reconnect in Settings.
- The hooks: a Claude Code plugin (`hooks/hooks.json`) installed with `claude plugin install notchcode@<marketplace>`. Plugin hooks merge alongside the owner's existing hooks; nothing in `settings.json` is overwritten. A `SessionStart` hook launches the app if it is not running.

## Distribution and first run (proposed 2026-09-28, owner to decide)

The question: how does a user open notchcode, and do they ever type a terminal command? Once, at most. After install the app opens itself. Mockup of every board below: https://claude.ai/artifact/V2HFkMgJTpagrsjzd36v9n.

**How the app gets opened.** Three layers; a user never launches it by hand.

1. Open at login. A switch in Settings (Opening group), on by default, `SMAppService.mainApp.register()`. No Dock icon, no menu bar item, so at login it is a black notch until a session exists.
2. Woken by Claude Code. The `SessionStart` hook group gets a second command, `pgrep -xq notchcode || open -g -b com.evch.notchcode`. The plugin has it already (`LAUNCH_APP` in settings.mjs); Connect adds the same line to settings.json. Launch Services knows the bundle id once the app has been opened once from /Applications.
3. By hand: Spotlight, or `⌥ space` while it runs. The Quit row says "opens again at login, or with your next Claude Code session".

**First run.** Not connected → the card opens by itself on a Welcome page: "Connect to Claude Code" (`⏎`, white), "Open at login" (on), one caption saying what Connect touches and that Disconnect puts it back, `esc` for later. One press does hooks, status line and login item together; the page turns into "Connected · start a Claude Code session" and closes. Seen once; Settings keeps the same controls. On a display without a notch nothing draws today; v0.1 says so in the README, the floating pill stays "later".

**Stable hook paths.** Connect writes the path of the script inside the app bundle, so moving or rebuilding the app breaks every hook without a word, and `status()` still says Connected because it only looks for the marker. Built 2026-10-02: on every launch the app copies both scripts to `~/Library/Application Support/notchcode/bin/` (only when the bytes differ) and Connect points hooks and the status line there. Updates never break hooks. `status()` gains `.stale` (our entries point at a file that is not there, or not at the bin folder); Settings shows an amber "Reconnect".

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
- `Sources/notchcode/App`: the app entry, delegate, hotkey, keyboard routing, system notifications, debug log.
- `Sources/notchcode/Core`: `Contract.swift`, the one shared contract (wire types, sessions, pending requests, file changes, turns, usage) everything talks through; preferences, formatting, `HookText` (hook payload parsers), `GitDir` (branch and repo name from `.git`), `ISODate` (ISO 8601 parsing), and `Diff/` (unified diff parser and builder, word diff).
- `Sources/notchcode/ClaudeCode`: reads and writes Claude Code's own files: the transcript reader (turns, files, tokens from `~/.claude/projects/<cwd>/<session>.jsonl`), its agent builder (`TranscriptAgents`) and turn builder (`TranscriptTurns`), the transcript watcher, JSON lines, the hooks installer and its ordered JSON.
- `Sources/notchcode/Transport/SocketServer.swift`: Unix socket listener, one JSON line per event, replies for blocking events, deadline handling.
- `Sources/notchcode/State`: `AppState.swift`, the app's live state: one class file (stored state, core derived values, mode) plus per-concern extensions (`+HookEvents`, `+Requests`, `+Sessions`, `+Card`, `+Teleport`, `+Peek`); `NotchTypes.swift`, the shared small types.
- `Sources/notchcode/UI`: `Theme.swift` (every colour, radius, spring, glyph), shared components, keycaps, motion modifiers, glyphs, `Segments` (the segment look and the action segment), `Controls` (the small controls more than one tool uses) and `Diff/` (the diff box, code lines, minimap, file rows, the reviewer diff).
- `Sources/notchcode/Notch`: the window over the notch, the shape and its morph, and every surface drawn in it: root, wings, resting, peek, attention, card, strip.
- `Sources/notchcode/Features/Sessions`: the Sessions tab.
- `Sources/notchcode/Features/Changes`: the Changes tab, `ChangesModel`, `AppState+Changes`.
- `Sources/notchcode/Features/Files`: the Files tab, `FilesModel`, `AppState+Files`, the repo file tree, the Markdown view and parser.
- `Sources/notchcode/Features/Git`: the Git tab split into header, diff pane and branch picker; `GitModel`; `AppState+Git`, `+GitPicker`, `+GitDraft`, `+GitWrites`; `GitRunner` (runs git).
- `Sources/notchcode/Features/Usage`: the Usage tab, `UsageModel`, the calculator, `PlanUsage` (reader and runner), `AppState+Usage`, `+PlanUsage`.
- `Sources/notchcode/Features/Requests`: the permission, question and commit cards, and the request actions.
- `Sources/notchcode/Features/Settings`: the Settings page.
- `Sources/notchcode/Demo`: the `--demo` script and `AppState+Demo`.
- `hooks/notchcode-hook.sh`: the single hook script, called with the event kind as its argument. Prints nothing unless the app replied.
- `scripts/connect.mjs`, `scripts/disconnect.mjs`: add or remove only our hooks in `~/.claude/settings.json`, beside the owner's own hooks. `scripts/send-test-event.sh`: fires a fake event at the socket.

Layout reorganised 2026-09-28: feature folders under Features/, shared code in Core/, UI/, State/, ClaudeCode/. Same day: the monolith files split into one-concern files; Git and Files tool state moved off static vars onto AppState.
Second pass 2026-10-02: the Git state, the transcript reader and the diff view split into one-concern files; the controls more than one tool uses moved to UI/; each tool's state is one value on AppState (`gitStore`, `changesTool`, `filesTool`). The file rule: a feature's value types in `<Feature>Model.swift`, its AppState extension in `AppState+<Feature>.swift`, its root view in `<Feature>Tab.swift`.

Milestones:

1. **See it** (today): the shape over the notch, closed / wings / attention / peek / card, springs, a `--demo` flag that walks the states with sample data, the permission card with working Allow / Deny / Always buttons.
2. **Feel it**: the socket, the hook script, connect and disconnect; a real permission round-trip; Stop and Notification drive the wings.
3. **Use it**: transcript reader feeding Changes and Usage; Sessions with teleport; commit gate.
4. **Ship it**: plugin packaging, notarised build, Homebrew cask.

## Transport

Unix socket at `~/Library/Application Support/notchcode/notchcode.sock`. Hook scripts write one JSON line and, for blocking events, read one line back. Scripts are plain `sh`, print nothing, exit 0 when the app is absent. The reply handler reports whether the hook got the answer; a press that lands after the deadline shows "Too late: the terminal asks" instead of counting as answered (2026-10-02).

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

Implement now: hover rim light on the closed and resting notch for click-to-open owners (hover-to-open owners get the card on the same dwell, so no rim). Rebuilt 2026-09-28 evening to the Motion board M7 exactly, mirrored outward (owner: the M7 look, fading out on the sides): the shape shifted 2 pt down minus the shape, a 2 pt band at 50% white under the flat bottom edge that thins to nothing up each bottom corner, plus the board's `0 2px 12px` glow at 12% behind the black; a straight bar and a stroked outline were both tried and dropped the same day; attention arrival with the clay bleed (the breath was dropped 2026-09-27 evening: on top of the height spring it read as a bounce); tab slide with parallax; done peek with the check drawing on and counts counting up; the simple teleport fold (card folds into the notch over 0.28 s, terminal activated at 0.15 s, no scale, no blur). No blur anywhere: content fades and rises 10 pt. The rest of the table below is later, or never.

After Done: 4 s, then the Resting state (see States). Never a bare notch while a session exists, unless the owner chose pure notch.

Toolbar motion (owner, 2026-09-27 evening), all in Theme: tools unfold from behind the camera (offset 16 pt toward the centre + opacity, spring 0.28/1.0, 100 ms + 30 ms per tool); segment hover lift (fill 9%) and press depress (scale 0.94, 0.12 s); selection fill and focus ring glide with `matchedGeometryEffect` (spring 0.30/0.88); the bridge slides with the same spring; panel height re-target in one spring (0.40/0.94); pane re-anchor slide 48 pt + parallax 40%; Allow pops in (0.92 → 1.08 → 1) and its countdown bar drains from the deadline date in a `TimelineView`. Reduce Motion: crossfades, no offsets, no press scale, the bar steps once a second.

**Settled, no bounce (owner, 2026-09-27 late).** The toolbar build bounced more than `main`: the wider, taller card made the 0.72 width spring overshoot visibly, the breath played on attention, and opening often ran the re-target spring instead of the sequenced ones (mode and card height changed together, and the second change replaced the first animation). Now every shape spring is damped at 0.9 or more: width 0.42/0.9, height 0.48/0.9, close at 0.7× those responses (30% faster), re-target 0.40/0.94 and only when the target actually changed. Tool names: a caption pill under the strip, centred under the tool, after 150 ms at rest (it follows the mouse between tools at once), and for 1.2 s after `⇥` or `1–4`. On the collapsed strip there is no room below (outside the black) or beside the tools, so the left wing shows the name instead.

## Usage tab layout (2026-10-01)

One page, no scrolling, fixed heights; the card is 420 pt, so the pane is 350. Unknown values show "—" in the same place. Numbers are never invented. The layout never changes shape with data.

Row 1, limits (what the other rows leave, about 110 pt): one tile per window, sharing the width. 5-hour, Week, one per model week ("Fable week"), then Spend behind a gateway. Each tile: the title, the percent large, a bar, the reset. The bar is white, clay at 90% or more. A window whose reset time has passed dims its number and says "reset at …". Before any data the 5-hour and Week tiles say "connect the status line"; a model week says "from /usage". Spend says "$12.40 of $50" when the gateway sends the amounts.

Row 2, context (66 pt): "Context", the model's name, "effort high", "thinking", "fast", and "past 200k" in clay; "36% · 357k of 1M" on the right. An 8 pt bar filled to the percent, split by the last call's input side: cached, new to cache, fresh. Then the legend chips and "643k free".

Row 3, session (76 pt), three tiles. This session: its tokens, a four-part token bar, then the cost ("$1.42" from Claude Code, "~$1.42" estimated), the time and "+2351 −147". Today: its tokens, "~$12.40 · Fable 78%" (today's Fable share of tokens). This week: where the week went, "Claude Code 98%", then "Chats 2%".

Row 4, behaviours (44 pt): "Last 24h · 155 requests · 2 sessions" with the week's counts on the right, then the day's lines in fewer words ("94% from subagent-heavy sessions · 82% at >150k context · subagents general-purpose 34%, fork 5%").

Footer: "cost from Claude Code" (or "cost estimated from tokens"), "limits updated 3m ago", "plan usage 8m ago" (or refreshing, off in Settings, or why the run failed). Keys: `R` refresh, `⇥` next tool.

Sources. Claude Code's status line gives the 5-hour and week windows, the spend limit, context, the last call's tokens, cost, time, lines, the model, effort, thinking and fast mode. Claude Code's own usage cache in `~/.claude.json` (`cachedUsageUtilization`, written whenever it answers `/usage`) gives the per-model weeks and the week breakdown, and the 5-hour and week windows when it is newer than the status line. A headless `claude -p /usage --output-format json --setting-sources "" --resume <id>` refreshes that cache: about 300 ms, no tokens, no model turn, no hooks. It runs 5 s after launch, every 15 minutes, when the Usage pane shows and the cache is older than 5 minutes, and on `R`. Its text gives the behaviour lines. It runs in `~/Library/Application Support/notchcode/usage`, so its transcript lands in `~/.claude/projects/-Users-…-notchcode-usage/`; past 1 MB a new session id starts over. Its session is headless and never shows. Settings → Usage turns the runs off; the page then shows what the status line and the cache last said. The demo never runs it. The app still makes no API calls and reads no keychain.

Prices (Anthropic first-party, per million tokens, cached 2026-09-25), for the estimated costs only:

| Model | Input | Output | Cache read | Cache write |
|---|---|---|---|---|
| Fable, Mythos | 10 | 50 | 0.25 | 12.5 |
| Opus 5.5 | 4 | 20 | 0.20 | 5 |
| Other Opus | 5 | 25 | 0.50 | 6.25 |
| Sonnet, unknown | 2 | 10 | 0.20 | 2.5 |
| Haiku | 1 | 5 | 0.10 | 1.25 |

Changed-file rows (Changes, the commit card, the Files preview header): the file name only, in ink, middle-truncated when long, the full path on hover; the cells and counts always stay visible at the right (owner, 2026-09-28).

Changes tool, Direction G · Timeline (owner, 2026-09-30, built; chosen from the canvas boards G0–G4 at https://claude.ai/artifact/X1n5uqeNZyXEaVHk1PnaRD, spec `design-G-timeline.md`): the session as a timeline, newest first, so the eye lands on the work. Inside the well (576 × 334): a 26 pt header with the session's totals in caption ("18 turns · 14 files · +2351 −147 · 3h 27m": turns, distinct files, ± via `DiffCounts`, first start to last end or now; the session's, whatever the filter) and the "With edits /" pill on the right (neutral, white while on, "· 6 with edits" after the totals). Under it the body: the timeline column takes the full width, or 236 pt beside the diff pane (gap 10, hairline, gap 10, the pane). The spine is a 1 pt hairline at x 10 from the first node down; titles start at 26. A turn that changed files is an entry: an 8 pt ink node, the prompt in body semibold on two lines at most, cut with a 24 pt fade instead of an ellipsis, its clock time right-aligned on the first line (and its duration when the column is at least 300 pt wide; on hover when narrow), then its files as 20 pt chips wrapping in rows 4 pt apart (`ChipFlow`): filterFill, chip radius, 6 pt inside, [the subagent's colour square when a subagent made the change] the name (mono caption, middle-truncated, 120 pt at most), the five cells, the counts; hover and the selected chip (its diff showing) fill quietFill; the keyboard cursor is a 1 pt inkSecondary ring that glides from chip to chip. Entries are 12 pt apart. Every run of turns without files, in every run, folds into one 20 pt quiet-group row (three stacked ticks on the spine, "7 quiet turns", " · questions and decisions" when the column is wide, a chevron); ⏎ or a click unfolds one 20 pt row per turn (a 6 × 1 tick, the prompt in caption secondary with the fade, its time). The live turn (the newest, while the session works, waits on the owner or its agents run) is always first, even with no edits: a clay node with a 14 pt breathing halo, "Working 16:32" in clay, its chips so far or "no edits yet". One run, no date labels. ⏎ on a chip opens the Git tool's split: the column springs to 236, a hairline fades in, the pane rises (a 20 pt header: the ⌘B pill, the name, the M / A badge, the counts, "turn 3 · 2:32 PM"; then the shared `ReviewerDiff`, extracted from the Git stage, which now uses it too, with its minimap scaled to the file's length on disk when it exists). Keys: ↑↓ move through chips, group rows, unfolded quiet rows and the live turn, in reading order, and the open pane follows; ⏎ on a chip opens its diff, ⏎ again (pane open) or ⌥⏎ goes to the session's terminal (the app has no "open in editor"; the teleport is the one place it can take you); ⏎ on a group row folds or unfolds it; Y copies path:line of the cursor chip; `/` toggles With edits; ⌘B hides or shows the column while the pane is open; esc shows a hidden column, then closes the pane (the chip stays the cursor), then the card. The footer says what ⏎ does on the cursor's stop. The view choices reset when the focused session changes. The permission and commit cards keep the older file row and diff box (`FileDiffRow`).

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
| Hover rim (click-to-open owners; 2026-09-28) | M7 mirrored outward: a 2 pt crescent at 50% white under the flat bottom edge, thinning to nothing up each corner (shape shifted 2 pt down minus the shape); 0.18 s ease-out in, 0.25 s ease-in out; glow: the shape at 12%, dropped 2 pt, blurred 6 pt, behind the black | after 250 ms at rest | yes | same, no glow |
| Git branch picker (2026-09-28) | the target pill morphs into the repository pill in place (spring 0.32 s, damping 0.86); branch, status and Push slide 12 pt right and fade 0.08 s; panes drop 6 pt and fade; picker header rises 10 pt at 120 ms; rows rise 10 pt one by one, 40 ms apart, capped at 8; closing: rows fade 0.08 s, header slides back from the right, panes rise back | 0 | yes | crossfade 0.2 s |
| Git push confirm (2026-09-28; the pill stays in the header, owner 2026-09-30 evening) | the stage's diff or clean note drops 6 pt and fades 0.08 s; the question rises 10 pt at 120 ms; "⏎ or Push again" and Cancel rise at 180 ms; the header's sync pill stays put and pops once (0.92 → 1.08 → 1), its keycap crossfading P → ⏎; esc or the run drops the confirm and the content rises back | 0 | yes | crossfade 0.2 s |
| Git dock travel (Direction F, 2026-09-30) | C or a click: the dock's summary box travels from the rail's foot to the top of the stage (matched frame, spring 0.32/0.86), its content crossfading, the dock's slot left empty; the diff drops 6 pt and fades 0.08 s; the description rises 10 pt at 120 ms, the co-author and bottom rows at 160 ms. Esc: the reverse, text kept. Commit: the fields fade, the box travels back and lands as the receipt (its check pops); undo: the receipt travels up as the refilled form | 0 | yes | crossfade 0.2 s |
| Git rail rows (Direction F) | a committed row folds its 20 pt height to 0 and fades on the 0.32/0.86 spring, top down 40 ms apart, capped at 8, the rest closing up; after an undo rows unfold bottom up the same way; the cursor's fill glides between rows (matched frame, same spring) | stagger | yes | crossfade 0.2 s |
| Git checkbox (Direction F) | tick: the fill appears and the check draws as a 0.09 s ease-out stroke; untick: the fill scales to 0.6 and fades in 0.08 s; the name and cells dim in 0.12 s; the header's box ticks the rows 20 ms apart, capped at 8; counts roll (`.numericText()`) and pop | 0 / stagger | yes | crossfade 0.2 s |
| Git rail fold, ⌘B (Direction F) | names, cells, totals and the dock fade 0.08 s; the rail's width springs to 22 pt (0.32/0.86) with the boxes in place; the stage widens | 0 | yes | crossfade 0.2 s |
| Git shake (Direction F) | a failed sync's pill, or a refused co-author: ±3 pt horizontally, two half-cycles of 60 ms ease-in-out | 0 | no | none |
| Changes, a new turn (Direction G, 2026-09-30) | the new entry rises 10 pt from transparent at the top (0.2 s ease-out), the rest slide down on the 0.32/0.86 spring; the finished node crossfades clay → ink and "Working" → its time on the same spring | 0 | yes | crossfade 0.2 s |
| Changes, a chip lands | pops in from 0.92 and transparent on the 0.32/0.86 spring at the end of its row; the row makes room on the same spring | 0 | yes | crossfade 0.2 s |
| Changes cursor | the chip ring glides between chips (matched frame, 0.32/0.86); on a quiet row it becomes the row's fill (crossfade 0.12 s) | 0 | yes | crossfade 0.2 s |
| Changes diff pane | ⏎: the column springs from the full width to 236 pt (0.32/0.86), its text re-wrapping at once; the hairline fades in; the pane's header rises 10 pt at 120 ms, the diff at 160 ms; another chip crossfades the diff 0.2 s. Esc: the pane drops 6 pt and fades 0.08 s, the column springs back. ⌘B: the column springs to 0 and back | 0 | yes | crossfade 0.2 s |
| Changes quiet group | ⏎ or a click: the chevron turns 90° (0.2 s), the quiet rows rise 10 pt 40 ms apart (capped at 8), the entries below slide down; folding drops them 6 pt | 0 / stagger | yes | crossfade 0.2 s |
| Changes With edits | `/`: the pill turns white and pops (1 → 1.08 → 1); quiet groups drop 6 pt and fade 40 ms apart; entries close the gaps on the spring; "· 6 with edits" rises in after the totals; `/` again is the reverse | 0 / stagger | yes | crossfade 0.2 s |
| Changes live node | the 14 pt clay halo breathes out to 1.5× and fades from 25 % to 0 over 1.6 s ease-in-out, repeating | 0 | yes | a still halo |
| Changes chip hover | filterFill → quietFill, 0.12 s ease-out | 0 | yes | crossfade 0.2 s |
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
