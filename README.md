# notchcode

The MacBook notch as a companion for Claude Code.

notchcode is a small macOS app that draws over the notch. Closed, it is invisible: pure black, the same shape as the hardware. While Claude Code works, the shape grows sideways into two wings that say what is happening. When Claude needs you, it grows into a card you can answer with one key. Press the notch at any time and the card opens on the things a plain terminal never shows: your sessions across worktrees, the files each turn changed with their diffs, the repository tree, and your usage limits.

It is the sibling of [sidecar-pane](https://github.com/evch1204/sidecar-pane), which shows the same stream in a terminal split. They share a data contract, not code: both read Claude Code's own session files, and both use hooks only for the one thing those files never record, Claude asking for permission.

## What it does

**Traffic light.** From any app or space you can see whether Claude is working, blocked on you, or done, across every session on the machine.

**Doorbell.** When Claude asks to run a command, edit a file, or commit, the notch grows to two rows, names the request, and waits. `⏎` allows, `⌫` denies, `A` allows always. When the request is a code change, `D` opens the real diff inside the card, built from the exact text Claude wants to write, so you approve what you have read and not a pair of counts. If you answer in the terminal instead, the card notices and folds away. If you answer nowhere, the terminal prompt takes over after a minute. notchcode never denies anything on your behalf.

**Companion.** The open card has four tabs.

| Tab | Shows |
|---|---|
| Changes | each turn you sent, the files it changed, including edits made by subagents, and the full diff under any file. |
| Usage | the 5-hour and weekly limits with reset times, context used against the model's window, tokens for the session and today, and an estimated cost. One page, no scrolling. |
| Sessions | every live session by repository, one row per worktree: branch, model, permission mode (`bypass` in clay, `plan` in blue; nothing for default), state, current prompt, a lane per subagent. `⏎` opens its Changes. |
| Files | the repository tree, changed files badged, and a preview with changed lines tinted; `⌘B` folds the tree away for a full-width preview, and Markdown files render with a Preview · Code switch. |

**Teleport.** Every session knows which terminal started it. One key lands you in that window. With several worktrees of one repository open at once, this is the reason to keep the app.

## How it looks

The design lives on a canvas with every state, the three directions that were explored, and a page of looping motion studies:
[notchcode design](https://claude.ai/artifact/AChgFMt8kby2qukkVNxwrn).

One black shape, six sizes. Nothing is ever drawn over the centre of the notch, that is the camera; every state is a left wing, the camera gap, and a right wing, with the card below.

```
closed     ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
                  ┃                     ┃              the notch itself, pixel-identical

wings      ▁▁▁▁▁▁┓                       ┏▁▁▁▁▁▁▁▁▁
            ✻ notchcode · ponyfish       1 agent      Claude is working
                  ┗━━━━━━━━━━━━━━━━━━━━━━━┛

resting     ● notchcode · ponyfish     +1 session     nothing moving, still yours to open

attention   ▲ Needs you                     0:53 ◔
            Allow Bash?  npm test -- --watch=false    two rows, a countdown, one key answers

peek        ✓ Done · notchcode · ponyfish   3 files  +87 −12    four seconds, then resting

card        ┌ Sessions · Changes · Files · Usage ┐
            │ …                                  │    the companion, ⇥ between tabs, esc closes
            └────────────────────────────────────┘
```

Motion follows the Dynamic Island rules: width before height on open, height before width on close, springs with a little overshoot, content that waits 120 ms and rises in, no blur anywhere. Hover the closed or resting notch and a thin light runs along its bottom edge. Reduce Motion turns every spring into a crossfade.

## How it works

Three sources, in order of how much they need from you.

1. **Session files.** Claude Code writes every session to `~/.claude/projects/<folder>/<session>.jsonl`. notchcode polls that folder every two seconds and reads the head and tail of what changed. That alone gives sessions, prompts, files, full diffs, subagents, tokens, and an estimated cost, with no setup, for sessions that started before the app did.
2. **Hooks.** One shell script, called by Claude Code's hooks with the event name, sends one JSON line over a Unix socket in `~/Library/Application Support/notchcode/`. For a permission request or a `git commit` it waits for your answer and prints Claude Code's decision JSON. For everything else it fires and forgets. If the app is not running the script prints nothing and exits at once; Claude Code is unaffected.
3. **Status line.** Claude Code hands its status line command the 5-hour and weekly limits. notchcode's status line script forwards them to the app, then runs whatever status line you had before, so nothing you already use stops working.

The app never runs a shell command, never edits your project, and makes no network requests. The one file it writes outside its own folder is `~/.claude/settings.json`, only to add or remove its own hook entries, after a backup, and only when you press Connect.

## Requirements

- A MacBook with a notch (2021 or later) and macOS 14 or newer. On a display without a notch the app draws nothing yet.
- Claude Code.
- To build: Xcode, with the licence accepted once (`sudo xcodebuild -license accept`), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Install

Two pieces: the app, and the hooks that tell Claude Code to send it events.

Build and run the app:

```sh
scripts/dev.sh            # generate the project, build, launch
scripts/dev.sh --demo     # the same, walking every state with sample data
```

Then connect Claude Code in one of three ways, shortest first. Pick one; with two of them, every event reaches the app twice.

**a. The Claude Code plugin.** It adds the hooks without touching `~/.claude/settings.json`, and opens the app when a session starts. Once published:

```sh
claude plugin install notchcode@<marketplace>
```

Until then, load it for one session with `claude --plugin-dir ./plugin`. See [plugin/README.md](plugin/README.md).

**b. Settings → Connect inside the card** (the gear, or `⌘,` while the card is open). It adds notchcode's hooks to `~/.claude/settings.json` beside your own, pointing at the script inside the app, and chains the status line. Disconnect puts everything back.

**c. From the repository, with Node 20:**

```sh
node scripts/connect.mjs      # add the hooks and chain the status line
node scripts/disconnect.mjs   # remove only ours, restore the status line
```

Both take `--settings <path>` to work on another file and `--dry-run` to print what would change.

Ways b and c follow the same rules. They back the file up first as `settings.json.notchcode-backup-<time>`. They add or replace only entries whose command contains `notchcode-hook.sh`, never your other hooks. They keep the file's key order byte for byte, and are safe to run twice.

**Usage limits** reach the app only through the status line, so the plugin alone does not show them; b or c does. **Running sessions** keep their old hooks until you restart them.

### The hooks it installs

| Claude Code event | Matcher | Blocks Claude? |
|---|---|---|
| `PermissionRequest` | all tools | until you answer, or 58 s pass |
| `PreToolUse` | `Bash`, only `git commit …` | the same |
| `PostToolUse` | `Edit`, `Write`, `MultiEdit`, `Bash` | no |
| `Notification`, `Stop`, `UserPromptSubmit` | | no |
| `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop` | | no |
| `statusLine` | | no; chained in front of your existing one |

## Keys

While the card is open the notch takes the keyboard; the moment it closes, focus goes back to your terminal.

| Key | Does |
|---|---|
| `⌥ space` | open or close the card from anywhere |
| `⏎` | the primary action: allow, commit, open the selected session or file |
| `⌫` | deny, or skip a commit |
| `A` | allow always |
| `E` | edit a proposed commit: Claude asks you for a new message |
| `D` | show the diff behind a permission or commit request |
| `1` – `4` | pick a tool |
| `⇥` `⇧⇥` | next and previous tool |
| `↑` `↓` `←` `→` | move in a list or the file tree |
| `y` | copy `path:line` of the first changed line |
| `/` | filter the Files tree |
| `⌥⏎` | jump to the session's terminal |
| `⌘,` | Settings |
| `⌘Q` | quit notchcode (while the card is open) |
| `esc` | back, or close |

## Settings

A page inside the card, never a separate window. What shows when idle (the resting row, or a pure notch), how "needs you" looks (two rows, or wings only), whether finished turns and agents peek and for how long, whether every file edit peeks too, click or hover to open, the `⌥ space` hotkey, agents in the wings, an optional macOS notification for blocking requests, and Connect / Disconnect with live status. Quit lives here too, or `⌘Q` while the card is open; `esc` only closes the card.

## Development

```
Sources/notchcode/
  Model/Contract.swift     the one contract every part talks through
  Transport/               the Unix socket server
  Sessions/                session files, diffs, subagents, usage, the file tree, the installer
  Notch/                   the panel over the notch, the geometry, the shape
  Views/                   every state and tab
  Theme.swift              every colour, size, font, radius, spring, and glyph
hooks/                     the two shell scripts Claude Code calls
scripts/                   connect, disconnect, test events, dev build, plugin sync
plugin/                    the Claude Code plugin
PLAN.md                    the spec: states, events, decisions, motion table
```

Useful commands:

```sh
xcodebuild -scheme notchcode build          # the check before a commit
scripts/send-test-event.sh permission       # fire a fake event at the running app
scripts/send-test-event.sh all
scripts/sync-plugin.sh --check              # plugin in step with hooks/
```

Rules the code follows: Swift and SwiftUI only; the app acts on your behalf only through hooks; hook scripts print nothing, have no dependencies, and exit 0 when the app is absent; every visual constant lives in `Theme.swift`; the closed state is pixel-identical to the notch.

## Status

Working on the owner's machine, unsigned, built from source. Next: a notarised build and a Homebrew cask, a marketplace entry for the plugin, and a floating pill for displays without a notch.
