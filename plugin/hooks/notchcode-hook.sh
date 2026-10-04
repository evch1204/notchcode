#!/bin/sh
# notchcode-hook.sh <kind>
#
# Forwards one Claude Code hook event to the notchcode app over its Unix socket.
# kind: permission pre_tool post_tool notification stop session_start session_end user_prompt
#       subagent_start subagent_stop statusline
#
# Rules: no dependencies beyond macOS base (sh, nc, sed, tr, date, uuidgen, git, base64);
# prints nothing unless the app replied allow or deny to a blocking event; always exits 0,
# including when the app is not running. Wire format: see Contract.swift.
#
# For user_prompt, and for post_tool on Bash, the envelope also carries a working-tree
# report ("tree"): git status and the diff against HEAD, base64, so the app can see files a
# shell command changed. Read-only git (GIT_OPTIONAL_LOCKS=0), skipped outside a work tree.

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

# A JSON string body: tabs become spaces and every other control character goes, so a
# stray one in TERM_PROGRAM or a path cannot make the envelope invalid JSON.
esc() {
  printf '%s' "$1" | tr '\t' ' ' | tr -d '\000-\010\012-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# The first "cwd" string in the payload, unescaped. Falls back to $PWD.
payload_cwd() {
  rest=${payload#*\"cwd\":\"}
  [ "$rest" != "$payload" ] || rest=${payload#*\"cwd\": \"}
  if [ "$rest" != "$payload" ]; then
    printf '%s' "${rest%%\"*}" | sed 's/\\\//\//g; s/\\\\/\\/g'
  else
    printf '%s' "$PWD"
  fi
}

# The diff against HEAD, then each untracked file (first 20) against /dev/null.
# Paths are relative to $top. Exit 1 from `diff --no-index` is normal.
tree_diff() {
  git -C "$top" -c core.quotePath=false diff HEAD --no-color --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ 2>/dev/null
  printf '%s\n' "$status" | sed -n 's/^?? //p' | head -n 20 | while IFS= read -r f; do
    # A quoted name: drop the quotes when nothing inside is escaped, else skip it.
    case "$f" in
      *\\*) continue ;;
      '"'*'"') f=${f#\"}; f=${f%\"} ;;
    esac
    git -C "$top" -c core.quotePath=false diff --no-index --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- /dev/null "$f" 2>/dev/null
  done
}

# ,"tree":{...} for the work tree holding $1, or nothing (and status 1) outside one.
# The whole diff is capped at 256 KB (then "truncated":true).
tree_report() {
  GIT_OPTIONAL_LOCKS=0
  export GIT_OPTIONAL_LOCKS
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  # At most 2000 lines: a huge untracked tree must not push the envelope past the socket's 8 MB.
  status=$(git -C "$top" -c core.quotePath=false status --porcelain=v1 --untracked-files=all 2>/dev/null | head -n 2000) || return 1
  head_sha=$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)
  cap=262144
  diff=$(tree_diff | head -c $((cap + 1)))
  truncated=false
  if [ "$(printf '%s' "$diff" | wc -c)" -gt "$cap" ]; then
    truncated=true
    diff=$(printf '%s' "$diff" | head -c "$cap")
  fi
  printf ',"tree":{"root":"%s","head":"%s","status_b64":"%s","diff_b64":"%s","truncated":%s}' \
    "$(esc "$top")" "$head_sha" \
    "$(printf '%s' "$status" | /usr/bin/base64 | tr -d '\r\n')" \
    "$(printf '%s' "$diff" | /usr/bin/base64 | tr -d '\r\n')" \
    "$truncated"
}

# The tree report rides on a turn's start (the baseline) and on every Bash call.
tree=""
case "$kind" in
  user_prompt) want_tree=1 ;;
  post_tool)
    case "$payload" in
      *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) want_tree=1 ;;
      *) want_tree=0 ;;
    esac
    ;;
  *) want_tree=0 ;;
esac
if [ "$want_tree" -eq 1 ] && command -v git >/dev/null 2>&1; then
  tree=$(tree_report "$(payload_cwd)" 2>/dev/null) || tree=""
fi

id=$(uuidgen 2>/dev/null) || id=""
[ -n "$id" ] || id="$$-$(date +%s)"
ts=$(date +%s)
pid=${PPID:-0}
case "$pid" in ''|*[!0-9]*) pid=0 ;; esac

envelope=$(printf '{"v":1,"kind":"%s","id":"%s","term_program":"%s","term_bundle_id":"%s","pid":%s,"ts":%s,"payload":%s%s}' \
  "$kind" "$id" "$(esc "${TERM_PROGRAM:-}")" "$(esc "${__CFBundleIdentifier:-}")" "$pid" "$ts" "$payload" "$tree")

if [ "$blocking" -eq 0 ]; then
  printf '%s\n' "$envelope" | nc -U -w 1 "$sock" >/dev/null 2>&1
  exit 0
fi

# Blocking: wait up to 59 s for one reply line (299 s for a plan). The app answers
# "none" at 58 s (298 s for a plan), and Claude Code's own hook timeout is 305 s,
# so nothing is ever cut off mid-way.
wait=59
case "$payload" in
  *'"tool_name":"ExitPlanMode"'*|*'"tool_name": "ExitPlanMode"'*) wait=299 ;;
esac
reply=$(printf '%s\n' "$envelope" | nc -U -w "$wait" "$sock" 2>/dev/null | head -n 1)
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
