import { mkdtempSync, readFileSync, rmSync, writeFileSync, renameSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createTestHost, type TestHost } from '@ditto/host-sdk/testing'
import { appendTask, completeTask, lineIds, parseFile, parseLine } from '../src/todotxt.ts'

const root = fileURLToPath(new URL('../', import.meta.url))
const provides = ['desktop.tasks.list', 'desktop.tasks.add', 'desktop.tasks.complete', 'desktop.tasks.subscribe']
let h: TestHost
let dir: string
let todo: string
let n = 0
const change = () => `chg-tasks-${++n}`

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'ditto-tasks-'))
  todo = join(dir, 'todo.txt')
  writeFileSync(todo, '(A) 2026-09-20 繳電話費 +家務 @手機\nx 2026-09-21 2026-09-20 買牛奶\n')
  h = await createTestHost({ packageRoots: [root], pendingWaitMs: 1_000 })
})
afterEach(async () => {
  await h.close()
  rmSync(dir, { recursive: true, force: true })
})

/** Core puts the path of each grant the entry holds into its projection; config names only the grant id. */
function tasks(config: Record<string, unknown> = { source: { kind: 'todo_txt', path_grant: 'grant-todo' } }, grants: Record<string, string> = { 'grant-todo': todo }) {
  return h.entry({
    entry_id: 'ent-tasks', package: 'ditto.svc.tasks', module_path: join(root, 'src', 'index.ts'), provides, config: config as never,
    data_dir: join(dir, 'plugin-data', 'ditto.svc.tasks'), file_grants: grants,
  })
}

async function until<T>(read: () => T | undefined, ms = 2_000): Promise<{ value: T; elapsed: number }> {
  const start = performance.now()
  while (performance.now() - start < ms) {
    const value = read()
    if (value !== undefined) return { value, elapsed: performance.now() - start }
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error('not within the time limit')
}

/** ditto_protocol::services::TasksListOutput */
type List = { tasks: { task_id: string; text: string; done: boolean; source: string; priority?: string }[]; demo: boolean; sources: { source: string; status: string }[] }
const listKeys = ['demo', 'sources', 'tasks']
const taskKeys = ['done', 'priority', 'source', 'task_id', 'text']

describe('todo.txt', () => {
  it('parses priority, dates, projects and contexts, and keeps ids stable per line', () => {
    expect(parseLine('(A) 2026-09-20 繳電話費 +家務 @手機')).toMatchObject({ priority: 'A', created: '2026-09-20', text: '繳電話費 +家務 @手機', projects: ['家務'], contexts: ['手機'], done: false })
    expect(parseLine('x 2026-09-21 2026-09-20 買牛奶')).toMatchObject({ done: true, completed: '2026-09-21', created: '2026-09-20', text: '買牛奶' })
    const lines = parseFile('a\nb\na\n')
    const ids = lineIds(lines)
    expect(ids[0]).not.toBe(ids[2])
    expect(lineIds(parseFile('z\na\nb\na\n')).slice(1)).toEqual(ids)
    // Completing (or re-prioritising) keeps the id: it depends on the text only.
    expect(lineIds(parseFile('x 2026-09-27 a\n(B) b\na\n'))).toEqual(ids)
  })
  it('appends and completes without touching other lines', () => {
    const now = new Date('2026-09-27T08:00:00Z')
    const content = appendTask('one\n(B) two', 'three', now)
    expect(content).toBe('one\n(B) two\n2026-09-27 three\n')
    const id = lineIds(parseFile(content))[1]!
    expect(completeTask(content, id, now)).toBe('one\nx 2026-09-27 two\n2026-09-27 three\n')
    expect(completeTask(content, 'f-missing-1', now)).toBeUndefined()
  })
})

describe('svc-tasks in the test host', () => {
  it('reads the granted file and its own list; the path comes from the grant, not from config', async () => {
    const { committed } = await h.core.apply(change(), [tasks()])
    expect(committed!.items[0]).toMatchObject({ status: 'applied' })
    const list = await h.core.invoke('desktop.tasks.list') as List
    // Exactly the Rust shape: Core deserialises it with deny_unknown_fields.
    expect(Object.keys(list).sort()).toEqual(listKeys)
    for (const task of list.tasks) expect(taskKeys).toEqual(expect.arrayContaining(Object.keys(task)))
    expect(list.sources).toEqual([{ source: 'file:grant-todo', status: 'ok' }, { source: 'own', status: 'ok' }])
    expect(list.tasks.map(task => [task.text, task.done, task.source, task.priority])).toEqual([['繳電話費 +家務 @手機', false, 'file:grant-todo', 'A'], ['買牛奶', true, 'file:grant-todo', undefined]])
    expect(list.demo).toBe(false)
    // The path is in the projection's file_grants, never in the entry's config.
    expect(JSON.stringify(tasks().config)).not.toContain(dir)
  })

  it('emits tasks/changed within 2 s of an external edit (an editor replacing the file)', async () => {
    await h.core.apply(change(), [tasks()])
    await h.runtime.events.flush('ent-tasks')
    const before = h.core.hostEvents.length
    const tmp = join(dir, '.todo.txt.swp')
    writeFileSync(tmp, readFileSync(todo, 'utf8') + '寫報告 +工作\n')
    renameSync(tmp, todo)
    const { elapsed, value } = await until(() => h.core.hostEvents.slice(before).find(event => event.name === 'tasks/changed'))
    expect(elapsed).toBeLessThan(2_000)
    expect(value.payload).toMatchObject({ why: 'file_edited', open: 2, done: 1, file_state: 'active' })
    expect(((await h.core.invoke('desktop.tasks.list')) as List).tasks.map(task => task.text)).toContain('寫報告 +工作')
  })

  it('adds and completes in the file and in its own list (data area), and survives a restart of the plugin', async () => {
    await h.core.apply(change(), [tasks()])
    const added = await h.core.invoke('desktop.tasks.add', { text: '買牛奶' }) as { task_id: string; source: string; done: boolean }
    expect(added).toMatchObject({ source: 'file:grant-todo', done: false })
    const own = await h.core.invoke('desktop.tasks.add', { text: '整理相簿', source: 'own' }) as { task_id: string }
    const completed = await h.core.invoke('desktop.tasks.complete', { task_id: added.task_id }) as { task_id: string; done: boolean }
    // Core's readback looks for the same task_id, now done.
    expect(completed).toMatchObject({ task_id: added.task_id, done: true })
    const listed = await h.core.invoke('desktop.tasks.list') as List
    expect(listed.tasks.find(task => task.task_id === added.task_id)).toMatchObject({ done: true })
    await h.core.invoke('desktop.tasks.complete', { task_id: own.task_id })
    expect(readFileSync(todo, 'utf8')).toMatch(/\nx \d{4}-\d{2}-\d{2} \d{4}-\d{2}-\d{2} 買牛奶\n$/)
    const stored = JSON.parse(readFileSync(join(dir, 'plugin-data', 'ditto.svc.tasks', 'own-tasks.json'), 'utf8'))
    expect(stored.items).toEqual([expect.objectContaining({ id: own.task_id, text: '整理相簿', done: true })])
    // Replace the instance (controlled handoff); the own list is read back from the data area.
    await h.core.apply(change(), [tasks({ source: { kind: 'todo_txt', path_grant: 'grant-todo' }, demo: false })])
    const list = await h.core.invoke('desktop.tasks.list', { source: 'own' }) as List
    expect(list.tasks).toEqual([{ task_id: own.task_id, text: '整理相簿', done: true, source: 'own' }])
  })

  it('without a grant: only its own list, never a guessed path; sample items only when asked for, and labelled', async () => {
    await h.core.apply(change(), [tasks({ source: { kind: 'todo_txt', path_grant: 'grant-todo' }, demo: true }, {})])
    const list = await h.core.invoke('desktop.tasks.list') as List
    expect(list.sources).toEqual([{ source: 'file:grant-todo', status: 'unavailable' }, { source: 'own', status: 'ok' }])
    expect(list.tasks.length).toBeGreaterThan(0)
    expect(list.tasks.every(task => task.source === 'demo')).toBe(true)
    expect(list.demo).toBe(true)
    await expect(h.core.invoke('desktop.tasks.add', { text: 'x', source: 'file' })).rejects.toMatchObject({ errorName: 'permission_denied' })
  })

  it('revocation: stops watching, clears the file items and reports the revoked state', async () => {
    await h.core.apply(change(), [tasks()])
    const instance = h.runtime.tx.active.get('ent-tasks')!
    const watchers = () => instance.fiber!.getEffects().filter(effect => effect.label.includes('fs.watch')).length
    expect(watchers()).toBe(1)
    h.core.revokeGrant('ent-tasks', 'grant-todo')
    const { value } = await until(() => h.core.hostEvents.find(event => (event.payload as { why?: string }).why === 'file_revoked'))
    expect(value.payload).toMatchObject({ file_state: 'revoked', open: 0, done: 0 })
    expect(watchers()).toBe(0)
    const list = await h.core.invoke('desktop.tasks.list') as List
    expect(list.tasks.filter(task => task.source.startsWith('file:'))).toEqual([])
    expect(list.sources[0]).toEqual({ source: 'file:grant-todo', status: 'revoked' })
    // Editing the file after revocation produces no event.
    const count = h.core.hostEvents.length
    writeFileSync(todo, 'should not be seen\n')
    await new Promise(resolve => setTimeout(resolve, 300))
    expect(h.core.hostEvents.length).toBe(count)
  })

  it('controlled handoff: writes accepted before a replacement reach the file exactly once', async () => {
    await h.core.apply(change(), [tasks()])
    const writes = Array.from({ length: 5 }, (_, i) => h.core.invoke('desktop.tasks.add', { text: `任務 ${i}` }))
    await h.core.apply(change(), [tasks({ source: { kind: 'todo_txt', path_grant: 'grant-todo' }, demo: true })])
    await Promise.allSettled(writes)
    const lines = readFileSync(todo, 'utf8').trim().split('\n')
    for (let i = 0; i < 5; i++) expect(lines.filter(line => line.endsWith(`任務 ${i}`))).toHaveLength(1)
  })
})
