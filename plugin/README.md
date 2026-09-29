# notchcode plugin for Claude Code

Connects Claude Code to the notchcode app, which shows your sessions in the MacBook notch.
You can allow or deny permission requests from the notch and approve `git commit`.

The plugin only adds hooks. **The app is installed separately**: download it from GitHub
Releases (a Homebrew cask comes later). Without the app the hooks do nothing.

## Install

Once the plugin is published to a marketplace:

```sh
claude plugin install notchcode@<marketplace>
```

For now, load it from this folder for one session:

```sh
claude --plugin-dir ./plugin
```

Start a new Claude Code session after installing. Sessions that are already running keep
their old hooks until you restart them.

## What it does

- Every hook runs `hooks/notchcode-hook.sh <kind>`. The script sends the event to the app over
  a Unix socket at `~/Library/Application Support/notchcode/notchcode.sock`.
- `SessionStart` also opens the app in the background if it is not running
  (`open -g -b com.evch.notchcode`). If the app is not installed, nothing happens.
- When the app is not running, every hook prints nothing and exits 0 at once. Claude Code
  carries on as if the plugin were not there.
- A permission request waits up to 58 s for an answer in the notch. After that the normal
  terminal prompt takes over. Nothing is ever denied on your behalf.

| Claude Code event | Matcher | Blocks Claude? |
|---|---|---|
| `PermissionRequest` | all tools | yes, until you answer or 58 s pass |
| `PreToolUse` | `Bash`, only `git commit *` | yes, same |
| `PostToolUse` | `Edit\|Write\|MultiEdit\|Bash` | no |
| `Notification`, `Stop`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop` | all | no |

## Usage limits need one more step

Claude Code gives the 5-hour and weekly limits only to the single `statusLine` command in
`~/.claude/settings.json`, and a plugin cannot set `statusLine`. So for real limits in the notch,
also run the app's Settings → Connect, or `node scripts/connect.mjs` from the repo. That makes
`hooks/notchcode-statusline.sh` the status line. Whatever status line you had (Orca's,
sidecar-pane's, your own) is saved and still runs through it, so your status line looks the same.
Disconnect puts it back. Without this step the notch shows no limits.

Connect also adds the hooks, so after it you can drop the plugin. Use the plugin **or** the app's Settings → Connect, not both. With both, every event reaches
the app twice.

## For maintainers

`hooks/notchcode-hook.sh` and `hooks/hooks.json` here are generated. Edit the repo's
`hooks/notchcode-hook.sh` and the table in `scripts/lib/settings.mjs`, then run:

```sh
scripts/sync-plugin.sh          # copy the script, rewrite hooks.json
scripts/sync-plugin.sh --check  # exit 1 if the plugin is out of date
claude plugin validate ./plugin
```
