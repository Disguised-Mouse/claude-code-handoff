import { expect, mock, test } from 'claude-code/testing'

import { menuOptions, parseRows, pickedNumber } from '../hooks/instant'

// A row as handoff-list.sh prints it: `%-2s %s  %s  %s`, title padded to 40, age to 7.
const row = (n: number, title: string, rest = '~  ● open') =>
  `${String(n).padEnd(2)} ${title.padEnd(40)}  ${'0 min'.padEnd(7)}  ${rest}`
const LIST = [row(1, 'Cswap concurrent account sessions'), row(2, 'Control-model  step 3 build')].join('\n')

test('rows, menu options and the picked number', () => {
  const rows = parseRows(`Continue a session?\n${LIST}\n`)
  expect(rows.map(r => r.n)).toEqual(['1', '2'])
  expect(rows[1]?.label).toBe('2. Control-model  step 3 build · 0 min · ~ · ● open')
  expect(menuOptions(rows)).toEqual([
    '1. Cswap concurrent account sessions · 0 min · ~ · ● open',
    '2. Control-model  step 3 build · 0 min · ~ · ● open',
    'Keep the current context',
  ])
  const twelve = parseRows(Array.from({ length: 12 }, (_, i) => row(i + 1, `T${i + 1}`)).join('\n'))
  expect(twelve.map(r => r.n).slice(-3)).toEqual(['10', '11', '12'])
  expect(twelve[11]?.label).toBe('12. T12 · 0 min · ~ · ● open')
  expect(menuOptions(twelve)).toHaveLength(4)
  expect(pickedNumber('2. Control-model step 3 build')).toBe('2')
  expect(pickedNumber('load 3')).toBe('3')
  expect(pickedNumber('Keep the current context')).toBe('')
  expect(pickedNumber('the second one')).toBe('')
})

// The engine beneath the plugin: the scripts and the session, answered as the engine would.
function engine(on: Parameters<Parameters<typeof test>[1]>[1], answer: string | Error, exitCode = 0) {
  const ran: { argv: string[]; stdin?: string }[] = []
  on('session.id', () => ({ value: 'cdc086f0-1336-4b20-9c94-ef8c922e65d4' }))
  on('process.run', (_, e) => {
    ran.push({ argv: e.argv.slice(1), stdin: e.init?.stdin })
    if (exitCode) return { value: { exitCode, stdout: '', stderr: 'jq missing' } }
    const out = e.argv[0]?.endsWith('handoff-list.sh') ? LIST : 'File: x.md'
    return { value: { exitCode: 0, stdout: out + '\n', stderr: '' } }
  })
  // $.ui.ask runs as a tool call of AskUserQuestion; Esc denies it.
  on('tool.call', (_, e) =>
    answer instanceof Error
      ? { deny: answer.message }
      : { result: { questions: e.questions, answers: { [e.questions[0].question]: answer } } },
  )
  return ran
}

test('/handoff:list keeps the context; scripts get no project dir and an empty stdin', async ($, on) => {
  const ran = engine(on, 'Keep the current context')
  const r = await $.command.run({ command: 'handoff:list', args: '' })
  expect(r.text).toContain('Kept the current context.')
  expect(ran[0]).toEqual({ argv: ['--all'], stdin: '' })
})

test('/handoff:list with Esc', async ($, on) => {
  const ran = engine(on, new Error("The user doesn't want to proceed with this tool use."))
  const r = await $.command.run({ command: 'handoff:list', args: 'here' })
  expect(r.text).toContain('Menu closed.')
  expect(ran[0]?.argv).toEqual([])
})

test('/handoff:list: another menu failure is not taken for Esc', async ($, on) => {
  engine(on, new Error('promise rejected: dialog unavailable'))
  const r = await $.command.run({ command: 'handoff:list', args: '' })
  expect(r.text).toContain('Menu failed:')
})

test('/handoff:list: text without a number under Other loads nothing', async ($, on) => {
  engine(on, 'the second one')
  const r = await $.command.run({ command: 'handoff:list', args: '' })
  expect(r.text).toContain('No session number in "the second one"')
})

test('/handoff:list pick queues the load after the hook returns', async ($, on) => {
  engine(on, 'load 2')
  const clock = mock.clock(on)
  const loads: string[] = []
  on('command.run', { command: 'handoff:load' }, (_, e) => {
    loads.push(e.args)
    return { text: 'loaded' }
  })
  const r = await $.command.run({ command: 'handoff:list', args: '' })
  expect(r.text).toContain('Picked 2: loading.')
  expect(loads).toEqual([])
  await clock.advance(100)
  expect(loads).toEqual(['2'])
})

test('/handoff:load with a number goes to the skill, without one to the menu', async ($, on) => {
  engine(on, 'Keep the current context')
  on('command.run', { command: 'handoff:load' }, () => ({ text: 'skill ran' }))
  expect((await $.command.run({ command: 'handoff:load', args: '3' })).text).toBe('skill ran')
  expect((await $.command.run({ command: 'handoff:load', args: '' })).text).toContain('Kept the current context.')
})

test('/handoff:status passes the session id', async ($, on) => {
  const ran = engine(on, '')
  await $.command.run({ command: 'handoff:status', args: '' })
  expect(ran[0]?.argv).toEqual(['cdc086f0-1336-4b20-9c94-ef8c922e65d4'])
})

// The test's own command.run hooks stand for the skills beneath the module.
for (const [why, setup] of [
  ['cannot start', (on: Parameters<typeof engine>[0]) => {
    const ran: string[] = []
    on('session.id', () => ({ value: 'x' }))
    on('process.run', () => (ran.push('tried'), Promise.reject(new Error('cannot start'))))
    return ran
  }],
  ['exits non-zero', (on: Parameters<typeof engine>[0]) => engine(on, '', 1)],
] as const) {
  test(`a script that ${why} leaves the command to the skill`, async ($, on) => {
    const ran = setup(on)
    on('command.run', { command: 'handoff:list' }, () => ({ text: 'skill ran' }))
    const r = await $.command.run({ command: 'handoff:list', args: '' })
    expect(ran.length).toBeGreaterThan(0)
    expect(r.text).toBe('skill ran')
  })
}

test('a measurement records the context window once per session and window', async ($, on) => {
  const ran = engine(on, '')
  on('session.measure', () => ({ changed: [] }))
  const measure = (window: number) => $.session.measure({ context: { window }, rateLimits: [], changed: [] } as never)
  await measure(1000000)
  await measure(1000000)
  await measure(200000)
  expect(ran.map(r => r.argv)).toEqual([['1000000'], ['200000']])
})

test('a main turn records the window before it runs; a subagent turn does not', async ($, on) => {
  const ran = engine(on, '')
  let window = 1000000
  on('session.usage', () => ({ value: { context: { window } } as never }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  await $.turn.start({ text: 'q', turnId: 't1' })
  window = 200000
  await $.turn.start({ text: '', turnId: 't2', agentId: 'sub' })
  await $.turn.start({ text: 'q', turnId: 't3' })
  expect(ran.map(r => r.argv)).toEqual([['1000000'], ['200000']])
})
