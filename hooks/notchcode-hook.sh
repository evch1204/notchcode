#!/bin/sh
# notchcode-hook.sh <kind>
#
# Forwards one Claude Code hook event to the notchcode app over its Unix socket.
# kind: permission pre_tool post_tool notification stop session_start session_end user_prompt
#       subagent_start subagent_stop statusline
#
# Rules: no dependencies beyond macOS base (sh, nc, sed, tr, date, uuidgen); prints
# nothing unless the app replied allow or deny to a blocking event; always exits 0,
# including when the app is not running. Wire format: see Contract.swift.

kind="$1"
case "$kind" in
  permission|pre_tool) blocking=1 ;;
  post_tool|notification|stop|session_start|session_end|user_prompt|subagent_start|subagent_stop|statusline) blocking=0 ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

sock="${NOTCHCODE_SOCK:-$HOME/Library/Application Support/notchcode/notchcode.sock}"

# The hook input is one JSON object. Raw newlines can only sit between tokens
# (inside strings they are escaped), so turning them into spaces keeps it valid.
payload=$(cat 2>/dev/null | tr '\r\n' '  ')

# App not running: stay silent, let Claude Code carry on.
[ -S "$sock" ] || exit 0

[ -n "$payload" ] || payload='{}'

esc() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

id=$(uuidgen 2>/dev/null) || id=""
[ -n "$id" ] || id="$$-$(date +%s)"
ts=$(date +%s)
pid=${PPID:-0}
case "$pid" in ''|*[!0-9]*) pid=0 ;; esac

envelope=$(printf '{"v":1,"kind":"%s","id":"%s","term_program":"%s","term_bundle_id":"%s","pid":%s,"ts":%s,"payload":%s}' \
  "$kind" "$id" "$(esc "${TERM_PROGRAM:-}")" "$(esc "${__CFBundleIdentifier:-}")" "$pid" "$ts" "$payload")

if [ "$blocking" -eq 0 ]; then
  printf '%s\n' "$envelope" | nc -U -w 1 "$sock" >/dev/null 2>&1
  exit 0
fi

# Blocking: wait up to 59 s for one reply line. The app answers "none" at 58 s,
# and Claude Code's own hook timeout is 65 s, so nothing is ever cut off mid-way.
reply=$(printf '%s\n' "$envelope" | nc -U -w 59 "$sock" 2>/dev/null | head -n 1)
[ -n "$reply" ] || exit 0

# The app writes sorted keys: always, decision, id, reason, then updated_permissions
# last. Look for decision/always only in the part before any free text.
head=${reply%%\"reason\"*}
head=${head%%\"updated_permissions\"*}
case "$head" in
  *'"decision":"allow"'*) decision=allow ;;
  *'"decision":"deny"'*)  decision=deny ;;
  *) exit 0 ;;
esac
case "$head" in
  *'"always":true'*) always=1 ;;
  *) always=0 ;;
esac

# Optional deny reason, copied as an already-escaped JSON string literal.
reason=""
case "$reply" in
  *'"reason":"'*)
    reason=$(printf '%s' "$reply" | sed -E 's/.*"reason":("([^"\\]|\\.)*").*/\1/')
    case "$reason" in '"'*'"') ;; *) reason="" ;; esac
    ;;
esac

# Permission rules to remember, when the owner chose "always" (JSON array, verbatim).
perms=""
case "$reply" in
  *'"updated_permissions":['*)
    perms=${reply#*\"updated_permissions\":}
    perms=${perms%\}}
    ;;
esac

case "$kind" in
  permission)
    if [ "$decision" = allow ]; then
      if [ "$always" -eq 1 ] && [ -n "$perms" ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":%s}}}\n' "$perms"
      else
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
      fi
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":%s}}}\n' "${reason:-\"Denied from notchcode\"}"
    fi
    ;;
  pre_tool)
    if [ "$decision" = allow ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved in notchcode"}}\n'
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "${reason:-\"Denied from notchcode\"}"
    fi
    ;;
esac
exit 0
