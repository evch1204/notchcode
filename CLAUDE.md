# notchcode

A notch app for macOS that surfaces Claude Code events as an interactive popup. `PLAN.md` is the spec: read it before starting work, and update it when a decision is made.

## Working with the owner

- Claude writes the code. The owner decides direction and design. Do not hand work back.
- Explain in short, simple sentences. Show the running result rather than describing files.
- Give blunt opinions. Check what already exists before proposing a feature.

## Rules

- Swift and SwiftUI only for the app. No Electron, no web views for the notch UI.
- The app may act on the owner's behalf only through Claude Code hooks (allow, deny, answer). It never edits files or runs shell commands itself.
- Hook scripts print nothing, have no dependencies, run `async`, and exit 0 even when the app is not running.
- Never overwrite the owner's existing hooks in `~/.claude/settings.json` (Orca, BurntToast, sidecar-pane). Add alongside them.
- All colours, corner radii, spring curves and glyphs come from one theme file.
- Closed state must be pixel-identical to the real notch: pure black, same radius, no shadow, no chrome.

## Environment

- macOS, Xcode, Swift. Node 20 is available for helper scripts. No `gh`.
- The repo is published through GitHub Desktop and stays private for now.

## Checks before a commit

```sh
xcodegen generate --quiet && xcodebuild -scheme notchcode build
```

## Windows port (`windows/`)

A second implementation of the same spec for Windows 11, planned 2026-10-12. `windows/PLAN.md` holds the Windows decisions; the root `PLAN.md` stays the spec for both.

- C# and WPF only. No Electron, no WebView2, no web view anywhere.
- The Swift app under `Sources/`, `hooks/`, `scripts/` and `plugin/` is the reference and is never changed by Windows work.
- The same rules apply: hooks only (plus the settings.json and git exceptions), one theme file (`windows/src/Notchcode.App/UI/Theme.cs`), the owner's existing hooks in `~/.claude/settings.json` are never overwritten, closed state is pure black with no chrome.
- The hook is a self-contained exe (`notchcode-hook.exe`): prints nothing but a decision line, no dependencies, exits 0 when the app is not running.
- Toolchain: the .NET LTS SDK at `%LOCALAPPDATA%\Microsoft\dotnet` (on the user PATH). No Visual Studio needed.

Checks before a commit that touches `windows/`:

```powershell
cd windows; dotnet build notchcode.sln -c Debug; dotnet test tests/Notchcode.Tests
```
