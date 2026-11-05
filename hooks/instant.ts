import type { EngineInterface, Register } from 'claude-code'

// Answers /handoff:list, /handoff:status, /handoff:open and a bare /handoff:load from the
// scripts, with no model turn. A failed hook is skipped, so the skills answer instead.

const KEEP = 'Keep the current context'

export type Row = { n: string; label: string; detail: string }

// A list row: number, title, age, then optional project and status, columns split by 2+ spaces.
export function parseRows(out: string): Row[] {
  return out
    .split('\n')
    .map(line => line.trim().split(/\s{2,}/))
    .filter(cols => /^\d+$/.test(cols[0] ?? ''))
    .map(([n = '', title = '', ...rest]) => ({
      n,
      label: `${n}. ${title}`.slice(0, 40),
      detail: rest.join(' · '),
    }))
}

// The menu takes 2-4 options; with fewer than 4 sessions the last one keeps the current context.
export function menuOptions(rows: Row[]): string[] {
  return rows.length < 4 ? [...rows.map(r => r.label), KEEP] : rows.slice(0, 4).map(r => r.label)
}

// The session number of a menu answer: a picked label or a number typed under Other.
export function pickedNumber(answer: string): string {
  return answer === KEEP ? '' : (answer.match(/^\s*(\d+)/)?.[1] ?? '')
}

async function script($: EngineInterface, name: string, args: string[]) {
  const r = await $.process.run([`${$.plugin.root}/scripts/${name}`, ...args], {
    env: { CLAUDE_CODE_SESSION_ID: await $.session.id() },
  })
  return { out: r.stdout.trimEnd(), err: r.stderr.trimEnd() }
}

async function listAndPick($: EngineInterface, here: boolean) {
  const root = await $.session.root()
  let out = here ? '' : (await script($, 'handoff-list.sh', ['--all', root])).out
  if (!out) out = (await script($, 'handoff-list.sh', [root])).out
  if (!out) return { text: 'No handoff exists yet.' }

  const rows = parseRows(out)
  let answer: string
  try {
    answer = await $.ui.ask(
      'Continue which session? Picking one makes this session continue in that file.' +
        (rows.length > 4 ? ' Type another number under Other.' : ''),
      { header: 'Handoff', options: menuOptions(rows) },
    )
  } catch (err) {
    // Esc rejects the dialog; any other failure is shown so it is not mistaken for Esc.
    const esc = /rejected|doesn't want to proceed/.test(String(err))
    return { text: `${out}\n\n${esc ? 'Menu closed.' : `Menu failed: ${String(err)}`}` }
  }
  const n = pickedNumber(answer)
  if (!n) return { text: `${out}\n\nKept the current context.` }
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

  on('command.run', { command: 'handoff:status' }, async $ => {
    const r = await script($, 'handoff-status.sh', [await $.session.id(), await $.session.root()])
    return { text: [r.out, r.err].filter(Boolean).join('\n') }
  })

  on('command.run', { command: 'handoff:open' }, async $ => {
    const r = await script($, 'handoff-open.sh', [await $.session.root()])
    return { text: [r.out, r.err].filter(Boolean).join('\n') }
  })
}
