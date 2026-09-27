# notchcode plan

## What it is

A menu-bar-less agent app that draws a black shape over the MacBook notch. Closed, it is invisible. When Claude Code needs the owner, the shape springs open into a card with buttons.

## Events it should handle (first pass)

| Event | Source hook | Card shows | Buttons |
|---|---|---|---|
| Claude finished / waiting | `Notification` | last message summary | Open terminal, Dismiss |
| Permission request | `PermissionRequest` | tool name, command or path | Allow, Deny, Allow always |
| Question to the owner | `Notification` | the question and options | one button per option |
| Commit proposed | `PreToolUse` on `git commit` | commit message, file count | Commit, Edit, Skip |
| Diff ready | `PostToolUse` on Edit/Write | file, added/removed lines | Expand, Next, Dismiss |

## Open decisions

- Transport between hook scripts and the app: Unix socket, named pipe, or a watched folder.
- How the permission hook waits for the tap without blocking Claude Code for too long. Needs a timeout and a default.
- Multiple sessions at once: one card per session, or a stack.
- Whether the closed notch shows a tiny status glyph (busy, idle, needs you).

## Not doing

- Music, calendar, file shelf, or anything the existing notch apps already do.
- Editing files or running commands directly from the app.

## References

- Boring Notch (open source) for window placement and the expand animation.
- `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` for the notch geometry.
- Claude Code hooks docs: `Notification`, `PermissionRequest`, `PreToolUse`, `PostToolUse`.
