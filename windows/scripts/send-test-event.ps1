# send-test-event.ps1 <event> ...
#
# Fires fake Claude Code hook events at the running notchcode app, without Claude Code.
# events: permission  commit  plan  stop  post_tool  shell_tool  notification  session_start  session_end
#         user_prompt  subagent_start  subagent_stop  statusline  all
#
# shell_tool is a Bash PostToolUse sent through notchcode-hook.exe, so it carries the
# real working tree of this repo. The first one is the baseline; change a file and send it
# again to see the change under the session's newest turn in Changes, tagged "shell".
#
# Blocking events (permission, commit, plan) wait for your answer in the notch and print
# the raw reply line. plan is an ExitPlanMode PermissionRequest as Claude Code 2.1.287 sends
# it (permission_mode plan, no tool_use_id, no permission_suggestions); it waits up to
# 298 s. -Pipe aims at another pipe name (default notchcode-<username>).
#
# Windows port of scripts/send-test-event.sh: the same events and payload shapes, with
# Windows paths, over the named pipe. Runs on Windows PowerShell 5.1 and PowerShell 7.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Pipe,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Events
)

$ErrorActionPreference = 'Stop'

if (-not $Events -or $Events.Count -eq 0) {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 14 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 1
}

# The pipe's name, as NotchcodePaths.PipeName makes it: [A-Za-z0-9._-] kept, the rest '-'.
if (-not $Pipe) {
    $user = ($env:USERNAME -replace '[^A-Za-z0-9._-]', '-')
    if (-not $user) { $user = 'user' }
    $Pipe = "notchcode-$user"
}

$windows = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $windows
$session = '00000000-0000-4000-8000-00000000c0de'

# A JSON string literal.
function J([string]$s) {
    '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + '"'
}

$cwd = J $root
$project = $root -replace '[^A-Za-z0-9]', '-'
$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$transcript = J (Join-Path $claudeDir "projects\$project\$session.jsonl")
$common = "`"session_id`":`"$session`",`"transcript_path`":$transcript,`"cwd`":$cwd,`"permission_mode`":`"default`""
$planCommon = $common.Replace('"permission_mode":"default"', '"permission_mode":"plan"')

$planMarkdown = @'
# Plan: Add "Hello" to README.md

## Context
The README has no greeting. The owner wants one line at the top.

## Steps
1. Open `README.md` and find the first heading.
   - Keep the badges where they are.
2. Add a line that reads **Hello** under it.
   - One line, no emoji.
3. Run `scripts/sync-plugin.sh --check` to be sure nothing else moved.

## Verification
- `Get-Content README.md -TotalCount 5` shows the new line.
- The diff lists only README.md.
'@ -replace "`r`n", "`n"
$planMarkdown = $planMarkdown.TrimEnd("`n")

function PayloadFor([string]$name) {
    $theme = J (Join-Path $root 'Sources\notchcode\Theme.swift')
    switch ($name) {
        'permission' { return "{$common,`"hook_event_name`":`"PermissionRequest`",`"tool_name`":`"Bash`",`"tool_input`":{`"command`":`"npm test -- --watch=false`",`"description`":`"Run the test suite once`"},`"tool_use_id`":`"toolu_test_permission`",`"permission_suggestions`":[{`"type`":`"addRules`",`"rules`":[{`"toolName`":`"Bash`",`"ruleContent`":`"npm test:*`"}],`"behavior`":`"allow`",`"destination`":`"localSettings`"}]}" }
        'plan' {
            $planFile = J (Join-Path $claudeDir 'plans\add-hello-to-readme-quiet-harbor.md')
            return "{$planCommon,`"hook_event_name`":`"PermissionRequest`",`"tool_name`":`"ExitPlanMode`",`"tool_input`":{`"plan`":$(J $planMarkdown),`"planFilePath`":$planFile}}"
        }
        'commit' { return "{$common,`"hook_event_name`":`"PreToolUse`",`"tool_name`":`"Bash`",`"tool_input`":{`"command`":`"git commit -m \`"Add pipe transport and hook exe\`"`",`"description`":`"Commit the transport`"},`"tool_use_id`":`"toolu_test_commit`"}" }
        'stop' { return "{$common,`"hook_event_name`":`"Stop`",`"stop_hook_active`":false,`"last_assistant_message`":`"Tests pass. I wired the pipe server into the app and added the hook exe.`"}" }
        'post_tool' { return "{$common,`"hook_event_name`":`"PostToolUse`",`"tool_name`":`"Edit`",`"tool_input`":{`"file_path`":$theme,`"old_string`":`"static let clay = Color(hex: 0xD97757)`",`"new_string`":`"static let clay = Color(hex: 0xD97757)\n    static let amber = Color(hex: 0xF5A524)`",`"replace_all`":false},`"tool_use_id`":`"toolu_test_edit`",`"tool_response`":{`"filePath`":$theme,`"success`":true}}" }
        'shell_tool' { return "{$common,`"hook_event_name`":`"PostToolUse`",`"tool_name`":`"Bash`",`"tool_input`":{`"command`":`"(Get-Content Sources/notchcode/Theme.swift) -replace 'clay','amber' | Set-Content Sources/notchcode/Theme.swift`",`"description`":`"Rename the colour`"},`"tool_use_id`":`"toolu_test_shell`",`"tool_response`":{`"stdout`":`"`",`"stderr`":`"`",`"interrupted`":false,`"isImage`":false}}" }
        'notification' { return "{$common,`"hook_event_name`":`"Notification`",`"message`":`"Claude is waiting for your input`",`"notification_type`":`"idle_prompt`"}" }
        'session_start' { return "{$common,`"hook_event_name`":`"SessionStart`",`"source`":`"startup`",`"model`":`"claude-opus-5`"}" }
        'session_end' { return "{$common,`"hook_event_name`":`"SessionEnd`",`"reason`":`"prompt_input_exit`"}" }
        'user_prompt' { return "{$common,`"hook_event_name`":`"UserPromptSubmit`",`"prompt`":`"Run the tests and fix whatever fails`"}" }
        'subagent_start' { return "{$common,`"hook_event_name`":`"SubagentStart`",`"agent_id`":`"agent-test-0001`",`"agent_type`":`"Explore`"}" }
        'subagent_stop' {
            $agentTranscript = J (Join-Path $claudeDir "projects\$project\$session\subagents\agent-agent-test-0001.jsonl")
            return "{$common,`"hook_event_name`":`"SubagentStop`",`"stop_hook_active`":false,`"agent_id`":`"agent-test-0001`",`"agent_type`":`"Explore`",`"agent_transcript_path`":$agentTranscript,`"last_assistant_message`":`"Found the pipe name in Paths.cs and the listener in PipeServer.cs.`",`"background_tasks`":[],`"session_crons`":[]}"
        }
        'statusline' {
            # What Claude Code hands the status line: 5-hour limit 23.5 % used, resets in 2 h 14 m;
            # weekly 41.2 %, resets in 3 d. Same shape as https://code.claude.com/docs/en/statusline.md
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            return "{`"session_id`":`"$session`",`"session_name`":`"ponyfish`",`"transcript_path`":$transcript,`"cwd`":$cwd,`"model`":{`"id`":`"claude-opus-5-5`",`"display_name`":`"Opus`"},`"workspace`":{`"current_dir`":$cwd,`"project_dir`":$cwd,`"added_dirs`":[],`"git_worktree`":`"ponyfish`"},`"version`":`"2.1.260`",`"output_style`":{`"name`":`"default`"},`"cost`":{`"total_cost_usd`":4.1872,`"total_duration_ms`":2843000,`"total_api_duration_ms`":611000,`"total_lines_added`":412,`"total_lines_removed`":57},`"context_window`":{`"total_input_tokens`":96400,`"total_output_tokens`":18250,`"context_window_size`":200000,`"used_percentage`":48,`"remaining_percentage`":52,`"current_usage`":{`"input_tokens`":1200,`"output_tokens`":850,`"cache_creation_input_tokens`":3400,`"cache_read_input_tokens`":91800}},`"exceeds_200k_tokens`":false,`"fast_mode`":false,`"effort`":{`"level`":`"high`"},`"thinking`":{`"enabled`":true},`"rate_limits`":{`"five_hour`":{`"used_percentage`":23.5,`"resets_at`":$($now + 8040)},`"seven_day`":{`"used_percentage`":41.2,`"resets_at`":$($now + 259200)}}}"
        }
        default { return $null }
    }
}

# The hook exe: the installed copy, else this tree's publish output, else its Debug build.
function HookExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'notchcode\bin\notchcode-hook.exe'),
        (Join-Path $windows 'src\Notchcode.Hook\bin\Release\net10.0\win-x64\publish\notchcode-hook.exe'),
        (Join-Path $windows 'src\Notchcode.Hook\bin\Debug\net10.0\win-x64\notchcode-hook.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw 'notchcode-hook.exe not found: run dotnet publish windows/src/Notchcode.Hook -c Release'
}

# Sends one line, returns the first reply line (or $null after $seconds).
function Exchange([string]$line, [int]$seconds) {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(2000)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line + "`n")
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()
        $reader = New-Object System.IO.StreamReader($client, (New-Object System.Text.UTF8Encoding($false)))
        $task = $reader.ReadLineAsync()
        if ($task.Wait($seconds * 1000)) { return $task.Result }
        return $null
    } finally {
        $client.Dispose()
    }
}

function Send([string]$name) {
    switch ($name) {
        'permission' { $kind = 'permission'; $wait = $true; $secs = 59 }
        'plan'       { $kind = 'permission'; $wait = $true; $secs = 299 }
        'commit'     { $kind = 'pre_tool'; $wait = $true; $secs = 59 }
        default      { $kind = $name; $wait = $false; $secs = 2 }
    }
    $payload = PayloadFor $name
    if (-not $payload) { Write-Error "unknown event: $name" -ErrorAction Continue; return }
    if ($name -eq 'shell_tool') {
        # The hook exe adds the working-tree report; it prints nothing and needs no reply.
        $env:NOTCHCODE_PIPE = $Pipe
        Push-Location $root
        try { $payload | & (HookExe) post_tool } finally { Pop-Location }
        Write-Output "${name}: sent through notchcode-hook.exe"
        return
    }
    $termProgram = if ($env:TERM_PROGRAM) { $env:TERM_PROGRAM } elseif ($env:WT_SESSION) { 'WindowsTerminal' } else { '' }
    $id = [guid]::NewGuid().ToString().ToUpperInvariant()
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $envelope = "{`"v`":1,`"kind`":`"$kind`",`"id`":`"$id`",`"term_program`":$(J $termProgram),`"term_bundle_id`":`"`",`"pid`":$PID,`"ts`":$ts,`"payload`":$payload}"
    if ($wait) {
        Write-Output "${name}: sent, answer it in the notch (up to $($secs - 1) s)..."
        $reply = Exchange $envelope $secs
        if (-not $reply) { $reply = '<none>' }
        Write-Output "${name}: reply $reply"
    } else {
        $reply = Exchange $envelope $secs
        if (-not $reply) { $reply = '<none>' }
        Write-Output "${name}: sent, ack $reply"
    }
}

# Is anyone listening?
$probe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
try { $probe.Connect(500) } catch {
    Write-Error "notchcode is not running (no pipe \\.\pipe\$Pipe)" -ErrorAction Continue
    exit 1
} finally { $probe.Dispose() }

foreach ($name in $Events) {
    if ($name -eq 'all') {
        foreach ($n in 'session_start', 'statusline', 'user_prompt', 'subagent_start', 'post_tool', 'subagent_stop', 'notification', 'stop', 'permission', 'plan') {
            Send $n
            Start-Sleep -Seconds 1
        }
    } else {
        Send $name
    }
}
