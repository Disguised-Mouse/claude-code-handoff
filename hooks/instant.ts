import type { EngineInterface, Register } from 'claude-code'

// A thrown hook is skipped by the engine, so on any script failure the skill answers instead.

const KEEP = 'Keep the current context'

export type Row = { n: string; label: string }

// handoff-list.sh prints `%-2s %s  age  [path  ]tail` with the title padded to 40, so the title is the
// 40 characters after the number and the other columns follow, split by 2+ spaces. ui.ask takes labels only, so
// the label carries every column.
export function parseRows(out: string): Row[] {
  return out
    .split('\n')
    .filter(line => /^\d+ /.test(line))
    .map(line => {
      // By code points, as the script pads; the number column grows past 2 digits.
      const n = line.match(/^\d+/)![0]
      const chars = [...line].slice(Math.max(2, n.length) + 1)
      const rest = chars.slice(40).join('').trim().split(/\s{2,}/)
      return { n, label: [`${n}. ${chars.slice(0, 40).join('').trim()}`, ...rest].join(' · ') }
    })
}

// The menu takes 2-4 options; with fewer than 4 sessions the last one keeps the current context.
export function menuOptions(rows: Row[]): string[] {
  return rows.length < 4 ? [...rows.map(r => r.label), KEEP] : rows.slice(0, 4).map(r => r.label)
}

// The session number of a menu answer: from a picked label, or the first number typed under Other.
export function pickedNumber(answer: string): string {
  return answer === KEEP ? '' : (answer.match(/\d+/)?.[0] ?? '')
}

// No project dir is passed: the scripts resolve it from this session's .cwd sidecar, as the
// /handoff:load skill that follows a pick does, so both read the same list.
async function script($: EngineInterface, name: string, args: string[]) {
  const r = await $.process.run([`${$.plugin.root}/scripts/${name}`, ...args], {
    env: { CLAUDE_CODE_SESSION_ID: await $.session.id() },
    stdin: '',
  })
  if (r.exitCode !== 0) throw new Error(`${name} exited ${r.exitCode}: ${r.stderr.trim()}`)
  return [r.stdout.trimEnd(), r.stderr.trimEnd()].filter(Boolean).join('\n')
}

// Shell hooks never receive the model's context window; auto-notes reads what this records.
let recorded = ''
async function record($: EngineInterface, w: number) {
  const key = `${await $.session.id()}:${w}`
  if (!(w > 0) || key === recorded) return
  recorded = key
  await script($, 'record-window.sh', [String(w)]).catch(err => {
    recorded = ''
    $.ui.log(`handoff: recording the context window failed: ${String(err)}`)
  })
}

async function listAndPick($: EngineInterface, here: boolean) {
  let out = here ? '' : await script($, 'handoff-list.sh', ['--all'])
  if (!out) out = await script($, 'handoff-list.sh', [])
  if (!out) return { text: 'No handoff exists yet.' }
  // The host prefixes the text with "handoff: ", which would push the first row out of its column.
  out = '\n' + out

  const rows = parseRows(out)
  let answer: string
  try {
    answer = await $.ui.ask(
      'Continue which session? Picking one makes this session continue in that file.' +
        (rows.length > 4 ? ' Type another number under Other.' : ''),
      { header: 'Handoff', options: menuOptions(rows) },
    )
  } catch (err) {
    // Esc denies the dialog with this wording (seen on 2.1.318); other failures are shown as such.
    const esc = /doesn't want to proceed/.test(String(err))
    return { text: `${out}\n\n${esc ? 'Menu closed.' : `Menu failed: ${String(err)}`}` }
  }
  const n = pickedNumber(answer)
  if (answer === KEEP) return { text: `${out}\n\nKept the current context.` }
  if (!n) return { text: `${out}\n\nNo session number in "${answer}": nothing loaded.` }
  // $.command.run is refused inside a hook the turn waits on: queue it after this hook returns.
  $.clock.after(50, () => {
    $.command.run({ command: 'handoff:load', args: n }).catch(err =>
      $.ui.log(`handoff: /handoff:load ${n} failed: ${String(err)}`),
    )
  })
  return { text: `${out}\n\nPicked ${n}: loading.` }
}

export const register: Register = on => {
  on('command.run', { command: 'handoff:list' }, async ($, e) => listAndPick($, e.args.trim() === 'here'))

  // With a number the skill loads the file into the model's context; without one, the menu.
  on('command.run', { command: 'handoff:load' }, async ($, e, next) =>
    e.args.trim() ? next(e) : listAndPick($, false),
  )

  on('command.run', { command: 'handoff:status' }, async $ => ({
    text: await script($, 'handoff-status.sh', [await $.session.id()]),
  }))

  on('command.run', { command: 'handoff:open' }, async $ => ({ text: await script($, 'handoff-open.sh', []) }))

  // At the start of each main turn, so the Stop hook ending that turn reads the window of the
  // model it ran on, a /model switch included; the measurement after the turn is the backstop.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) await record($, (await $.session.usage()).context.window)
    return next(e)
  })
  on('session.measure', async ($, e, next) => {
    await record($, e.context.window)
    return next(e)
  })
}
