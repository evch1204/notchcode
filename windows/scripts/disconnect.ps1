# disconnect.ps1
# Development path for Disconnect: removes notchcode's hooks from
# %USERPROFILE%\.claude\settings.json and puts the previous status line back, by running
# `notchcode.exe --disconnect` (HooksInstaller.Disconnect). Every other hook stays as it was.
#   .\scripts\disconnect.ps1                 the Debug build
#   .\scripts\disconnect.ps1 -Exe <path>     another notchcode.exe

[CmdletBinding()]
param([string]$Exe)

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $windows 'src\Notchcode.App\bin\Debug\net10.0-windows\notchcode.exe' }
if (-not (Test-Path $Exe)) { throw "notchcode.exe not found: $Exe (build it with .\scripts\dev.ps1)" }

if (-not $env:DOTNET_ROOT) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    if (Test-Path (Join-Path $candidate 'dotnet.exe')) { $env:DOTNET_ROOT = $candidate }
}

$p = Start-Process -FilePath $Exe -ArgumentList '--disconnect' -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0) { throw "disconnect failed (exit $($p.ExitCode)); settings.json is unchanged" }
Write-Output 'Disconnected: notchcode''s hooks removed, the previous status line restored'
