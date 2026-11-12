# Internals

How the plugin works, for people who want to read the code or wire it by hand. Everyday use is in the [README](../README.md).

## Events

| Event | Script | What happens |
|---|---|---|
| `Stop` (every reply, async) | `scripts/save-handoff.sh` | Waits for the transcript to flush (up to 2 s, stops early once the last row is not a user row or the file stops growing), takes the final reply from the hook's `last_assistant_message`, renders every session of the thread from their transcripts under a per-thread lock, copies the notes from `.state/<root>.notes.md`, writes the file atomically, copies `LATEST.md`, applies retention, records the open mark. Every delete, rename or join is logged in `.state/audit.log`; a failed render or a lock timeout is logged too and reported on stderr. |
| `PostCompact` | `scripts/save-compact.sh` | Stores `compact_summary` under `.state/<session>.compact.md` (wrapper tags stripped, inner headings demoted) and refreshes the file. |
| `SessionStart` (`startup`, `clear`, `resume`, `fork`) | `scripts/load-handoff.sh` | Returns JSON: `additionalContext` for Claude (the compact handoff of the newest thread, the numbered list, one instruction) and `systemMessage` for the terminal (the list, the cache tip, the branch note). On `resume` and `fork` only a cost note, and only when Claude Code reports the cache as expired. Writes the numbered list to `.state/<session>.index` once, so the numbers stay valid even if other sessions write meanwhile. |
| `SessionEnd` | `scripts/mark-closed.sh` | Removes the open mark, writes `.state/<session>.closed`; status follows the remaining sessions. |
| `Stop` with `CLAUDE_HANDOFF_AUTO_NOTES` | `scripts/auto-notes.sh` | Keeps Claude going for one more step to rewrite the notes, through `hookSpecificOutput.additionalContext`, which Claude Code shows as `Stop hook feedback`, not as a hook error: at 60% and 85% of the context window (`context`) or every N turns. The window is `CLAUDE_HANDOFF_CONTEXT_WINDOW` when it is a number; with `auto` (the default) it is the one the hooks module recorded for the session, and before that file exists, 200k or 1M depending on the largest request in the transcript. |
| `turn.start` of a main turn, and `session.measure` after it (hooks module) | `scripts/record-window.sh` | Writes the context window of the session's model, read before the turn runs so the Stop hook ending it sees a `/model` switch, to `${XDG_STATE_HOME:-~/.local/state}/claude-code-handoff/windows/<session id>` when it changes, outside every project so the module and the Stop hook need not resolve the project alike; files untouched for 30 days are deleted. Skipped in headless sessions; a failed write exits non-zero, so the module logs it and retries on the next turn. Shell hooks never receive the window; only the status line and hooks modules do. |
| Skills | `skills/*/SKILL.md` | `list`, `load`, `notes`, `status`, `open`. Read-only and write split: `status`, `list` and `handoff-path.sh` only read; `handoff-show.sh --adopt` (list, load) joins the thread and writes `.state/`; `open` launches the system opener; `notes` writes the sidecar through Claude's Write tool. Each skill's `allowed-tools` names exactly its scripts. Scripts find the current session through `CLAUDE_CODE_SESSION_ID`, which Claude Code sets for every shell it starts, and the project through the `.cwd` sidecar the Stop hook writes. |

Hook output is capped by Claude Code at 10,000 characters per field; the start context stays under `CLAUDE_HANDOFF_CONTEXT_CHARS` (9,500) by shrinking its blocks.

## State

Next to the files, in `.state/`:

| File | Holds |
|---|---|
| `<root>.notes.md` | the notes, source of truth; the block in the handoff file is a copy |
| `<root>.members`, `<session>.adopt` | thread membership: who joined whom |
| `<session>.transcript`, `<session>.cwd` | where the session's transcript and project are |
| `<session>.open`, `<session>.closed` | open mark while the session runs (stale after 6 h without activity), close time |
| `<session>.compact.md` | every compaction summary of the session |
| `<root>.frozen.md` | snapshot of the last complete render of a thread, for the day a transcript is deleted |
| `<session>.index` | the numbered list as it was printed at that session's start |
| `<session>.auto-notes` | the last auto-notes threshold reached |
| `audit.log` | every delete, rename, join, failed render, lock timeout (trimmed past 2,000 lines) |

## Threads

A thread is a root session plus the sessions that joined it with `/handoff:load` (or a number at start). The writer renders all their transcripts, in order, into the root's file, so two open sessions of one thread keep the same file. The file keeps the root's title. A session that joins a thread drops its own file, because its history is in the thread now; if other sessions had joined that file, it stays and they move to the new thread too.

## Headless runs

`claude -p …` and SDK sessions are new sessions every time. The hooks detect them (`CLAUDE_CODE_SESSION_ATTENDED=0`, `CLAUDE_CODE_ENTRYPOINT=sdk-*`, or the transcript's own `entrypoint`) and do nothing. `CLAUDE_HANDOFF_HEADLESS=true` turns them on there too.

## Tracked directory guard

If `.claude/handoffs/` is committed in the repository (someone added it on purpose, or `git add -A` caught it), the Stop hook writes nothing there and the start message says so. A committed handoff would be injected into every teammate's session, like a committed CLAUDE.md, but out of sight. Remove the directory from git, or set `CLAUDE_HANDOFF_IN_PROJECT=false`.

## Status bar

`scripts/statusline.sh` reads Claude Code's status-line JSON and prints one segment:

```
handoff ● Rate limiter with Redis fallback (+1) · ctx 41%
handoff ● Rate limiter with Redis fallback (+1) · ctx 72% → /handoff:notes · 5h 83% → /handoff:notes
handoff ○ after first reply · ctx 2%
```

`(+N)` is the number of other sessions in the thread. The context percentage and the 5-hour / 7-day usage percentages never reach shell hooks, so the status line is where the plugin warns without spending a token. Thresholds: `CLAUDE_HANDOFF_NUDGE_CONTEXT` 70, `_NUDGE_LIMIT` 80, `_NUDGE_LIMIT_HARD` 95 ("notes now"), `_NUDGE_WEEK` 90 (7-day number shown, `→ /handoff:notes`), `_NUDGE_WEEK_HARD` 95 ("notes now"); `0` disables one. Each usage reminder sits beside its own number. With both windows at their hard level the 5-hour number has no reminder and the 7-day number says "notes now!".

Use it as the status line:

```json
{ "statusLine": { "type": "command", "command": "\"$(jq -r '.plugins[\"handoff@claude-code-handoff\"][0].installPath' ~/.claude/plugins/installed_plugins.json)/scripts/statusline.sh\"" } }
```

The path comes from Claude Code's install record: cache folders are named after the plugin's commit, which do not sort by age, and older folders can stay in the cache.

If you already have a status script, pipe the same JSON into `statusline.sh` from it and print the result as one more line. `handoff-status.sh --short` prints the title segment alone, without the context percentage and without the nudges; a script that shows those numbers itself can add the nudges from the `CLAUDE_HANDOFF_NUDGE_*` settings.

## Token accounting

The `## Tokens` section is computed from the `usage` of every API response in the thread's transcripts, one request counted once (`unique_by(requestId)`, then sorted by time). Input-equivalents = `RATE_WRITE`×cold + `RATE_READ`×warm + input + `RATE_OUTPUT`×output, defaults 2 / 0.025 / 5 (Claude Fable 5.1); USD = equivalents × `CLAUDE_HANDOFF_PRICE_PER_M` (10) per million. These are API prices; a subscription draws usage on every request for the whole context, with a weighting Anthropic does not publish.
