#!/usr/bin/env bash
# Called by the hooks module after each turn: stores the context window of the session's model in
# .state/<sid8>.window, because shell hooks never receive it and auto-notes needs it.
# Usage: record-window.sh <session cwd> <window tokens>; the session from CLAUDE_CODE_SESSION_ID.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
sid="${CLAUDE_CODE_SESSION_ID:-}"
valid_sid "$sid" || exit 0
w="$(int_setting "${2:-}" 0)"
[ "$w" -gt 0 ] || exit 0
f="$(state_dir "$(handoff_dir "${1:-$PWD}")")/${sid:0:8}.window"
[ "$(cat "$f" 2>/dev/null)" = "$w" ] && exit 0
mkdir -p "$(dirname "$f")" && printf '%s' "$w" > "$f"
