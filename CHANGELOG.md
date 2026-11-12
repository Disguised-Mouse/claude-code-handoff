# Changelog

## Unreleased

### Status bar
- The 7-day limit now nudges like the 5-hour one: `→ /handoff:notes` from `CLAUDE_HANDOFF_NUDGE_WEEK` (90, before: number only) and `notes now` from the new `CLAUDE_HANDOFF_NUDGE_WEEK_HARD` (95). Each reminder sits beside its own number. With both windows at their hard level the 5-hour number has no reminder and the 7-day number says `notes now!`.

## 0.6.7 — 2026-11-11

### Commands
- `/handoff:list`, `status`, `open` and a bare `load` are answered by a hooks module (`hooks/instant.ts`) that runs the scripts and opens the menu itself, so they cost no model turn. A pick queues `/handoff:load <n>` after the hook returns. When the module fails, the skills answer as before.
- `/handoff:list` menu: each option's label carries the age, project and next step, which the module's first menu dropped, and the title is no longer cut a second time. Numbers of 3 digits and titles with emoji are split correctly.
- `handoff-list.sh --all` lists every project, newest first, with a project column; `/handoff:list` uses it by default, and `/handoff:list here` or an empty `--all` result gives this project only. It includes this project's own folder and stops at the newest 30 rows.
- Loading another project's handoff shows the file without joining it, and says where to continue it; joining would split the thread, because this session's hooks write to their own project's folder.

### Handoff file
- Interrupts (`[Request interrupted by user]`) end the turn without counting as requests or turns. The reply cut off by the interrupt is recorded with a note that it was interrupted.
- Notices Claude Code writes itself (`<synthetic>` rows such as "No response requested.", "Login expired", usage-limit notices) are no longer taken as Claude's reply, also when they arrive as `last_assistant_message`.
- The last reply is no longer listed twice, as "Last reply" and as the newest earlier reply.
- Hooks file a session under the project it started in, not under every directory a `cd` took it to. `hook_cwd` reads only up to the first cwd of the transcript (4 ms on a 60 MB transcript instead of reading multi-MB lines on every Stop).

### Storage and install
- Skills find the session's project after a `cd` when `CLAUDE_HANDOFF_IN_PROJECT=false`, so `list` and `load` use the same folder.
- A trailing slash in `CLAUDE_HANDOFF_DIR` no longer makes the project's own sessions show as "not joined".
- `plugin.json` has no fixed version, so every merged commit installs as an update with `claude plugin update`. INTERNALS reads the status line path from `installed_plugins.json` instead of sorting the commit-named cache folders.

### Auto-notes
- A context threshold (or turn count) stays open until the notes request is sent. Before, a session's first Stop, before the async `save-handoff.sh` had written the file, used the threshold up without asking, which hit every long session already past 60% at install.

### Tests
- The test harness clears every `CLAUDE_HANDOFF_*` setting by prefix; settings exported from a Claude Code session broke 8 start and resume checks.

## 0.6.6 — 2026-11-08
- Auto-notes asks for the notes through `hookSpecificOutput.additionalContext` instead of `decision: "block"`. The turn continues the same way, with the same loop protections, but the terminal shows `Stop hook feedback` instead of `Stop hook error`.

## 0.6.5 — 2026-11-08
- The hooks module records the context window at the start of each main turn too, so the Stop hook ending the first turn after a `/model` switch uses the new model's window instead of the old one.
- `record-window.sh` does nothing in headless sessions, like the other hooks, and exits non-zero when it cannot write, so the module logs the failure and retries.
- `auto-notes.sh` checks the session id before reading the window file under it.

## 0.6.4 — 2026-11-08
- Auto-notes: the recorded context window lives in `${XDG_STATE_HOME:-~/.local/state}/claude-code-handoff/windows/<session id>` instead of the project's `.state/`. The hooks module took the project from the session's cwd and the Stop hook from the transcript's first cwd; where those resolved to different projects, auto-notes missed the file and fell back to the 200k/1M guess.

## 0.6.3 — 2026-11-07
- Auto-notes: `CLAUDE_HANDOFF_CONTEXT_WINDOW=auto` (the default) uses the model's real context window, which the hooks module records in `.state/<session>.window` after each turn (`scripts/record-window.sh`); a number still sets it by hand. Before, unset meant 200k until a request passed 200k, so on a 1M model the percentages were five times too high until then.
- INTERNALS: a status script of your own gets the nudges by piping into `statusline.sh`; `handoff-status.sh --short` has none.

## 0.6.2 — 2026-10-16
- Skills declare `allowed-tools` for their own scripts only, so `/handoff:list`, `load`, `status`, `open` and the path lookup of `notes` run without a permission prompt in the default mode. Writing the notes file still asks once: Claude Code treats `.claude/` as a protected directory and a skill cannot lift that.

## 0.6.1 — 2026-10-16
- Windows: `/handoff:open` opens the file with the default app in Git Bash (`cmd.exe /c start`) and WSL (`wslview` or `explorer.exe`); before, it only printed the path there. README: Windows confirmed in Git Bash (user report), jq install per OS, a check that jq is visible to the hooks.

## 0.6.0 — 2026-10-15
- Start screen: one line per session with title, age and the next action from its notes, or `● open`; no dates, ids or branch columns; untitled 0-turn sessions skipped; sessions ordered by their `updated_epoch`, not file mtime; the numbered list is written to `.state/<session>.index` once, so numbers stay valid; `new` keyword dropped, just type your task. One-line cache tip (`claude -r <id>` is cheaper), its window from the transcript's cache TTL (5 min or 1 h); a note when the newest file is on another branch; open marks older than 6 h without activity count as closed. Cold `--resume` / fork note made actionable (Ctrl+C, `claude`, the number).
- Status bar: short form `handoff ● <title> (+N) · ctx 41%`; `→ /handoff:notes` at 70% context or 80% of the 5-hour limit, `notes now` at 95%, 7-day limit shown from 90% (`CLAUDE_HANDOFF_NUDGE_LIMIT_HARD`, `_NUDGE_WEEK`); stdin session id wins over a stale environment.
- File: `- Next:` line in the header from the notes' next action; section order Notes, Last reply, Earlier replies, Requests, Files, Git, Compaction, Tokens; Tokens per session and total with input-equivalents and ≈ USD (`CLAUDE_HANDOFF_RATE_READ/_WRITE/_OUTPUT`, `_PRICE_PER_M`), calls sorted by time; auto-notes derives a 1M window when a request exceeded 200k.
- Robustness: a failed render or a lock timeout is audited and reported on stderr instead of a silent exit; the Stop hook writes nothing into a committed `.claude/handoffs/` and the start says so; one marker neutraliser shared by the shell and jq paths; the transcript flush wait stops early (1 s instead of 2.8 s on a 9 MB transcript); empty session ids rejected.
- Cost table corrected: the 25k system prefix is a warm read at every start, so a new session with the handoff costs ~38k input-equivalents, not 85k; break-even ~20k of history, not 40–50k. Rates named per model.
- Docs: README restructured for first-time readers; internals moved to `docs/INTERNALS.md`; images re-rendered from the current output.

## 0.5.1 — 2026-10-15
- `CLAUDE_HANDOFF_AUTO_NOTES=context`: notes updated by Claude when the context crosses 60% and 85% of the window, once per threshold, re-armed after compaction (`_AUTO_NOTES_AT`, `_CONTEXT_WINDOW`).
- Start hints name the thread by its title; the session id stays only inside the `claude -r` command.

## 0.5.0 — 2026-10-14
- Status bar: context percentage, and a `/handoff:notes` nudge at 70% context or 90% of the 5-hour limit (`CLAUDE_HANDOFF_NUDGE_CONTEXT`, `_NUDGE_LIMIT`). These fields reach only the status line, so this is zero tokens.
- `SessionStart` on `resume`: a one-line note with the cost of a cold resume, from the `prompt_cache_likely_expired` / `estimated_cache_write_usd` fields Claude Code passes; silent while the cache is warm.
- Start: injected context kept under the 10,000-character hook-output cap (`CLAUDE_HANDOFF_CONTEXT_CHARS`, blocks shrink to fit); branch-mismatch note when the newest handoff was written on another branch.
- Notes: `Done` / `In progress` instead of `State`; `Next action` must be a file:line or an exact command.

## 0.4.1 — 2026-10-14
- Notes are scrubbed for secrets in the rendered copy (the sidecar keeps the raw text); compaction sidecars written by older versions have their quoted markers neutralised on read.

## 0.4.0 — 2026-10-14
- Notes: markers count only as whole lines and the block ends at the first end marker; markers quoted in replies are neutralised; bloated blocks heal on the next render (#1). Notes live in `.state/<root>.notes.md`, the file shows a copy; `/handoff:notes` writes the sidecar (`handoff-path.sh --notes`) (#6).
- Deletes and renames touch only files named like a handoff and carrying the epoch marker; retention is skipped while other markdown files share the directory; `.frozen.md` and `.transcript` sidecars are never cleaned up (#2, #12).
- `/handoff:load` keeps a file that other sessions joined and moves those sessions along; `.state/audit.log` records every delete, rename and join (#3, #23).
- Numbers in the list are fixed at print time (`.state/<sid>.index`); the index shows the thread root id; ids and names match on the file name (#4, #5).
- Per-thread render lock; SessionEnd writes `.closed` so a late Stop does not re-open the session; no cache hint while a file is less than a minute old (#6, #7).
- Prompts with attachments (array content) are counted and shown (#8).
- scrub: `AWS_SECRET_ACCESS_KEY=`, `github_pat_`, `sk_live_`, `AIza…`, `glpat-`, JSON-quoted keys, credentials in URLs; the git section is scrubbed too (#9).
- Portability and hardening: quoted `${var//…}` replacements (bash 5.2 `&`), integer settings validated, `KEEP` raised to at least 5, the final reply passed through a file, control characters stripped from titles, ids validated before use in paths, `find -print0`, percent-encoded project slugs, physical paths for `.git/info/exclude`, headless detection scans 20 lines (#10, #13–#20).
- Skills resolve the project from the session's recorded cwd, not from the Bash tool's current directory (#11).
- Start context says which part is data and which is the instruction (#21). README: token estimate, statusline path without a version, Uninstall section; `save-handoff.sh --version`; `tests/run.sh` (#22, #23).

## 0.3.2 — 2026-10-14
- The start index is printed in the terminal (hook `systemMessage`, no tokens), so the number to type is visible; the handoff itself goes to Claude as `additionalContext`.

## 0.3.1 — 2026-10-14
- A bare number as the first message continues that thread from the start index (`new` starts fresh): no `/handoff:list`, no menu, no extra request.

## 0.3.0 — 2026-10-13
- Silent in `claude -p` / SDK sessions: no files, no context injected.
- Per-session open marks: a thread file stays 🟢 while any of its sessions is open.
- Snapshot of complete thread renders; appended as `## Archived history` when a transcript was deleted.
- Handoff directory added to the clone's `.git/info/exclude`.
- Status bar segment (`scripts/statusline.sh`), `/handoff:status`, `/handoff:open`.
- Start hint distinguishes "still open in another terminal" from "closed, cache warm".

## 0.2.x — 2026-10-13
- Threads: `/handoff:load` joins the chosen file instead of creating a new one; all sessions of a thread render into the root's file.
- Slash commands and the post-compaction continuation message are no longer counted as user requests.

## 0.1.x — 2026-10-13
- Per-session handoff files written by a `Stop` hook; compact autoload at `SessionStart`.
- Compaction summaries captured from `PostCompact`.
- Session index, warm-cache hint, secret redaction, retention, token accounting.
- `/handoff:list` with an arrow-key menu, `/handoff:load`, `/handoff:notes`.
- Final reply taken from the hook's `last_assistant_message` (fixes a race with the transcript).
