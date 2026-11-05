import { expect, mock, test } from 'claude-code/testing'

import { menuOptions, parseRows, pickedNumber } from '../hooks/instant'

const LIST = [
  '1  Cswap concurrent account sessions         0 min    ~                         ● open',
  '2  Control-model step 3 build                6 min    ~                         next: merge 3.4',
].join('\n')

test('rows, menu options and the picked number', () => {
  const rows = parseRows(`Continue a session?\n${LIST}\n`)
  expect(rows.map(r => r.n)).toEqual(['1', '2'])
  expect(rows[1]?.label).toBe('2. Control-model step 3 build')
  expect(rows[1]?.detail).toBe('6 min · ~ · next: merge 3.4')
  expect(menuOptions(rows)).toEqual([
    '1. Cswap concurrent account sessions',
    '2. Control-model step 3 build',
    'Keep the current context',
  ])
  const five = parseRows([1, 2, 3, 4, 5].map(n => `${n}  T${n}  1 min`).join('\n'))
  expect(menuOptions(five)).toHaveLength(4)
  expect(pickedNumber('2. Control-model step 3 build')).toBe('2')
  expect(pickedNumber(' 7')).toBe('7')
  expect(pickedNumber('Keep the current context')).toBe('')
  expect(pickedNumber('the second one')).toBe('')
})

// The engine beneath the plugin: the scripts and the session, answered as the engine would.
function engine(on: Parameters<Parameters<typeof test>[1]>[1], answer: string | Error) {
  const ran: string[][] = []
  on('session.id', () => ({ value: 'cdc086f0-1336-4b20-9c94-ef8c922e65d4' }))
  on('session.root', () => ({ value: '/home/me' }))
  on('process.run', (_, e) => {
    ran.push([...e.argv])
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

test('/handoff:list keeps the context', async ($, on) => {
  const ran = engine(on, 'Keep the current context')
  const r = await $.command.run({ command: 'handoff:list', args: '' })
  expect(r.text).toContain('Kept the current context.')
  expect(ran[0]?.slice(1)).toEqual(['--all', '/home/me'])
})

test('/handoff:list with Esc', async ($, on) => {
  engine(on, new Error("The user doesn't want to proceed with this tool use."))
  const r = await $.command.run({ command: 'handoff:list', args: 'here' })
  expect(r.text).toContain('Menu closed.')
})

test('/handoff:list pick queues the load after the hook returns', async ($, on) => {
  engine(on, '2. Control-model step 3 build')
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

test('/handoff:status passes the session id first', async ($, on) => {
  const ran = engine(on, '')
  await $.command.run({ command: 'handoff:status', args: '' })
  expect(ran[0]?.slice(1)).toEqual(['cdc086f0-1336-4b20-9c94-ef8c922e65d4', '/home/me'])
})

test('a failing script leaves the command to the skill', async ($, on) => {
  on('session.id', () => ({ value: 'cdc086f0-1336-4b20-9c94-ef8c922e65d4' }))
  on('session.root', () => ({ value: '/home/me' }))
  on('process.run', () => Promise.reject(new Error('cannot start')))
  on('command.run', { command: 'handoff:status' }, () => ({ text: 'skill ran' }))
  const r = await $.command.run({ command: 'handoff:status', args: '' })
  expect(r.text).toBe('skill ran')
})
