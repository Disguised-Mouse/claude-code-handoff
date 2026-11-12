#!/usr/bin/env bash
# Status-bar segment: reads Claude Code's statusLine JSON on stdin, prints one line:
#   handoff ● <title> · ctx 41%                    normal
#   handoff ● <title> · ctx 72% → /handoff:notes   context high: write notes before compaction
#   … · 5h 83% → /handoff:notes | · 5h 96% → notes now | · 7d 91% → /handoff:notes | · 7d 96% → notes now
#   both windows at their hard level: · 5h 96% · 7d 96% → notes now!
#   handoff ○ after first reply                     no file yet
# The percentages reach only the status line (never hooks), so this is the one place the
# plugin can warn without spending a token.
#   CLAUDE_HANDOFF_NUDGE_CONTEXT     context % from which notes are suggested (70; 0 = off)
#   CLAUDE_HANDOFF_NUDGE_LIMIT       5-hour usage % from which they are suggested (80; 0 = off)
#   CLAUDE_HANDOFF_NUDGE_LIMIT_HARD  5-hour usage % from which it says "notes now" (95)
#   CLAUDE_HANDOFF_NUDGE_WEEK        7-day usage % from which it is shown and suggested (90; 0 = off)
#   CLAUDE_HANDOFF_NUDGE_WEEK_HARD   7-day usage % from which it says "notes now" (95)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'handoff: jq missing\n'; exit 0; }
input=""; [ -t 0 ] || input="$(cat)"
line="$(printf '%s' "$input" | "$HERE/handoff-status.sh" --short "$@")"
nc="$(int_setting "${CLAUDE_HANDOFF_NUDGE_CONTEXT:-}" 70)"
nl="$(int_setting "${CLAUDE_HANDOFF_NUDGE_LIMIT:-}" 80)"
nh="$(int_setting "${CLAUDE_HANDOFF_NUDGE_LIMIT_HARD:-}" 95)"
nw="$(int_setting "${CLAUDE_HANDOFF_NUDGE_WEEK:-}" 90)"
nwh="$(int_setting "${CLAUDE_HANDOFF_NUDGE_WEEK_HARD:-}" 95)"
ctx="$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty | floor' 2>/dev/null)"
lim="$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty | floor' 2>/dev/null)"
wk="$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty | floor' 2>/dev/null)"
extra=""
if [ -n "$ctx" ]; then
  extra="$extra · ctx ${ctx}%"
  [ "$nc" -gt 0 ] && [ "$ctx" -ge "$nc" ] && extra="$extra → /handoff:notes"
fi
# Both windows at their hard level: one stronger message, beside the 7-day number.
both=0
[ -n "$lim" ] && [ -n "$wk" ] && [ "$nl" -gt 0 ] && [ "$nh" -gt 0 ] && [ "$nw" -gt 0 ] && [ "$nwh" -gt 0 ] \
  && [ "$lim" -ge "$nh" ] && [ "$wk" -ge "$nwh" ] && both=1
if [ -n "$lim" ] && [ "$nl" -gt 0 ] && [ "$lim" -ge "$nl" ]; then
  extra="$extra · 5h ${lim}%"
  if [ "$both" = 1 ]; then :
  elif [ "$nh" -gt 0 ] && [ "$lim" -ge "$nh" ]; then extra="$extra → notes now"
  else extra="$extra → /handoff:notes"; fi
fi
if [ -n "$wk" ] && [ "$nw" -gt 0 ] && [ "$wk" -ge "$nw" ]; then
  extra="$extra · 7d ${wk}%"
  if [ "$both" = 1 ]; then extra="$extra → notes now!"
  elif [ "$nwh" -gt 0 ] && [ "$wk" -ge "$nwh" ]; then extra="$extra → notes now"
  else extra="$extra → /handoff:notes"; fi
fi
printf '%s%s\n' "$line" "$extra"
