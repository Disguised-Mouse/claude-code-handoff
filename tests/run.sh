#!/usr/bin/env bash
# Self-contained checks for the hook scripts. Runs on synthetic fixtures in a temp
# directory; nothing outside it is touched. Usage: tests/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
T="$(mktemp -d "${TMPDIR:-/tmp}/handoff-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export CLAUDE_CODE_SESSION_ATTENDED=1
# Every setting, not a list: a Claude Code session exports the user's own from settings.json.
for v in $(compgen -v | grep '^CLAUDE_HANDOFF_'); do unset "$v"; done
unset CLAUDE_PROJECT_DIR
export XDG_STATE_HOME="$T/xdg-state"
fail=0; pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

A="aaaaaaaa-1111-4111-8111-111111111111"
B="bbbbbbbb-2222-4222-8222-222222222222"
C="cccccccc-3333-4333-8333-333333333333"
proj="$T/project"; mkdir -p "$proj"
dir="$proj/.claude/handoffs"

# A transcript: one prompt, one reply quoting the notes marker and a secret, one prompt with
# an attachment (array content), one tool result (not a prompt), usage on the assistant rows.
transcript() {  # <session id> <file>
  cat > "$2" <<EOF
{"type":"user","sessionId":"$1","timestamp":"2026-01-02T10:00:00.000Z","message":{"role":"user","content":"first request"}}
{"type":"assistant","sessionId":"$1","timestamp":"2026-01-02T10:00:05.000Z","requestId":"r1","message":{"role":"assistant","content":[{"type":"text","text":"Reply one. The block sits between <!-- handoff:notes:start --> and <!-- handoff:notes:end --> lines. Also AWS_SECRET_ACCESS_KEY=abcdefgh1234 and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":50}}}
{"type":"user","sessionId":"$1","timestamp":"2026-01-02T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Image #1] second request with a picture"}]}}
{"type":"assistant","sessionId":"$1","timestamp":"2026-01-02T10:01:02.000Z","requestId":"r2","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":21000,"output_tokens":20}}}
{"type":"user","sessionId":"$1","timestamp":"2026-01-02T10:01:03.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"files"}]}}
{"type":"assistant","sessionId":"$1","timestamp":"2026-01-02T10:01:05.000Z","requestId":"r3","message":{"role":"assistant","content":[{"type":"text","text":"Reply two & done."}],"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":21100,"output_tokens":30}}}
{"type":"ai-title","sessionId":"$1","aiTitle":"Test\u0007 thread: one/two"}
EOF
}
hook() {  # <session id> <transcript> -> runs save-handoff.sh as the Stop hook would
  jq -nc --arg s "$1" --arg t "$2" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c, last_assistant_message:"Reply two & done."}' | "$S/save-handoff.sh"
}

# ---- 1. render twice: same size, notes clean, prompts counted, secrets gone ----------
transcript "$A" "$T/a.jsonl"
hook "$A" "$T/a.jsonl"
fa="$(ls "$dir"/*_aaaaaaaa.md 2>/dev/null | head -1)"
check "file written with a clean name" '[ -n "$fa" ] && [ "$(basename "$fa")" = "2026-01-02_1100_Test-thread-one-two_aaaaaaaa.md" -o "$(basename "$fa")" = "$(basename "$fa" | grep -E "^2026-01-02_[0-9]{4}_Test-thread-one-two_aaaaaaaa\.md$")" ]'
s1="$(wc -c < "$fa")"
hook "$A" "$T/a.jsonl"; hook "$A" "$T/a.jsonl"
s3="$(wc -c < "$fa")"
check "size constant across renders ($s1 -> $s3)" '[ "$s1" = "$s3" ]'
check "exactly one start marker" '[ "$(grep -c "^<!-- handoff:notes:start -->$" "$fa")" = 1 ]'
check "quoted marker neutralised" 'grep -q "handoff‑notes:start" "$fa"'
check "notes still the placeholder" 'grep -q "^_No notes yet" "$fa"'
# Notes sidecar: secrets scrubbed in the rendered copy, a marker line inside the notes is harmless,
# and an old compaction sidecar quoting the markers does not reopen the block.
printf '%s\n' "**Goal**: t. password=hunter2 and AWS_SECRET_ACCESS_KEY=abcdef1234567890" "<!-- handoff:notes:start -->" "more" > "$dir/.state/aaaaaaaa.notes.md"
printf '%s\n' "### 2026-01-02 11:30 (auto)" "quote: <!-- handoff:notes:start -->" "<!-- handoff:notes:end -->" "tail" > "$dir/.state/aaaaaaaa.compact.md"
hook "$A" "$T/a.jsonl"
check "notes: secret value scrubbed in the file" '! grep -q "hunter2" "$fa" && ! grep -q "abcdef1234567890" "$fa"'
check "notes: sidecar keeps the raw text" 'grep -q "hunter2" "$dir/.state/aaaaaaaa.notes.md"'
check "notes: still exactly one start marker with a marker in notes and compaction" '[ "$(grep -c "^<!-- handoff:notes:start -->$" "$fa")" = 1 ]'
check "notes: the goal line survives" 'grep -q "Goal\*\*: t\." "$fa"'
rm -f "$dir/.state/aaaaaaaa.notes.md" "$dir/.state/aaaaaaaa.compact.md"
# Status line nudges and the cold-resume note (fields only the status line / a resume start receive).
sl="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, context_window:{used_percentage:72.4}, rate_limits:{five_hour:{used_percentage:91}}}' | "$S/statusline.sh")"
check "statusline: context percentage shown" 'printf "%s" "$sl" | grep -q "ctx 72%"'
check "statusline: notes nudge at 70% context" 'printf "%s" "$sl" | grep -q "ctx 72% → /handoff:notes"'
check "statusline: soft nudge at 91% of the 5-hour limit" 'printf "%s" "$sl" | grep -q "5h 91% → /handoff:notes"'
check "statusline: title, no path" 'printf "%s" "$sl" | grep -q "^handoff ● Test thread: one/two" && ! printf "%s" "$sl" | grep -q "$dir"'
sl="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, rate_limits:{five_hour:{used_percentage:96}, seven_day:{used_percentage:92}}}' | "$S/statusline.sh")"
check "statusline: hard nudge at 96% and the 7-day limit" 'printf "%s" "$sl" | grep -q "5h 96% → notes now · 7d 92%"'
sl="$(CLAUDE_CODE_SESSION_ID="$B" jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c}' | CLAUDE_CODE_SESSION_ID="$B" "$S/statusline.sh")"
check "statusline: stdin session id wins over a stale environment" 'printf "%s" "$sl" | grep -q "Test thread"'
sl="$(jq -nc --arg c "$proj" '{session_id:"99999999-9999-4999-8999-999999999999", cwd:$c}' | "$S/statusline.sh")"
check "statusline: no file yet" '[ "$sl" = "handoff ○ after first reply" ]'
sl="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, context_window:{used_percentage:12}}' | "$S/statusline.sh")"
check "statusline: no nudge at 12%" '! printf "%s" "$sl" | grep -q "/handoff:notes"'
rs="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, source:"resume", prompt_cache_likely_expired:true, context_tokens:232000, estimated_cache_write_usd:"4.64", seconds_since_last_response:5400}' | "$S/load-handoff.sh")"
check "resume: cold-resume note, no context injected" 'printf "%s" "$rs" | jq -e ".systemMessage | test(\"cold\") and test(\"232k\") and test(\"Ctrl\\\\+C\")" >/dev/null && ! printf "%s" "$rs" | jq -e ".hookSpecificOutput" >/dev/null 2>&1'
rs="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, source:"fork", prompt_cache_likely_expired:true, context_tokens:150000.5, estimated_cache_write_usd:3}' | "$S/load-handoff.sh")"
check "resume: float context_tokens does not break the note" 'printf "%s" "$rs" | jq -e ".systemMessage | test(\"150k\")" >/dev/null'
rs="$(jq -nc --arg s "$A" --arg c "$proj" '{session_id:$s, cwd:$c, source:"resume", prompt_cache_likely_expired:false}' | "$S/load-handoff.sh")"
check "resume: silent while the cache is warm" '[ -z "$rs" ]'
# Auto-notes by context: fires once at 60%, again at 85%, re-arms after compaction.
ctxt() { printf '%s\n' '{"type":"user","sessionId":"'"$A"'","timestamp":"2026-01-02T10:00:00.000Z","message":{"role":"user","content":"q"}}' \
  '{"type":"assistant","sessionId":"'"$A"'","timestamp":"2026-01-02T10:00:05.000Z","requestId":"r9","message":{"role":"assistant","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":'"$1"',"output_tokens":5}}}' > "$T/ctx.jsonl"; }
an() { jq -nc --arg s "$A" --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context CLAUDE_HANDOFF_CONTEXT_WINDOW=200000 "$S/auto-notes.sh"; }
rm -f "$dir/.state/aaaaaaaa.auto-notes"
ctxt 50000;  check "auto-notes: quiet at 25%" '[ -z "$(an)" ]'
ctxt 130000; check "auto-notes: fires at 65%" 'an | jq -e ".hookSpecificOutput.hookEventName == \"Stop\" and (has(\"decision\") | not)" >/dev/null'
ctxt 140000; check "auto-notes: not again at 70%" '[ -z "$(an)" ]'
ctxt 175000; check "auto-notes: fires at 87%" 'an | jq -e ".hookSpecificOutput.additionalContext | test(\"87%\")" >/dev/null'
ctxt 30000;  check "auto-notes: re-armed below 60% after compaction" '[ -z "$(an)" ] && [ "$(cat "$dir/.state/aaaaaaaa.auto-notes")" = 0 ]'
ctxt 125000; check "auto-notes: fires again at 62%" 'an | jq -e ".hookSpecificOutput.hookEventName == \"Stop\" and (has(\"decision\") | not)" >/dev/null'
rm -f "$dir/.state/aaaaaaaa.auto-notes"
# First Stop of a session: the async writer has not made its file yet; the threshold stays open.
G="99999999-7777-4777-8777-777777777777"
ag="$(jq -nc --arg s "$G" --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context CLAUDE_HANDOFF_CONTEXT_WINDOW=200000 "$S/auto-notes.sh")"
check "auto-notes: no file yet -> quiet, threshold not used up" '[ -z "$ag" ] && [ ! -f "$dir/.state/99999999.auto-notes" ]'
# Window derived from the transcript: a request above 200k means the 1M window.
ctxt 300000; an1="$(jq -nc --arg s "$A" --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context "$S/auto-notes.sh")"
check "auto-notes: 300k request implies the 1M window (30%, quiet)" '[ -z "$an1" ]'
ctxt 700000; an1="$(jq -nc --arg s "$A" --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context "$S/auto-notes.sh")"
check "auto-notes: 700k of 1M fires at 70%" 'printf "%s" "$an1" | jq -e ".hookSpecificOutput.additionalContext | test(\"70%\")" >/dev/null'
rm -f "$dir/.state/aaaaaaaa.auto-notes"
# Window recorded by the hooks module: used with auto, a number in the setting wins over it.
wf="$XDG_STATE_HOME/claude-code-handoff/windows/$A"
(cd "$T" && CLAUDE_CODE_SESSION_ID="$A" "$S/record-window.sh" 1000000)
check "record-window: written by session id, wherever it runs" '[ "$(cat "$wf")" = 1000000 ]'
CLAUDE_CODE_SESSION_ID="$A" "$S/record-window.sh" "1M"
CLAUDE_CODE_SESSION_ID="not-a-session" "$S/record-window.sh" 5
check "record-window: bad window or session id ignored" '[ "$(cat "$wf")" = 1000000 ] && [ "$(ls "$XDG_STATE_HOME/claude-code-handoff/windows" | wc -l)" = 1 ]'
CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_SESSION_ID="$C" "$S/record-window.sh" 1000000
check "record-window: headless session writes nothing" '[ ! -f "$XDG_STATE_HOME/claude-code-handoff/windows/$C" ]'
mkdir -p "$T/ro" && chmod 500 "$T/ro"
rw_rc=0; XDG_STATE_HOME="$T/ro" CLAUDE_CODE_SESSION_ID="$A" "$S/record-window.sh" 1000000 2>/dev/null || rw_rc=$?
chmod 700 "$T/ro"
check "record-window: unwritable state dir exits non-zero" '[ "$rw_rc" -ne 0 ]'
anw() { jq -nc --arg s "$A" --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context CLAUDE_HANDOFF_AUTO_NOTES_AT=25,40 CLAUDE_HANDOFF_CONTEXT_WINDOW="$1" "$S/auto-notes.sh"; }
ctxt 150000; check "auto-notes: auto uses the recorded 1M window (15%, quiet)" '[ -z "$(anw auto)" ]'
ctxt 260000; check "auto-notes: auto fires at 26% of the recorded window" 'anw auto | jq -e ".hookSpecificOutput.additionalContext | test(\"26%\")" >/dev/null'
rm -f "$dir/.state/aaaaaaaa.auto-notes"
mkdir -p "$XDG_STATE_HOME/claude-code-handoff" && printf '1000000' > "$XDG_STATE_HOME/claude-code-handoff/bad"
ctxt 150000; anb="$(jq -nc --arg t "$T/ctx.jsonl" --arg c "$proj" '{session_id:"../bad", transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_AUTO_NOTES=context CLAUDE_HANDOFF_AUTO_NOTES_AT=25,40 "$S/auto-notes.sh" 2>/dev/null)"
check "auto-notes: an invalid session id is not used as a path" '[ "$(cat "$XDG_STATE_HOME/claude-code-handoff/bad")" = 1000000 ] && ! printf "%s" "$anb" | grep -q "15%"'
rm -f "$XDG_STATE_HOME/claude-code-handoff/bad"
ctxt 150000; check "auto-notes: a number overrides the recorded window (75%)" 'anw 200000 | jq -e ".hookSpecificOutput.additionalContext | test(\"75%\")" >/dev/null'
rm -f "$dir/.state/aaaaaaaa.auto-notes" "$wf" "$T/ctx.jsonl"
check "User turns counts the array prompt" 'grep -q "^- User turns: 2$" "$fa"'
check "array prompt text shown" 'grep -q "second request with a picture" "$fa"'
check "AWS secret redacted" '! grep -q "abcdefgh1234" "$fa"'
check "github token redacted" '! grep -q "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "$fa"'
check "ampersand survives the substitution" 'grep -q "Reply two & done" "$fa"'
check "last reply not repeated under earlier replies (hook copy equals the transcript's)" '[ "$(grep -c "Reply two & done" "$fa")" = 1 ]'
check "cwd sidecar written" '[ "$(cat "$dir/.state/aaaaaaaa.cwd")" = "$proj" ]'

# ---- 2. notes sidecar is the source of truth ----------------------------------------
printf '**Goal**: test notes\n<!-- handoff:notes:start -->\n**Next**: keep going\n' > "$dir/.state/aaaaaaaa.notes.md"
hook "$A" "$T/a.jsonl"
check "notes from the sidecar rendered" 'grep -q "^\*\*Goal\*\*: test notes$" "$fa" && grep -q "^\*\*Next\*\*: keep going$" "$fa"'
check "marker pasted into the sidecar dropped" '[ "$(grep -c "^<!-- handoff:notes:start -->$" "$fa")" = 1 ]'
sn1="$(wc -c < "$fa")"; hook "$A" "$T/a.jsonl"
check "size constant with notes" '[ "$sn1" = "$(wc -c < "$fa")" ] && [ "$(grep -c "^\*\*Goal\*\*: test notes" "$fa")" = 1 ]'

# ---- 3. a bloated block from an older version heals and seeds the sidecar -------------
transcript "$B" "$T/b.jsonl"
hook "$B" "$T/b.jsonl"
fb="$(ls "$dir"/*_bbbbbbbb.md | head -1)"
rm -f "$dir/.state/bbbbbbbb.notes.md"
# simulate the old bug: the block runs into the body
awk -v s="<!-- handoff:notes:start -->" '
  $0 == "<!-- handoff:notes:end -->" && !done { print "**Goal**: real notes"; print "## Last reply from Claude"; print "> junk " s; done = 1; next } { print }' "$fb" > "$fb.tmp" && mv "$fb.tmp" "$fb"
hook "$B" "$T/b.jsonl"
check "healed notes keep the real line" '[ "$(cat "$dir/.state/bbbbbbbb.notes.md")" = "**Goal**: real notes" ]'
check "healed file has one block" '[ "$(grep -c "^<!-- handoff:notes:start -->$" "$fb")" = 1 ] && ! grep -q "> junk" "$fb"'

# ---- 4. retention touches only handoff files, and nothing in a shared directory -------
export CLAUDE_HANDOFF_KEEP=5
for i in 1 2 3 4 5 6 7; do
  printf '# Handoff: old %s\n\n- Session: `%s`\n<!-- handoff:updated_epoch:1 -->\n\n## Notes\n' "$i" "dddddd0$i-4444-4444-8444-444444444444" > "$dir/2026-01-01_000${i}_old_dddddd0${i}.md"
  touch -t "20260101000$i" "$dir/2026-01-01_000${i}_old_dddddd0${i}.md"
done
printf '# my notes\n' > "$dir/README.md"; touch -t 202501010000 "$dir/README.md"
hook "$A" "$T/a.jsonl"
check "shared directory: nothing deleted" '[ "$(ls "$dir"/2026-01-01_*_old_*.md | wc -l | tr -d " ")" = 7 ] && [ -f "$dir/README.md" ]'
check "shared directory: skip logged" 'grep -q "retention-skipped" "$dir/.state/audit.log"'
rm -f "$dir/README.md"
printf '# Handoff: fake\n' > "$dir/2026-01-01_0000_nomarker_eeeeeeee.md"; touch -t 202501010000 "$dir/2026-01-01_0000_nomarker_eeeeeeee.md"
hook "$A" "$T/a.jsonl"
check "retention keeps a file without the epoch marker (shared dir again)" '[ -f "$dir/2026-01-01_0000_nomarker_eeeeeeee.md" ]'
rm -f "$dir/2026-01-01_0000_nomarker_eeeeeeee.md"
hook "$A" "$T/a.jsonl"
n_old="$(ls "$dir"/2026-01-01_*_old_*.md 2>/dev/null | wc -l | tr -d ' ')"
check "retention keeps 5 newest handoff files (old left: $n_old)" '[ "$n_old" = 3 ] && [ -f "$fa" ] && [ -f "$fb" ]'
check "retention logged" 'grep -q "retention-rm" "$dir/.state/audit.log"'
unset CLAUDE_HANDOFF_KEEP
check "LATEST.md kept" '[ -f "$dir/LATEST.md" ]'

# ---- 5. --adopt: numbers from the saved index; a root with members is kept ------------
export CLAUDE_CODE_SESSION_ID="$C"
transcript "$C" "$T/c.jsonl"; hook "$C" "$T/c.jsonl"
fc="$(ls "$dir"/*_cccccccc.md | head -1)"
"$S/handoff-list.sh" "$proj" > "$T/list.txt"
check "list: number, title, age columns" 'grep -Eq "^1  Test thread: one/two +[0-9]+ (min|h|d)" "$T/list.txt"'
check "list: no ids, no file names" '! grep -q "aaaaaaaa" "$T/list.txt"'
check "index saved for the session, one line per file" '[ "$(wc -l < "$dir/.state/cccccccc.index" | tr -d " ")" = "$(ls "$dir"/*.md | grep -vc LATEST)" ] && [ "$(sort -u "$dir/.state/cccccccc.index" | wc -l | tr -d " ")" = "$(wc -l < "$dir/.state/cccccccc.index" | tr -d " ")" ]'
nA="$(grep -n "_aaaaaaaa.md" "$dir/.state/cccccccc.index" | cut -d: -f1 | head -1)"
touch "$fb"   # another session writes: the order changes, the number must not
out="$("$S/handoff-show.sh" --adopt "$nA" "$proj" 2>"$T/err.txt")"
check "adopt by number joins the file the list showed" 'grep -q "joined thread aaaaaaaa" "$T/err.txt"'
check "own single-session file removed and logged" '[ ! -f "$fc" ] && grep -q "adopt-rm" "$dir/.state/audit.log"'
check "member recorded" 'grep -q "^$C$" "$dir/.state/aaaaaaaa.members"'
# C is now in A. Make B a member of C's old id? Instead: A (root with member C) adopts B: must keep A's file.
export CLAUDE_CODE_SESSION_ID="$A"
rm -f "$dir/.state/aaaaaaaa.index"
"$S/handoff-show.sh" --adopt "bbbbbbbb" "$proj" >/dev/null 2>"$T/err2.txt"
check "root with members: file kept" '[ -f "$fa" ] && grep -q "kept" "$T/err2.txt" && grep -q "adopt-keep" "$dir/.state/audit.log"'
[ "$fail" = 0 ] || { echo "--- err2:"; cat "$T/err2.txt"; echo "--- audit:"; cat "$dir/.state/audit.log"; ls "$dir" "$dir/.state"; }
check "members follow into the new thread" 'grep -q "^$C$" "$dir/.state/bbbbbbbb.members" && [ "$(cat "$dir/.state/cccccccc.adopt")" = "$B" ]'
unset CLAUDE_CODE_SESSION_ID

# ---- 6. closed mark beats a late Stop ------------------------------------------------
jq -nc --arg s "$B" --arg c "$proj" '{session_id:$s, cwd:$c}' | "$S/mark-closed.sh"
check "closed mark written" '[ -s "$dir/.state/bbbbbbbb.closed" ]'
printf '%s' "$(( $(date +%s) + 5 ))" > "$dir/.state/bbbbbbbb.closed"   # SessionEnd after this Stop started
hook "$B" "$T/b.jsonl"
check "late Stop does not re-open" '[ ! -f "$dir/.state/bbbbbbbb.open" ] && ! grep "^- Status:" "$fb" | grep -q bbbbbbbb'

# ---- 7. settings validation, ids, lock ----------------------------------------------
CLAUDE_HANDOFF_MAX_PROMPTS="abc" hook "$A" "$T/a.jsonl"
check "non-integer setting falls back (file still written)" '[ "$(find "$fa" -newer "$T/list.txt" | wc -l | tr -d " ")" = 1 ]'
printf 'zz/../..' > "$dir/.state/aaaaaaaa.adopt"
. "$S/lib.sh"
check "invalid adopt id ignored" '[ "$(thread_root "$dir" "$A")" = "$A" ]'
rm -f "$dir/.state/aaaaaaaa.adopt"
mkdir -p "$dir/.state/aaaaaaaa.lock"; date +%s > "$dir/.state/aaaaaaaa.lock/t"
check "fresh lock blocks (times out)" '! take_lock "$dir" "$A"'
printf '1' > "$dir/.state/aaaaaaaa.lock/t"
check "stale lock is taken over" 'take_lock "$dir" "$A" && release_lock "$dir" "$A"'
check "--version prints a version" '"$S/save-handoff.sh" --version | grep -Eq "^([0-9]+\.[0-9]+|[0-9a-f]{7,40}|dev)$"'
# No version field: Claude Code names the install folder after the commit; that is the version.
mkdir -p "$T/cache/0123456789ab/.claude-plugin" && cp -R "$S" "$T/cache/0123456789ab/scripts" && printf '{"name":"handoff"}\n' > "$T/cache/0123456789ab/.claude-plugin/plugin.json"
check "--version without a version field: the commit folder name" '[ "$("$T/cache/0123456789ab/scripts/save-handoff.sh" --version)" = 0123456789ab ]'
check "project slug percent-encodes" '[ "$(project_slug "/a b/c-d")" = "a%20b%2Fc-d" ]'

# ---- 8. start screen, index once, ordering by epoch ----------------------------------
# Untangle the threads of section 5: A and C become plain single-session roots again.
rm -f "$dir/.state/cccccccc.adopt" "$dir/.state/aaaaaaaa.adopt" "$dir/.state/aaaaaaaa.members" "$dir/.state/bbbbbbbb.members" "$dir/.state/cccccccc.open"
transcript "$C" "$T/c2.jsonl"; hook "$C" "$T/c2.jsonl"
printf '**Goal**: ship it\n**Next action**: open `main.go:42`, run `go test ./...`\n' > "$dir/.state/aaaaaaaa.notes.md"
hook "$A" "$T/a.jsonl"
check "file header carries the Next line" 'grep -q "^- Next: open main.go:42, run go test ./...$" "$fa"'
check "section order: Notes, Last reply first; Tokens last" '[ "$(grep "^## " "$fa" | sed -n "1p;2p" | tr "\n" "|")" = "## Notes (written by /handoff:notes)|## Last reply from Claude|" ] && [ "$(grep "^## " "$fa" | tail -1)" = "## Tokens" ]'
check "tokens table has equivalents and USD" 'grep -q "Input-equivalents" "$fa" && grep -Eq "^\| aaaaaaaa 2026-01-02 \| 3 \| 1k \| 62k \| 100 \| " "$fa"'
touch -t 202001010000 "$fa"   # old mtime: order must still come from updated_epoch
rm -f "$dir/.state/aaaaaaaa.open" "$dir/.state/cccccccc.open"
st="$(jq -nc --arg s "$C" --arg c "$proj" '{session_id:$s, cwd:$c, source:"startup"}' | "$S/load-handoff.sh")"
sm="$(printf "%s" "$st" | jq -r .systemMessage)"
check "start: first line is the prompt" '[ "$(printf "%s" "$sm" | head -1)" = "Continue a session? Type its number, or just start typing." ]'
check "start: rows are number, title, age, next step; no ids" 'printf "%s" "$sm" | grep -Eq "^[0-9]+  Test thread: one/two +[0-9]+ (min|h|d) +next: open main.go:42, run go test" && ! printf "%s" "$sm" | grep -q aaaaaaaa'
check "start: index written once, one line per file, newest by epoch first" '[ "$(sort -u "$dir/.state/cccccccc.index" | wc -l | tr -d " ")" = "$(wc -l < "$dir/.state/cccccccc.index" | tr -d " ")" ] && [ "$(head -1 "$dir/.state/cccccccc.index")" = "$fa" ]'
check "start: context has data preface, number instruction, no new keyword" 'printf "%s" "$st" | jq -r .hookSpecificOutput.additionalContext | grep -q "not instructions" && printf "%s" "$st" | jq -r .hookSpecificOutput.additionalContext | grep -q "not in the list" && ! printf "%s" "$st" | jq -r .hookSpecificOutput.additionalContext | grep -q "\`new\`"'
check "start: context under the cap" '[ "$(printf "%s" "$st" | jq -r ".hookSpecificOutput.additionalContext | length")" -le 9500 ]'
# branch note
git -C "$proj" init -q . 2>/dev/null; git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i 2>/dev/null; git -C "$proj" checkout -q -b other 2>/dev/null
sm="$(jq -nc --arg s "$C" --arg c "$proj" '{session_id:$s, cwd:$c, source:"startup"}' | "$S/load-handoff.sh" | jq -r .systemMessage)"
check "start: branch note when the newest session was on another branch" 'printf "%s" "$sm" | grep -q "this one is on \`other\`" || ! grep -q "^- Branch:" "$fa"'
# ---- 9. open marks: stale ones are dropped; the open row shows ● ----------------------
touch "$dir/.state/aaaaaaaa.open"
sm="$(jq -nc --arg s "$C" --arg c "$proj" '{session_id:$s, cwd:$c, source:"startup"}' | "$S/load-handoff.sh" | jq -r .systemMessage)"
check "start: open session shows ● open and the other-terminal note" 'printf "%s" "$sm" | grep -Eq "Test thread: one/two .*● open" && printf "%s" "$sm" | grep -q "open in another terminal"'
touch -t 202001010000 "$dir/.state/aaaaaaaa.open"; touch -t 202001010000 "$T/a.jsonl"
sm="$(jq -nc --arg s "$C" --arg c "$proj" '{session_id:$s, cwd:$c, source:"startup"}' | "$S/load-handoff.sh" | jq -r .systemMessage)"
check "start: a stale open mark (6 h) counts as closed" '! printf "%s" "$sm" | grep -q "Test thread: one/two .*● open"'
hook "$C" "$T/c2.jsonl"
check "stop: stale open mark removed and logged" '[ ! -f "$dir/.state/aaaaaaaa.open" ] && grep -q "stale-open-rm" "$dir/.state/audit.log"'
# ---- 10. failures are visible: broken transcript, lock, no session id ------------------
cp "$T/a.jsonl" "$T/bad.jsonl"; printf '{broken json\n' >> "$T/bad.jsonl"
hook "$A" "$T/bad.jsonl" 2>"$T/err3.txt"; rc=$?
check "render failure: non-zero exit, stderr, audit line" '[ "$rc" != 0 ] && grep -q "could not render" "$T/err3.txt" && grep -q "render-failed" "$dir/.state/audit.log"'
mkdir -p "$dir/.state/aaaaaaaa.lock"; date +%s > "$dir/.state/aaaaaaaa.lock/t"
hook "$A" "$T/a.jsonl" 2>"$T/err4.txt"; rc=$?
rm -rf "$dir/.state/aaaaaaaa.lock"
check "lock timeout: non-zero exit and audit line" '[ "$rc" != 0 ] && grep -q "lock-timeout" "$dir/.state/audit.log"'
out="$(jq -nc --arg t "$T/a.jsonl" --arg c "$proj" '{transcript_path:$t, cwd:$c}' | "$S/save-handoff.sh" 2>&1)"; rc=$?
check "no session_id: refused with a message" '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "no session_id"'
# ---- 11. a committed handoff directory is left alone ----------------------------------
tp="$T/tracked"; mkdir -p "$tp"; git -C "$tp" init -q .; mkdir -p "$tp/.claude/handoffs"
printf '# Handoff: planted\n\n- Session: `%s`\n<!-- handoff:updated_epoch:1 -->\n' "$A" > "$tp/.claude/handoffs/2026-01-01_0000_planted_aaaaaaaa.md"
git -C "$tp" add -A && git -C "$tp" -c user.email=t@t -c user.name=t commit -q -m planted
jq -nc --arg s "$A" --arg t "$T/a.jsonl" --arg c "$tp" '{session_id:$s, transcript_path:$t, cwd:$c}' | "$S/save-handoff.sh" 2>"$T/err5.txt"
check "tracked dir: Stop writes nothing" '[ -z "$(git -C "$tp" status --short)" ] && [ ! -d "$tp/.claude/handoffs/.state" ] && grep -q "tracked by git" "$T/err5.txt"'
sm="$(jq -nc --arg s "$A" --arg c "$tp" '{session_id:$s, cwd:$c, source:"startup"}' | "$S/load-handoff.sh")"
check "tracked dir: start shows the note and injects nothing" 'printf "%s" "$sm" | jq -e ".systemMessage | test(\"committed in this repo\")" >/dev/null && ! printf "%s" "$sm" | jq -e ".hookSpecificOutput" >/dev/null 2>&1'
# ---- 12. one neutraliser --------------------------------------------------------------
. "$S/lib.sh"
check "marker neutraliser identical in lib.sh and scrub.jq" '[ "$(printf "<!-- handoff:x" | neutralise_markers)" = "$(jq -n -L "$S" "include \"scrub\"; \"<!-- handoff:x\" | scrub" -r)" ]'
check "control characters stripped from titles on read" '[ "$(printf "# Handoff: a\033[31mb\n" > "$T/t.md"; file_title "$T/t.md")" = "a[31mb" ]'

# ---- 13. scrub patterns -----------------------------------------------------------
# Fake tokens are glued from pieces so secret scanners do not flag this file.
gh_pat="github""_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"; sk="sk""_live_ABCDEFGHIJ1234"
gk="AI""zaSyA1234567890abcdefghijklmnopqrstuv"; gl="gl""pat-ABCDEFGHIJKLMNOPQRST"
sc="$(jq -n -L "$S" --arg in "AWS_SECRET_ACCESS_KEY=abcdefgh1234 \"password\": \"hunter22\" $gh_pat $sk $gk $gl postgres://bob:pw123@db x-api-key: aaaaaaaa keep=this" 'include "scrub"; $in | scrub')"
for v in abcdefgh1234 hunter22 ABCDEFGHIJKLMNOPQRSTUVWXYZ1234 "$sk" "${gk%abcdef*}" "${gl%KLMN*}" bob:pw123 "x-api-key: aaaaaaaa"; do
  check "scrub hides '$v'" '! printf "%s" "$sc" | grep -qF "$v"'
done
check "scrub keeps ordinary text" 'printf "%s" "$sc" | grep -qF "keep=this"'

# ---- 14. open: the opener matches the platform, the path is always printed ------------
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho MINGW64_NT-10.0\n' > "$T/bin/uname"
printf '#!/usr/bin/env bash\nprintf "W:%%s\\n" "$2"\n' > "$T/bin/cygpath"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/opened"\n' "$T" > "$T/bin/cmd.exe"
chmod +x "$T/bin/"*
out="$(CLAUDE_CODE_SESSION_ID="$A" PATH="$T/bin:$PATH" "$S/handoff-open.sh" "$proj" 2>/dev/null)"
check "open on Git Bash: cmd.exe start with the converted path; path printed" '[ "$out" = "$fa" ] && grep -q "^/c start " "$T/opened" && grep -qF "W:$fa" "$T/opened"'
printf '#!/usr/bin/env bash\necho Linux\n' > "$T/bin/uname"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/opened"\n' "$T" > "$T/bin/xdg-open"
chmod +x "$T/bin/"*; rm -f "$T/opened"
out="$(CLAUDE_CODE_SESSION_ID="$A" PATH="$T/bin:$PATH" "$S/handoff-open.sh" "$proj" 2>/dev/null)"
check "open on Linux: xdg-open with the path; path printed" '[ "$out" = "$fa" ] && [ "$(cat "$T/opened")" = "$fa" ]'
rm -f "$T/bin/xdg-open" "$T/opened"
out="$(CLAUDE_CODE_SESSION_ID="$A" PATH="$T/bin:$PATH" "$S/handoff-open.sh" "$proj" 2>/dev/null)"
check "open without an opener: only prints the path, exit 0" '[ "$out" = "$fa" ] && [ ! -f "$T/opened" ]'

# ---- 15. interrupts: the marker ends the turn but is no request; the cut-off reply says so --
I="dddddddd-4444-4444-8444-444444444444"
cat > "$T/i.jsonl" <<EOF
{"type":"user","sessionId":"$I","timestamp":"2026-01-03T10:00:00.000Z","message":{"role":"user","content":"start the job"}}
{"type":"assistant","sessionId":"$I","timestamp":"2026-01-03T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Half-way answer"}]}}
{"type":"user","sessionId":"$I","timestamp":"2026-01-03T10:00:06.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
{"type":"user","sessionId":"$I","timestamp":"2026-01-03T10:00:07.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
{"type":"assistant","sessionId":"$I","timestamp":"2026-01-03T10:00:08.000Z","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}
{"type":"user","sessionId":"$I","timestamp":"2026-01-03T10:01:00.000Z","message":{"role":"user","content":"do it differently"}}
{"type":"assistant","sessionId":"$I","timestamp":"2026-01-03T10:01:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Finished answer"}]}}
EOF
jq -nc --arg s "$I" --arg t "$T/i.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c, last_assistant_message:"Finished answer"}' | "$S/save-handoff.sh"
fi_="$(ls "$dir"/*_dddddddd.md 2>/dev/null | head -1)"
check "interrupt: markers are not counted as turns" 'grep -q "^- User turns: 2$" "$fi_"'
check "interrupt: markers are not listed as requests" '! grep -q "Request interrupted" "$fi_"'
check "interrupt: cut-off reply marked once" '[ "$(grep -o "interrupted by user before finishing" "$fi_" | wc -l | tr -d " ")" = 1 ] && grep -q "before finishing)\* Half-way answer" "$fi_"'
check "interrupt: finished reply unmarked" 'section "$fi_" "Last reply from Claude" | grep -q "Finished answer" && ! section "$fi_" "Last reply from Claude" | grep -q interrupted'
check "synthetic notice is no reply" '! grep -q "No response requested" "$fi_"'
jq -nc --arg s "$I" --arg t "$T/i.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c, last_assistant_message:"No response requested."}' | "$S/save-handoff.sh"
check "synthetic notice as last_assistant_message is no reply either" '! grep -q "No response requested" "$fi_" && section "$fi_" "Last reply from Claude" | grep -q "Finished answer"'

# ---- 16. list --all: every project under ~/.claude/handoffs, newest first, project column --
H="$T/home"; P1="$H/p1"; P2="$H/two words"; mkdir -p "$P1" "$P2"
E="eeeeeeee-5555-4555-8555-555555555555"; F="ffffffff-6666-4666-8666-666666666666"
transcript "$E" "$T/e.jsonl"
transcript "$F" "$T/f.jsonl"; sed -i.bak 's/2026-01-02T/2026-01-05T/' "$T/f.jsonl"
for x in "$E $T/e.jsonl $P1" "$F $T/f.jsonl $P2"; do
  set -- $x; s="$1"; t="$2"; shift 2
  jq -nc --arg s "$s" --arg t "$t" --arg c "$*" '{session_id:$s, transcript_path:$t, cwd:$c}' | HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false "$S/save-handoff.sh"
done
la="$(HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-list.sh" --all "$P1")"
check "list --all: both projects, newest first, with project paths" '[ "$(printf "%s\n" "$la" | wc -l | tr -d " ")" = 2 ] && printf "%s\n" "$la" | head -1 | grep -q "~/two words" && printf "%s\n" "$la" | tail -1 | grep -q "~/p1"'
lh="$(HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-list.sh" "$P1")"
check "list without --all: this project only, no project column" '[ "$(printf "%s\n" "$lh" | wc -l | tr -d " ")" = 1 ] && ! printf "%s" "$lh" | grep -q "~/"'
HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-list.sh" --all "$P1" >/dev/null
so="$(HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-show.sh" --adopt 1 "$P1" 2>&1)"
own="$(ls "$dir"/*.md | grep -vc LATEST.md)"
lo="$(HOME="$H" CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-list.sh" --all "$proj")"
check "list --all, handoffs inside the project: own sessions listed with the leftover folders" '[ "$(printf "%s\n" "$lo" | wc -l | tr -d " ")" = "$((own + 2))" ]'
check "show --adopt of another project: shown, not joined" 'printf "%s" "$so" | grep -q "not joined: .*project $P2" && printf "%s" "$so" | grep -q "^Handoff file: .*_ffffffff.md" && ! ls "$H/.claude/handoffs/"*/.state/eeeeeeee.adopt >/dev/null 2>&1'

# ---- 17. project = where the session started, not where the Bash tool last cd-ed ---------
K="12121212-8888-4888-8888-888888888888"
mkdir -p "$proj/sub"
printf '%s\n' '{"type":"user","sessionId":"'"$K"'","cwd":"'"$proj"'","timestamp":"2026-01-06T10:00:00.000Z","message":{"role":"user","content":"start here"}}' \
  '{"type":"assistant","sessionId":"'"$K"'","cwd":"'"$proj/sub"'","timestamp":"2026-01-06T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"moved"}]}}' > "$T/k.jsonl"
jq -nc --arg s "$K" --arg t "$T/k.jsonl" --arg c "$proj/sub" '{session_id:$s, transcript_path:$t, cwd:$c}' | "$S/save-handoff.sh"
check "hook cwd: file in the start project, none in the cd target" 'ls "$dir"/*_12121212.md >/dev/null 2>&1 && [ ! -d "$proj/sub/.claude/handoffs" ]'

# ---- 18. CLAUDE_HANDOFF_DIR with a trailing slash: own sessions still join ---------------
M="34343434-9999-4999-8999-999999999999"; N="56565656-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
transcript "$M" "$T/m.jsonl"
jq -nc --arg s "$M" --arg t "$T/m.jsonl" --arg c "$proj" '{session_id:$s, transcript_path:$t, cwd:$c}' | CLAUDE_HANDOFF_DIR="$T/hd/" "$S/save-handoff.sh"
sm="$(CLAUDE_HANDOFF_DIR="$T/hd/" CLAUDE_CODE_SESSION_ID="$N" "$S/handoff-show.sh" --adopt 1 "$proj" 2>&1)"
check "trailing slash in CLAUDE_HANDOFF_DIR: adopt joins" '! printf "%s" "$sm" | grep -q "not joined" && [ "$(cat "$T/hd/.state/56565656.adopt")" = "$M" ]'

# ---- 19. IN_PROJECT=false, skill run after a cd: the session's start project, no stray folder --
mkdir -p "$H/elsewhere"; before="$(ls "$H/.claude/handoffs" | wc -l | tr -d " ")"
(cd "$H/elsewhere" && HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-list.sh" >/dev/null)
sc="$(cd "$H/elsewhere" && HOME="$H" CLAUDE_HANDOFF_IN_PROJECT=false CLAUDE_CODE_SESSION_ID="$E" "$S/handoff-path.sh")"
check "central storage after cd: skills find the start project, no new folder" '[ "$(ls "$H/.claude/handoffs" | wc -l | tr -d " ")" = "$before" ] && printf "%s" "$sc" | grep -q "_eeeeeeee.md"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
