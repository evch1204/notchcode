# notchcode

A macOS app that turns the MacBook notch into a companion for Claude Code. See what every session is doing from any app, and allow or deny a permission request with one key without leaving your work.

The design lives on a canvas with every state, the directions explored, and looping motion studies: [notchcode design](https://claude.ai/artifact/AChgFMt8kby2qukkVNxwrn).
The first-run flow is sketched in the onboarding mockup: https://claude.ai/artifact/V2HFkMgJTpagrsjzd36v9n.

## What you get

**Doorbell.** When Claude asks to run a command, edit a file, or commit, the notch grows to two rows, names the request, and waits. `⏎` allows, `⌫` denies, `A` allows always. For a code change, `D` opens the real diff inside the card, built from the exact text Claude wants to write, so you approve what you have read and not a pair of counts. Answer in the terminal instead and the card folds away. Answer nowhere and the terminal prompt takes over after a minute. notchcode never denies anything on your behalf.

**Traffic light.** From any app or space you can see whether Claude is working, blocked on you, or done, across every session on the machine.

**Companion.** Press the notch at any time and a card opens with five tabs.

| Tab | Shows |
|---|---|
| Sessions | every live session by repository, one row per worktree: branch, model, permission mode (`bypass` in clay, `plan` in blue; nothing for default), state, current prompt, a lane per subagent. `⏎` opens its Changes. |
| Changes | each turn you sent, the files it changed (subagent edits too), and the full diff under any file. |
| Files | the repository tree, changed files badged, and a preview with changed lines tinted; `⌘B` folds the tree away for a full-width preview, and Markdown files render with a Preview · Code switch. |
| Usage | 5-hour and weekly limits with reset times, context used, tokens for the session and today, an estimated cost. |
| Git | the focused session's worktree, or any local branch of a repository a session runs in (the picker, `W`: one row per branch saying where it lives, "worktree seadevil", "main checkout" or "not checked out", with its uncommitted count or how far it is ahead). Branch, commits to push, and two panes like Files: the uncommitted files (each with its ± cells and counts) and the last five commits (unpushed ones tagged) on the left, the selected file's diff on the right, with line numbers, changed words lit, sideways scrolling and a minimap of the whole file. A branch checked out nowhere shows its changes and commits against main, read-only. A Push (or Publish) button that asks before it pushes. |

**Teleport.** Every session knows which terminal started it. One key lands you in that window. With several worktrees of one repository open at once, this is the reason to keep the app.

Closed, the notch looks exactly like the hardware. Nothing is drawn over the camera; every state is a left wing, the camera gap, and a right wing, with the card below.

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

## Install

### Requirements

- A MacBook with a notch (2021 or later) running macOS 14 or newer. On a display without a notch the app draws nothing yet.
- Claude Code.
- For now, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), because there is no download yet. Accept the Xcode licence once with `sudo xcodebuild -license accept`, and install XcodeGen with `brew install xcodegen`.

### Today: build it once

From a clone of this repository:

```sh
scripts/dev.sh            # generate the project, build, launch
scripts/dev.sh --demo     # the same, walking every state with sample data
```

The first command builds the app and opens it over the notch. The second does the same and plays every state with sample data, so you can see it before connecting anything.

After this one build the app stays on your Mac, in `build/DerivedData/Build/Products/Debug/notchcode.app` inside the clone. You do not run the script again unless you want a newer version. The app does not start at login yet; after a restart, open it again:

```sh
open build/DerivedData/Build/Products/Debug/notchcode.app
```

### Connect Claude Code

Open the card (click the notch, or press `⌥ space`), press the gear, then press Connect.

Connect adds notchcode's hooks to `~/.claude/settings.json` beside your own, and never changes your other hooks. It chains the status line, so the one you already use keeps running and notchcode gets your usage limits. It backs the file up first, and Disconnect puts everything back.

Sessions already running keep their old hooks until you restart them.

### Coming

Not available yet:

- A notarised download and a Homebrew cask.
- Open at login, and a first-run Welcome card in the notch.
- The Claude Code plugin on a marketplace.

## How it works

1. **Session files.** Claude Code writes every session to `~/.claude/projects/<folder>/<session>.jsonl`, and notchcode polls that folder every two seconds. That alone gives sessions, prompts, files, diffs, subagents, tokens, and cost, with no setup.
2. **Hooks.** One shell script, called by Claude Code's hooks, sends one JSON line over a Unix socket in `~/Library/Application Support/notchcode/`. For a permission request or a `git commit` it waits for your answer; if the app is not running it prints nothing and exits at once.
3. **Status line.** Claude Code hands its status line command the 5-hour and weekly limits. notchcode's status line script forwards them to the app, then runs whatever status line you had before.

It is the sibling of [sidecar-pane](https://github.com/evch1204/sidecar-pane), which shows the same stream in a terminal split. They share a data contract, not code.

| Claude Code event | Matcher | Blocks Claude? |
|---|---|---|
| `PermissionRequest` | all tools | until you answer, or 58 s pass |
| `PreToolUse` | `Bash`, only `git commit …` | the same |
| `PostToolUse` | `Edit`, `Write`, `MultiEdit`, `Bash` | no |
| `Notification`, `Stop`, `UserPromptSubmit` | | no |
| `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop` | | no |
| `statusLine` | | no; chained in front of your existing one |

### What it touches

The app never edits your project and makes no network requests of its own. The one command it runs is `git`, for the Git tool: read-only commands to show the worktree, and `git push` only when you press Push and confirm. The only file it writes outside its own folder is `~/.claude/settings.json`. It adds or removes only its own entries there, after a backup named `settings.json.notchcode-backup-<time>`, and only when you press Connect or Disconnect.

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
| `1` – `5` | pick a tool |
| `⇥` `⇧⇥` | next and previous tool |
| `↑` `↓` `←` `→` | move in a list or the file tree (in Git, `↑` `↓` select a file and show its diff) |
| `y` | copy `path:line` of the first changed line |
| `/` | filter the Files tree, or the Git branch picker past eight branches |
| `⌘B` | hide or show the Files tree, or the Git file list (one switch for both) |
| `P` | switch a Markdown file between Preview and Code (Files); push or publish the branch, after a `⏎` confirm (Git) |
| `W` | the Git branch picker: every local branch of a repository (`↑` `↓`, `⏎` shows that branch, `esc` goes back) |
| `R` | in the Git branch picker, the repository dropdown (`↑` `↓`, `⏎` picks, `esc` closes) |
| `⌥↑` `⌥↓` | previous and next hunk in the Git diff |
| `⌥⏎` | jump to the session's terminal |
| `⌘,` | Settings |
| `⌘Q` | quit notchcode (while the card is open) |
| `esc` | back, or close |

## Settings

A page inside the card, never a separate window: the gear, or `⌘,` while the card is open. It holds what shows when idle (the resting row, or a pure notch), how "needs you" looks (two rows, or wings only), whether finished turns and agents peek and for how long, whether every file edit peeks too, click or hover to open, the `⌥ space` hotkey, agents in the wings, an optional macOS notification for blocking requests, and Connect / Disconnect with live status. Quit lives here too, or `⌘Q` while the card is open; `esc` only closes the card.

## Uninstall

1. Press Disconnect in Settings, or run `node scripts/disconnect.mjs` from the clone. This removes only notchcode's hooks and restores your status line.
2. Quit notchcode from Settings, or `⌘Q` while the card is open.
3. Delete the app (the `build` folder in the clone, or the clone itself) and `~/Library/Application Support/notchcode`.

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

Connect without the app, with Node 20. Both take `--settings <path>` and `--dry-run`, follow the same rules as Connect, and are safe to run twice:

```sh
node scripts/connect.mjs      # add the hooks and chain the status line
node scripts/disconnect.mjs   # remove only ours, restore the status line
```

The plugin adds the hooks without touching `settings.json` and opens the app when a session starts, but cannot carry usage limits. Load it for one session; use it or Connect, not both, or every event arrives twice. See [plugin/README.md](plugin/README.md).

```sh
claude --plugin-dir ./plugin
```

## Status

Working on the owner's machine, unsigned, built from source. Next: a notarised build and a Homebrew cask, a marketplace entry for the plugin, and a floating pill for displays without a notch.
