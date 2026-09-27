# notchcode

A macOS app that lives in the MacBook notch and turns Claude Code events into a Dynamic Island-style popup: "Claude is ready", permission prompts you can accept or deny, questions you can answer, commits you can approve, and diffs you can read, all without leaving the notch.

Sibling project of [sidecar-pane](https://github.com/evch1204/sidecar-pane), which shows the same stream in a terminal split. The two share a data contract (Claude Code hooks and session files), not code.

## Status

Planning. See `PLAN.md`.

## Requirements

- MacBook with a notch (2021 or later), macOS 14 or newer
- Xcode (the full app, not just Command Line Tools)
- Claude Code CLI

## Install

Two pieces: the notchcode app, and hooks that tell Claude Code to send it events.

Build the app (needs the Xcode licence accepted once: `sudo xcodebuild -license accept`):

```sh
xcodegen generate
xcodebuild -scheme notchcode build
```

Then connect Claude Code in one of three ways, shortest first. Pick one: with two of them,
every event reaches the app twice.

**a. The Claude Code plugin.** It adds the hooks without touching `~/.claude/settings.json`, and
it opens the app when a session starts. Once published:

```sh
claude plugin install notchcode@<marketplace>
```

Until then, load it for one session: `claude --plugin-dir ./plugin`. See [plugin/README.md](plugin/README.md).

**b. The app's Settings → Connect button** (⌘,). It adds notchcode's hooks to
`~/.claude/settings.json`, beside your own, pointing at the hook script inside the app.
Disconnect removes them again.

**c. From the repo, with Node 20:**

```sh
node scripts/connect.mjs      # add the hooks
node scripts/disconnect.mjs   # remove them
```

Both take `--settings <path>` to work on another file and `--dry-run` to only print what would change.

Ways b and c follow the same rules. They back the file up first (`settings.json.notchcode-backup-<time>`).
They add or replace only entries whose command contains `notchcode-hook.sh`, and never touch your
other hooks. They keep the file's key order, and are safe to run again.

**Usage limits.** The 5-hour and weekly limits reach notchcode only through Claude Code's
status line, so b or c is needed for them (the plugin cannot set `statusLine`); your existing
status line is saved, keeps running through ours, and comes back on disconnect.

**Restart running sessions.** Claude Code reads hooks when a session starts. Sessions that are
already open keep their old hooks until you restart them.

### When the app is not running

The hook script checks for the socket at `~/Library/Application Support/notchcode/notchcode.sock`.
If it is missing, or nothing is listening, the script prints nothing and exits 0 at once. Claude
Code is unaffected: it carries on as if notchcode were not installed, and its normal terminal
prompt appears.

When the app is running but you do not answer a permission request, the app gives up after 58
seconds. The hook prints nothing and the terminal prompt takes over. notchcode never denies
anything on your behalf.

The hooks it installs:

| Claude Code event | Matcher | Blocks Claude? |
|---|---|---|
| `PermissionRequest` | all tools | yes, until you answer or 58 s pass |
| `PreToolUse` | `Bash`, only `git commit *` | yes, same |
| `PostToolUse` | `Edit\|Write\|MultiEdit` | no |
| `Notification`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop` | all | no (returns in under a second) |

### Try it without Claude Code

With the app running, this sends a fake permission request, waits for you to answer in the notch, and prints the reply:

```sh
scripts/send-test-event.sh permission
scripts/send-test-event.sh all        # session_start, user_prompt, subagent_start, post_tool, subagent_stop, notification, stop, permission
```

Other events: `commit`, `stop`, `post_tool`, `notification`, `session_start`, `session_end`, `user_prompt`, `subagent_start`, `subagent_stop`.
