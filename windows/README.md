# notchcode for Windows

The Windows port of notchcode: a black notch at the top centre of the screen that shows
Claude Code's sessions, requests and changes. C# and WPF. The plan is `windows/PLAN.md`;
the spec is the root `PLAN.md`.

## Build

Needs the .NET 10 SDK. On this PC it is per user at `%LOCALAPPDATA%\Microsoft\dotnet`, which
Windows does not register, so a framework-dependent `notchcode.exe` (every Debug build) finds
the runtime only through `DOTNET_ROOT`:

```powershell
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"   # dev.ps1, connect.ps1 set it themselves
cd windows
dotnet build notchcode.sln -c Debug
dotnet test tests/Notchcode.Tests
```

`windows/NuGet.Config` points at nuget.org, because the per-user NuGet config here lists no source.

Every build of the app also publishes the hook (Release, self-contained single file) and copies
`notchcode-hook.exe` next to `notchcode.exe`, so the copy the app installs at launch is always
the current one. `-p:SkipHookPublish=true` skips that step.

## Release build

```powershell
dotnet publish src/Notchcode.App -c Release
```

gives `src/Notchcode.App/bin/Release/net10.0-windows/win-x64/publish/` with two files:
`notchcode.exe` (self-contained single file for win-x64, about 60 MB, no runtime and no
`DOTNET_ROOT` needed) and `notchcode-hook.exe` (about 16 MB). Keep them together; the app
copies the hook to `%LOCALAPPDATA%\notchcode\bin\` at every launch. The version is in
`Notchcode.App.csproj` (`<Version>`).

## Run

```powershell
.\scripts\dev.ps1          # build Debug, stop a running copy, start it
.\scripts\dev.ps1 -Demo    # the same with --demo: sample sessions walk every state
```

Only one notchcode runs per Windows user (a mutex and the pipe name both say so); a second
launch exits at once.

## Connect

Settings → Connect in the app is the way in. For a fresh build there are scripts that run the
same code without a window:

```powershell
.\scripts\connect.ps1      # notchcode.exe --connect
.\scripts\disconnect.ps1   # notchcode.exe --disconnect
notchcode.exe --hooks-status | Write-Output   # prints connected / not-connected / partial / stale
```

`--connect` and `--disconnect` exit 0 when done and 1 when `settings.json` was left as it was
(the reason on stderr; an unreadable file is never written). `--hooks-status` exits 0, 1, 2
or 3 for connected, not connected, partial, stale. A WinExe has a stdout only when the
caller redirects it, hence the pipe into `Write-Output`.

Connect adds only entries whose command names `notchcode-hook`, beside every other hook, after
a backup (`settings.json.notchcode-backup-<time>`, newest 5 kept). Disconnect takes them out and
puts the previous status line back, so a connect followed by a disconnect gives back the same
bytes (checked on a copy of this PC's file: `$env:NOTCHCODE_REAL = "1"` runs the read-only
checks in `RealMachineTests`).

## Projects

| Project | What |
|---|---|
| `src/Notchcode.App` | the app (`notchcode.exe`, WPF) |
| `src/Notchcode.Hook` | the hook and status line forwarder (`notchcode-hook.exe`, self-contained single file, trimmed) |
| `tests/Notchcode.Tests` | xunit |

The hook links `Core/Paths.cs` from the app. It writes the envelope by hand, as `hooks/notchcode-hook.sh` does, so the trimmed exe carries no reflection-based JSON (its publish has no trim warnings); `HookExeTests` run the built exe against the app's `PipeServer` and `HookEnvelope`, so the two cannot drift. Publish it alone with `dotnet publish src/Notchcode.Hook -c Release`.

Test events: `.\scripts\send-test-event.ps1 all` (or any event name) against the running app.

## Where things live

| What | Where |
|---|---|
| App state, preferences | `%LOCALAPPDATA%\notchcode\` (`preferences.json`, `statusline-chain.json`, `statusline-stamps\`, `shell-changes\`, `usage\`) |
| Hook exe | `%LOCALAPPDATA%\notchcode\bin\notchcode-hook.exe` (with `app-path.txt` and `dotnet-root.txt`, which `notchcode-hook.exe launch` reads) |
| Pipe | `\\.\pipe\notchcode-<username>`, current user only |
| Claude Code | `%USERPROFILE%\.claude\` (`CLAUDE_CONFIG_DIR` when set): `settings.json`, `projects\`, `plans\`; and `%USERPROFILE%\.claude.json` |
