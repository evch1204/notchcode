# connect.ps1
# Development path for Connect: adds notchcode's hooks and status line to
# %USERPROFILE%\.claude\settings.json (beside the owner's own hooks, after a backup) by running
# `notchcode.exe --connect`, which calls HooksInstaller.Connect and exits without a window.
# The app's Settings → Connect is the primary way; this is for a fresh build.
#   .\scripts\connect.ps1                 the Debug build
#   .\scripts\connect.ps1 -Exe <path>     another notchcode.exe
# The flag is handled by HooksInstaller.HandleCommandLine, which App.OnStartup calls first.

[CmdletBinding()]
param([string]$Exe)

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $windows 'src\Notchcode.App\bin\Debug\net10.0-windows\notchcode.exe' }
if (-not (Test-Path $Exe)) { throw "notchcode.exe not found: $Exe (build it with .\scripts\dev.ps1)" }

# A per-user runtime is found only through DOTNET_ROOT.
if (-not $env:DOTNET_ROOT) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    if (Test-Path (Join-Path $candidate 'dotnet.exe')) { $env:DOTNET_ROOT = $candidate }
}

$p = Start-Process -FilePath $Exe -ArgumentList '--connect' -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0) { throw "connect failed (exit $($p.ExitCode)); settings.json is unchanged" }
Write-Output 'Connected: hooks and status line point at %LOCALAPPDATA%\notchcode\bin\notchcode-hook.exe'
