#!/bin/sh
# notchcode-statusline.sh
#
# Claude Code's statusLine command. Claude Code hands the status line the only copy of the
# plan limits (rate_limits.five_hour / seven_day: used_percentage, resets_at in unix s),
# plus context_window, cost, model and session_id. This script:
#
#   1. forwards that JSON to the notchcode app as an envelope of kind "statusline", through
#      notchcode-hook.sh, in the background, at most once every 5 s per session;
#   2. runs the status line that was configured before notchcode (saved by connect in
#      ~/Library/Application Support/notchcode/statusline-chain.json as {"previous": {...}})
#      with the same stdin and prints exactly what it prints. With nothing chained it
#      prints nothing.
#
# A session's first stamp also deletes stamps older than 7 days, so the folder never grows.
#
# Rules: no dependencies beyond macOS base (sh, cat, stat, date, plutil, sed, tr, nc, find);
# never prints an error; always exits 0, including when the app is not running.

here=$(dirname "$0")
dir="$HOME/Library/Application Support/notchcode"
sock="${NOTCHCODE_SOCK:-$dir/notchcode.sock}"
chain="$dir/statusline-chain.json"

input=$(cat 2>/dev/null)

# 1. Forward, only when the app is listening, throttled per session with a stamp file.
if [ -S "$sock" ] && [ -n "$input" ]; then
  sid=$(printf '%s' "$input" | tr '\r\n' '  ' \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' 2>/dev/null)
  stamps="$dir/statusline-stamps"
  stamp="$stamps/${sid:-unknown}"
  now=$(date +%s 2>/dev/null)
  last=$(stat -f %m "$stamp" 2>/dev/null) || last=0
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge 5 ] || [ "$now" -lt "$last" ]; then
    if [ ! -e "$stamp" ]; then
      # A session's first status line: prune the stamps of sessions long gone.
      find "$stamps" -type f -mtime +7 -delete 2>/dev/null
    fi
    mkdir -p "$stamps" 2>/dev/null && : > "$stamp" 2>/dev/null
    # Detached: the status line is never slowed, and Claude Code cancelling this script
    # (it does when a newer update arrives) does not wait on the socket.
    ( printf '%s' "$input" | /bin/sh "$here/notchcode-hook.sh" statusline ) </dev/null >/dev/null 2>&1 &
  fi
fi

# 2. Chain to the previous status line, if one was saved. Never to ourselves.
prev=""
if [ -f "$chain" ]; then
  prev=$(plutil -extract previous.command raw -o - "$chain" 2>/dev/null) || prev=""
fi
case "$prev" in
  ''|*notchcode-statusline.sh*) ;;
  *) printf '%s' "$input" | /bin/sh -c "$prev" 2>/dev/null ;;
esac
exit 0
