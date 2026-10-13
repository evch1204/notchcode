# dev.ps1
# Builds notchcode (Debug) and launches it. `-Demo` walks every state with sample data.
#   .\scripts\dev.ps1          build and run
#   .\scripts\dev.ps1 -Demo    build and run with --demo
# Any other arguments are passed through to notchcode.exe.

[CmdletBinding()]
param(
    [switch]$Demo,
    # `-DebugKeys "open:changes,2,tab,snap:card,esc"`: drive the app with no one at the keys (App.xaml.cs).
    [string]$DebugKeys,
    # Write the mode and frame trace to %LOCALAPPDATA%\notchcode\debug.log.
    [switch]$DebugLog,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# dotnet: PATH first, then the per-user install.
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
    if (Test-Path $candidate) { $dotnet = $candidate }
}
if (-not $dotnet) { throw 'dotnet not found (PATH or %LOCALAPPDATA%\Microsoft\dotnet).' }
# A per-user runtime is not registered, so notchcode.exe's apphost finds it only through DOTNET_ROOT.
if (-not $env:DOTNET_ROOT) { $env:DOTNET_ROOT = Split-Path -Parent $dotnet }

# A running copy holds the exe open; stop it before the build replaces it.
Get-Process -Name notchcode -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$project = Join-Path $root 'src\Notchcode.App\Notchcode.App.csproj'
& $dotnet build $project -c Debug --nologo -v quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $root 'src\Notchcode.App\bin\Debug\net10.0-windows\notchcode.exe'
if (-not (Test-Path $exe)) { throw "Build output not found: $exe" }

$appArgs = @()
if ($Demo) { $appArgs += '--demo' }
if ($DebugKeys) { $appArgs += '--debug-keys'; $appArgs += $DebugKeys }
if ($DebugLog) { $appArgs += '--debug-log' }
if ($Rest) { $appArgs += $Rest }

if ($appArgs.Count -gt 0) {
    Start-Process -FilePath $exe -ArgumentList $appArgs -WorkingDirectory (Split-Path $exe)
} else {
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe)
}
