#!/bin/sh
# send-test-event.sh <event> ...
#
# Fires fake Claude Code hook events at the running notchcode app, without Claude Code.
# events: permission  commit  stop  post_tool  shell_tool  notification  session_start  session_end
#         user_prompt  subagent_start  subagent_stop  statusline  all
#
# shell_tool is a Bash PostToolUse sent through hooks/notchcode-hook.sh, so it carries the
# real working tree of this repo. The first one is the baseline; change a file and send it
# again to see the change under the session's newest turn in Changes, tagged "shell".
#
# Blocking events (permission, commit) wait for your answer in the notch and print the
# raw reply line. Set NOTCHCODE_SOCK to aim at another socket.

sock="${NOTCHCODE_SOCK:-$HOME/Library/Application Support/notchcode/notchcode.sock}"
root=$(cd "$(dirname "$0")/.." && pwd)
session="00000000-0000-4000-8000-00000000c0de"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
cwd=$(esc "$root")
project=$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')
transcript=$(esc "$HOME/.claude/projects/$project/$session.jsonl")
common="\"session_id\":\"$session\",\"transcript_path\":\"$transcript\",\"cwd\":\"$cwd\",\"permission_mode\":\"default\""

payload_for() {
  case "$1" in
    permission)
      printf '{%s,"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run the test suite once"},"tool_use_id":"toolu_test_permission","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}' "$common" ;;
    commit)
      printf '{%s,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \\"Add socket transport and hook script\\"","description":"Commit the transport"},"tool_use_id":"toolu_test_commit"}' "$common" ;;
    stop)
      printf '{%s,"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Tests pass. I wired the socket server into the app and added the hook script."}' "$common" ;;
    post_tool)
      printf '{%s,"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/Sources/notchcode/Theme.swift","old_string":"static let clay = Color(hex: 0xD97757)","new_string":"static let clay = Color(hex: 0xD97757)\\n    static let amber = Color(hex: 0xF5A524)","replace_all":false},"tool_use_id":"toolu_test_edit","tool_response":{"filePath":"%s/Sources/notchcode/Theme.swift","success":true}}' "$common" "$cwd" "$cwd" ;;
    shell_tool)
      printf '{%s,"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"perl -pi -e s/clay/amber/ Sources/notchcode/Theme.swift","description":"Rename the colour"},"tool_use_id":"toolu_test_shell","tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false}}' "$common" ;;
    notification)
      printf '{%s,"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' "$common" ;;
    session_start)
      printf '{%s,"hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}' "$common" ;;
    session_end)
      printf '{%s,"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}' "$common" ;;
    user_prompt)
      printf '{%s,"hook_event_name":"UserPromptSubmit","prompt":"Run the tests and fix whatever fails"}' "$common" ;;
    subagent_start)
      printf '{%s,"hook_event_name":"SubagentStart","agent_id":"agent-test-0001","agent_type":"Explore"}' "$common" ;;
    subagent_stop)
      printf '{%s,"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_id":"agent-test-0001","agent_type":"Explore","agent_transcript_path":"%s","last_assistant_message":"Found the socket path in Contract.swift and the listener in SocketServer.swift.","background_tasks":[],"session_crons":[]}' "$common" "$(esc "$HOME/.claude/projects/$project/$session/subagents/agent-agent-test-0001.jsonl")" ;;
    statusline)
      # What Claude Code hands the status line: 5-hour limit 23.5 % used, resets in 2 h 14 m;
      # weekly 41.2 %, resets in 3 d. Same shape as https://code.claude.com/docs/en/statusline.md
      now=$(date +%s)
      printf '{"session_id":"%s","session_name":"ponyfish","transcript_path":"%s","cwd":"%s","model":{"id":"claude-opus-5-5","display_name":"Opus"},"workspace":{"current_dir":"%s","project_dir":"%s","added_dirs":[],"git_worktree":"ponyfish"},"version":"2.1.260","output_style":{"name":"default"},"cost":{"total_cost_usd":4.1872,"total_duration_ms":2843000,"total_api_duration_ms":611000,"total_lines_added":412,"total_lines_removed":57},"context_window":{"total_input_tokens":96400,"total_output_tokens":18250,"context_window_size":200000,"used_percentage":48,"remaining_percentage":52,"current_usage":{"input_tokens":1200,"output_tokens":850,"cache_creation_input_tokens":3400,"cache_read_input_tokens":91800}},"exceeds_200k_tokens":false,"fast_mode":false,"effort":{"level":"high"},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":%s},"seven_day":{"used_percentage":41.2,"resets_at":%s}}}' \
        "$session" "$transcript" "$cwd" "$cwd" "$cwd" "$((now + 8040))" "$((now + 259200))" ;;
    *) return 1 ;;
  esac
}

send() {
  name="$1"
  case "$name" in
    permission) kind=permission; wait=1 ;;
    commit)     kind=pre_tool;   wait=1 ;;
    *)          kind="$name";    wait=0 ;;
  esac
  payload=$(payload_for "$name") || { echo "unknown event: $name" >&2; return 1; }
  if [ "$name" = shell_tool ]; then
    # The hook script adds the working-tree report; it prints nothing and needs no reply.
    printf '%s' "$payload" | NOTCHCODE_SOCK="$sock" sh "$root/hooks/notchcode-hook.sh" post_tool
    echo "$name: sent through hooks/notchcode-hook.sh"
    return 0
  fi
  envelope=$(printf '{"v":1,"kind":"%s","id":"%s","term_program":"%s","term_bundle_id":"%s","pid":%s,"ts":%s,"payload":%s}' \
    "$kind" "$(uuidgen)" "$(esc "${TERM_PROGRAM:-}")" "$(esc "${__CFBundleIdentifier:-}")" "$$" "$(date +%s)" "$payload")
  if [ "$wait" -eq 1 ]; then
    echo "$name: sent, answer it in the notch (up to 58 s)..."
    reply=$(printf '%s\n' "$envelope" | nc -U -w 59 "$sock" 2>/dev/null | head -n 1)
    echo "$name: reply ${reply:-<none>}"
  else
    reply=$(printf '%s\n' "$envelope" | nc -U -w 2 "$sock" 2>/dev/null | head -n 1)
    echo "$name: sent, ack ${reply:-<none>}"
  fi
}

if [ $# -eq 0 ]; then
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
if [ ! -S "$sock" ]; then
  echo "notchcode is not running (no socket at $sock)" >&2
  exit 1
fi

for name in "$@"; do
  if [ "$name" = all ]; then
    for n in session_start statusline user_prompt subagent_start post_tool subagent_stop notification stop permission; do send "$n"; sleep 1; done
  else
    send "$name"
  fi
done
