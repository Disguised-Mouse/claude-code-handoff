#!/usr/bin/env bash
# Called by the hooks module after each turn: stores the context window of the session's model,
# because shell hooks never receive it and auto-notes needs it.
# Usage: record-window.sh <window tokens>; the session from CLAUDE_CODE_SESSION_ID.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
sid="${CLAUDE_CODE_SESSION_ID:-}"
valid_sid "$sid" || exit 0
w="$(int_setting "${1:-}" 0)"
[ "$w" -gt 0 ] || exit 0
f="$(window_file "$sid")"
[ "$(cat "$f" 2>/dev/null)" = "$w" ] && exit 0
mkdir -p "$(dirname "$f")" && printf '%s' "$w" > "$f"
# One small file per session: drop those of sessions untouched for 30 days.
find "$(dirname "$f")" -type f -mtime +30 -delete 2>/dev/null
exit 0
