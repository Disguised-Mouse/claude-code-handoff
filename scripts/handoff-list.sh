#!/usr/bin/env bash
# Prints the sessions of a project as a numbered list, newest first (by each file's own
# updated time), and remembers the order for this session (.state/<sid8>.index) so that
# handoff-show.sh <number> picks the same file even if another session writes in between.
# Columns: number, title, age, then "● open" or the next step from the notes; the branch only
# when it differs from the current one.
#   --all   every project under ~/.claude/handoffs (CLAUDE_HANDOFF_IN_PROJECT=false), with a
#           project column; the numbers still work with handoff-show.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
loc="$(utf8_locale)"; [ -n "$loc" ] && export LC_ALL="$loc"
all=0; [ "${1:-}" = "--all" ] && { all=1; shift; }
cwd="$(skill_project_dir "${1:-}")"
dir="$(handoff_dir "$cwd")"
now="$(date +%s)"
sid="$(current_session_id)"
cbr="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ "$all" = 1 ]; then
  # This project's own folder too: it lives elsewhere unless CLAUDE_HANDOFF_IN_PROJECT=false.
  # shortcut: newest 30 rows (each costs ~15 processes); raise when a menu needs more.
  files="$({ printf '%s\n' "$dir"; all_project_dirs; } | awk '!seen[$0]++' | { ds=(); while IFS= read -r d; do ds+=("$d"); done; session_files "${ds[@]}"; } | head -n 30)"
else
  files="$(session_files "$dir")"
fi
if [ -n "$sid" ] && mkdir -p "$(state_dir "$dir")" 2>/dev/null; then
  printf '%s\n' "$files" | sed '/^$/d' > "$(state_dir "$dir")/${sid:0:8}.index"
fi
pad() { local t="${1:0:$2}"; printf '%s' "$t"; printf '%*s' $(($2 - ${#t})) ''; }
i=0
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  i=$((i + 1))
  title="$(file_title "$f")"
  turns="$(header_field "$f" 'User turns')"; case "$turns" in ''|*[!0-9]*) turns=0 ;; esac
  [ "$title" = "untitled" ] && title="untitled ($turns turns)"
  root="$(root_of_file "$f")"; fd="$(dirname "$f")"
  ep="$(epoch_of "$f")"; age="?"
  [ -n "$ep" ] && [ "$ep" -gt 0 ] 2>/dev/null && age="$(age_text $((now - ep)))"
  tail_col=""
  if [ -n "$root" ] && [ -n "$(open_members "$fd" "$root")" ]; then tail_col="● open"
  else nx=""; [ -n "$root" ] && nx="$(next_of_notes "$fd" "$root" "$f")"; [ -n "$nx" ] && tail_col="next: $nx"; fi
  br="$(header_field "$f" Branch | clean_text)"
  [ "$fd" = "$dir" ] && [ -n "$br" ] && [ -n "$cbr" ] && [ "$br" != "$cbr" ] && tail_col="${tail_col:+$tail_col · }branch $br"
  pc=""
  if [ "$all" = 1 ]; then
    if [ "$fd" = "$dir" ]; then p="$cwd"; else p="$(slug_path "$(basename "$fd")" | clean_text)"; fi
    case "$p" in "$HOME"|"$HOME"/*) p="~${p#"$HOME"}" ;; esac
    pc="$(pad "$p" 24)  "
  fi
  printf '%-2s %s  %s  %s%s\n' "$i" "$(pad "$title" 40)" "$(pad "$age" 7)" "$pc" "$tail_col" | sed 's/[[:space:]]*$//'
done
