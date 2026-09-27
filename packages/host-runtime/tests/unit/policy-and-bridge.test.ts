import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { readFile, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { duplexPair } from 'node:stream'
import { afterAll, afterEach, describe, expect, it } from 'vitest'
import { RpcPeer } from '../../src/bridge/rpc.ts'
import { PluginDataArea } from '../../src/data-area.ts'
import { DittoError } from '../../src/errors.ts'
import { faultsCompiledIn } from '../../src/fault.ts'
import { ModulePolicy } from '../../src/loader/module-policy.ts'
import { parseProjection } from '../../src/loader/projection.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { changeId, fixture, host, packagesDir, pluginFixture } from '../helpers.ts'

const scratch = mkdtempSync(join(tmpdir(), 'ditto-policy-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))
let h: TestHost | undefined
afterEach(async () => { await h?.close(); h = undefined })

describe('module resolution policy', () => {
  const store = join(scratch, 'packages', 'sha256')
  mkdirSync(join(store, 'abc', 'dist'), { recursive: true })
  mkdirSync(join(scratch, 'elsewhere'), { recursive: true })
  mkdirSync(join(store, 'abc', 'node_modules', 'x'), { recursive: true })
  writeFileSync(join(store, 'abc', 'dist', 'index.mjs'), 'export default {}')
  writeFileSync(join(store, 'abc', 'node_modules', 'x', 'index.mjs'), 'export default {}')
  writeFileSync(join(scratch, 'elsewhere', 'index.mjs'), 'export default {}')
  symlinkSync(join(scratch, 'elsewhere'), join(store, 'escape'))
  const policy = new ModulePolicy([store])

  it('admits a pushed path inside the package store and resolves it', () => {
    policy.admit(join(store, 'abc', 'dist', 'index.mjs'))
    expect(policy.resolve(join(store, 'abc', 'dist', 'index.mjs'))).toMatch(/^file:\/\//)
  })

  it.each([
    ['a relative path', 'dist/index.mjs'],
    ['an unnormalised path', `${store}/abc/../abc/dist/index.mjs`],
    ['a path outside the store', join(scratch, 'elsewhere', 'index.mjs')],
    ['a symlink leading out of the store', join(store, 'escape', 'index.mjs')],
    ['node_modules inside the store', join(store, 'abc', 'node_modules', 'x', 'index.mjs')],
    ['a missing file', join(store, 'abc', 'dist', 'missing.mjs')],
  ])('refuses %s', (_label, path) => {
    expect(() => policy.admit(path)).toThrow(DittoError)
  })

  it('refuses a bare specifier or any path Core did not push', () => {
    expect(() => policy.resolve('@deepseek-ai/cordis')).toThrow(/not pushed by Core/)
    expect(() => policy.resolve(join(store, 'other.mjs'))).toThrow(/not pushed by Core/)
  })

  it('reads XDG_DATA_HOME and DITTO_DEV_PACKAGES', () => {
    const roots = ModulePolicy.fromEnvironment({ XDG_DATA_HOME: '/data', DITTO_DEV_PACKAGES: '/src/a:/src/b' }).allowedRoots
    expect(roots).toEqual(['/data/ditto/packages/sha256/', '/src/a/', '/src/b/'])
    // DITTO_DATA_DIR wins, with the same layout as ditto_store::Paths::under.
    expect(ModulePolicy.fromEnvironment({ DITTO_DATA_DIR: '/fixture', XDG_DATA_HOME: '/data' }).allowedRoots).toEqual(['/fixture/data/packages/sha256/'])
    expect(ModulePolicy.fromEnvironment({ XDG_DATA_HOME: 'relative', HOME: '/home/u' }).allowedRoots).toEqual(['/home/u/.local/share/ditto/packages/sha256/'])
  })
})

describe('projection parsing', () => {
  const entry = { entry_id: 'ent-1', package: 'p.q', version: '1.0.0', module_path: '/x', data_dir: '/d' }
  it('fills defaults', () => {
    expect(parseProjection({ role: 'hostd', entries: [entry] }).entries[0]).toMatchObject({ disabled: false, provides: [], hot_swap: 'controlled_handoff', health_timeout_ms: 2_000, cleanup_timeout_ms: 5_000, config: {} })
  })
  it.each([
    ['wrong role', { role: 'shell', entries: [] }],
    ['duplicate ids', { role: 'hostd', entries: [entry, entry] }],
    ['an id the loader cannot key', { role: 'hostd', entries: [{ ...entry, entry_id: 'a:b' }] }],
    ['an unknown hot_swap', { role: 'hostd', entries: [{ ...entry, hot_swap: 'magic' }] }],
  ])('rejects %s', (_label, value) => {
    expect(() => parseProjection(value)).toThrow(/invalid HostProjection/)
  })
})

describe('JSON-RPC framing', () => {
  it('answers requests, forwards notifications and rejects frames over 1 MiB', async () => {
    const [a, b] = duplexPair()
    const seen: string[] = []
    let closedWith: Error | undefined
    const left = new RpcPeer(a, 'hostd-', { request: async () => ({}), notification: () => {}, closed: error => { closedWith = error } })
    const right = new RpcPeer(b, 'core-', {
      request: async (method, _params, id) => { seen.push(`${method}:${id}`); if (method === 'boom') throw new DittoError('conflict', 'no', { reason: 'x' }); return { ok: true } },
      notification: method => { seen.push(`note:${method}`) },
      closed: () => {},
    })
    expect(await left.request('ping', {})).toEqual({ ok: true })
    await expect(left.request('boom', {})).rejects.toMatchObject({ errorName: 'conflict', data: { reason: 'x' } })
    left.notify('hello', {})
    await new Promise(resolve => setTimeout(resolve, 5))
    expect(seen).toEqual(['ping:hostd-1', 'boom:hostd-2', 'note:hello'])
    await expect(left.request('big', { blob: 'x'.repeat(1_100_000) })).rejects.toMatchObject({ errorName: 'invalid_params' })
    b.write('x'.repeat(1_100_000))
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(closedWith?.message ?? '').toMatch(/1 MiB/)
    right.close()
  })
})

describe('plugin data area', () => {
  const dir = join(scratch, 'plugin-data', 'p')
  const area = new PluginDataArea(dir)
  it('reads and writes inside data_dir, atomically', async () => {
    await area.writeJson('state/list.json', { a: 1 })
    expect(await area.readJson('state/list.json')).toEqual({ a: 1 })
    expect(await area.list('state')).toEqual(['list.json'])
    expect(await area.readText('missing.txt')).toBeUndefined()
  })
  it.each(['../escape.txt', '/etc/passwd', '.', 'a/../../b'])('refuses %s', async path => {
    await expect(area.writeText(path, 'x')).rejects.toThrow(DittoError)
  })
  it('refuses a symlink that leads out of the area', async () => {
    mkdirSync(join(scratch, 'outside'), { recursive: true })
    symlinkSync(join(scratch, 'outside'), join(dir, 'link'))
    await expect(area.writeText('link/x.txt', 'x')).rejects.toThrow(/escapes/)
  })
})

describe('bridge behaviour through the test host', () => {
  it('participant.state answers from memory and says unknown for a change it does not remember', async () => {
    h = await host()
    const id = changeId()
    await h.core.apply(id, [h.entry({ entry_id: 'ent-s', module_path: fixture('generic'), config: { tag: 's' } })])
    expect((await h.core.state(id)).change).toEqual({ change_id: id, phase: 'committed' })
    expect((await h.core.state('chg-from-before-a-restart')).change).toEqual({ change_id: 'chg-from-before-a-restart', phase: 'unknown' })
    await h.close()
    // L-06 negative, hostd side: a restarted hostd remembers nothing.
    h = await host()
    expect((await h.core.state(id)).change).toEqual({ change_id: id, phase: 'unknown' })
    expect((await h.core.state()).observed.entries).toEqual([])
  })

  it('a PENDING candidate waits a bounded time, then fails as dependency_not_ready with the missing service named', async () => {
    h = await host({ pendingWaitMs: 300 })
    const id = changeId()
    const started = performance.now()
    const prepared = await h.core.prepare(id, [h.entry({ entry_id: 'ent-w', module_path: pluginFixture('faults/never_ready/src/index.ts') })])
    expect(performance.now() - started).toBeGreaterThanOrEqual(280)
    expect(prepared.items[0]).toMatchObject({ status: 'failed', reason: 'dependency_not_ready: ditto.fixture.missing', missing: ['ditto.fixture.missing'] })
    await h.core.abort(id)
    expect(h.runtime.tx.instances.size).toBe(0)
  })

  it('a module that is not a Cordis plugin fails its entry and leaves nothing mounted', async () => {
    h = await host()
    const id = changeId()
    const prepared = await h.core.prepare(id, [
      h.entry({ entry_id: 'ent-bad', module_path: `${fixture('not-a-plugin').slice(0, -3)}.mjs` }),
      h.entry({ entry_id: 'ent-ok', module_path: fixture('generic'), config: { tag: 'ok' } }),
    ])
    const bad = prepared.items.find(item => item.key === 'ent-bad')!
    expect(bad.status).toBe('failed')
    expect(bad.reason).toMatch(/^module_(invalid|load_failed)/)
    expect(prepared.items.find(item => item.key === 'ent-ok')!.status).toBe('ready')
    await h.core.abort(id)
    expect(h.runtime.tx.instances.size).toBe(0)
    expect(Object.keys(h.runtime.root.loader.store)).toEqual([])
  })

  it('host.invoke honours deadline_ms and validates the lease owner', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-i', module_path: fixture('generic'), config: { tag: 'i', register: ['plugin.test.i.get'] }, provides: ['plugin.test.i.get'] })])
    const binding = h.core.bindingOf('plugin.test.i.get')!
    await expect(h.core.invokeWithLease(binding.leaseId, 'ent-other', 'plugin.test.i.get')).rejects.toMatchObject({ data: { reason: 'not_bound' } })
    await expect(h.core.invokeWithLease('lease-never', 'ent-i', 'plugin.test.i.get')).rejects.toMatchObject({ data: { reason: 'not_bound' } })
    const registration = h.runtime.leases.lookup(binding.leaseId)!
    registration.definition.handler = () => new Promise(() => {})
    await expect(h.core.invoke('plugin.test.i.get', {}, 'shell', 50)).rejects.toMatchObject({ errorName: 'timeout', outcome: 'unknown' })
  })

  it('permissions fail closed: needs_approval, errors and malformed answers are denials', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-q', module_path: fixture('generic'), config: { tag: 'q' } })])
    const instance = h.runtime.tx.active.get('ent-q')!
    const ditto = instance.fiber!.ctx.ditto
    expect(await ditto.permissions.check('desktop.tasks.list')).toEqual({ decision: 'denied', reason: 'approval_unavailable' })
    h.core.grant('ent-q', 'desktop.tasks.list')
    expect(await ditto.permissions.check('desktop.tasks.list')).toEqual({ decision: 'allowed' })
    const sent = h.core.requests.filter(request => request.method === 'desktop.permissions.check').at(-1)!.params
    expect(sent).toMatchObject({ subject: 'host:ent-q', capability_id: 'desktop.tasks.list', _meta: { on_behalf_of: 'ent-q' } })
    h.core.faults.set('desktop.permissions.check', { action: 'refuse', error: { name: 'internal' } })
    expect((await ditto.permissions.check('desktop.tasks.list')).decision).toBe('denied')
    // `decision: allowed` without `effective: allowed` is malformed, not a yes.
    h.core.overrides.set('desktop.permissions.check', () => ({ decision: 'allowed' }))
    expect((await ditto.permissions.check('desktop.tasks.list')).decision).toBe('denied')
    h.core.overrides.clear()
    h.core.faults.delete('desktop.permissions.check')
    await expect(ditto.permissions.resolveFile('grant-nope')).rejects.toMatchObject({ errorName: 'permission_denied' })
  })

  it('file grants come from the projection and are forgotten on revocation', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-f', module_path: fixture('generic'), config: { tag: 'f' }, file_grants: { 'grant-todo': '/tmp/todo.txt' } })])
    const ditto = h.runtime.tx.active.get('ent-f')!.fiber!.ctx.ditto
    expect((await ditto.permissions.resolveFile('grant-todo')).path).toBe('/tmp/todo.txt')
    h.core.revokeGrant('ent-f', 'grant-todo')
    await new Promise(resolve => setTimeout(resolve, 10))
    await expect(ditto.permissions.resolveFile('grant-todo')).rejects.toMatchObject({ errorName: 'permission_denied' })
  })

  it('on_behalf_of carries the entry id; an entry Core did not assign is rejected by Core', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-o', module_path: fixture('generic'), config: { tag: 'o', emit: 'fixture/changed' } })])
    await h.runtime.events.flush('ent-o')
    const event = h.core.requests.find(request => request.method === 'host.event')!
    expect(event.params['_meta']).toMatchObject({ protocol_version: '0.2.0', on_behalf_of: 'ent-o' })
    expect(h.core.hostEvents).toEqual([expect.objectContaining({ entryId: 'ent-o', name: 'fixture/changed', coalesceKey: 'fixture/changed' })])
    await expect(h.runtime.leases.register({ instance: { entryId: 'ent-ghost', mode: 'active' } as never, definition: { id: 'x', version: '1', handler: () => {} }, revoked: false }))
      .rejects.toMatchObject({ errorName: 'identity_rejected' })
  })

  it('plugins cannot reach ctx.loader (only the transaction layer mutates the entry tree)', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-g', module_path: fixture('generic'), config: { tag: 'g' } })])
    const ctx = h.runtime.tx.active.get('ent-g')!.fiber!.ctx
    expect(() => ctx.loader).toThrow(/may not use ctx.loader/)
  })

  it('volatile-only config commits without a remount and rolls back the same way', async () => {
    h = await host()
    const entry = (threshold: number) => h!.entry({ entry_id: 'ent-v', module_path: fixture('generic'), config: { tag: 'v', register: ['plugin.test.v.get'], rules: { threshold } }, provides: ['plugin.test.v.get'] })
    await h.core.apply(changeId(), [entry(3)])
    const fiber = h.runtime.tx.active.get('ent-v')!.fiber
    const id = changeId()
    const { committed } = await h.core.apply(id, [entry(5)])
    expect(committed!.items[0]).toMatchObject({ status: 'applied' })
    expect(h.runtime.tx.active.get('ent-v')!.fiber).toBe(fiber)
    expect(await h.core.invoke('plugin.test.v.get')).toMatchObject({ threshold: 5 })
    expect((await h.core.rollback(id)).items[0]).toMatchObject({ status: 'restored' })
    expect(h.runtime.tx.active.get('ent-v')!.fiber).toBe(fiber)
    expect(await h.core.invoke('plugin.test.v.get')).toMatchObject({ threshold: 3 })
  })

  it('controlled handoff carries exported state into the new instance, and rollback carries it back', async () => {
    h = await host()
    const entry = (tag: string, state?: number) => h!.entry({ entry_id: 'ent-h', module_path: fixture('generic'), config: { tag, register: ['plugin.test.h.get'], ...(state !== undefined ? { state } : {}) }, provides: ['plugin.test.h.get'] })
    await h.core.apply(changeId(), [entry('h1', 42)])
    const id = changeId()
    await h.core.apply(id, [entry('h2')])
    expect(await h.core.invoke('plugin.test.h.get')).toMatchObject({ tag: 'h2', state: 42 })
    const rolledBack = await h.core.rollback(id)
    expect(rolledBack.items[0]).toMatchObject({ status: 'restored' })
    expect(await h.core.invoke('plugin.test.h.get')).toMatchObject({ tag: 'h1', state: 42 })
  })

  it('entry_state is pushed on fiber changes, rate-limited, and PENDING carries the services waited for', async () => {
    h = await host({ intervals: { entryStateMs: 50 } })
    await h.core.apply(changeId(), [
      h.entry({ entry_id: 'ent-p', module_path: fixture('provider'), config: { tag: 'p' } }),
      h.entry({ entry_id: 'ent-c', module_path: fixture('consumer'), config: { tag: 'c' } }),
    ])
    await h.core.apply(changeId(), [
      h.entry({ entry_id: 'ent-p', module_path: fixture('provider'), config: { tag: 'p' }, disabled: true }),
      h.entry({ entry_id: 'ent-c', module_path: fixture('consumer'), config: { tag: 'c' } }),
    ])
    await new Promise(resolve => setTimeout(resolve, 150))
    const last = h.core.entryStates.at(-1) as { entry_id: string; fiber_state: string; waiting_for: string[] | null; effects: number }[]
    expect(last).toEqual([expect.objectContaining({ entry_id: 'ent-c', fiber_state: 'pending', waiting_for: ['counter'] })])
    expect(last[0]).not.toHaveProperty('failure')
    expect(Object.keys(last[0]!)).not.toContain('memory')
    const times = h.core.requests.filter(request => request.method === 'host.entry_state').length
    expect(times).toBeLessThan(20)
  })

  it('host.hello carries versions, the vendored fingerprint and the D-32 strategy; resources are three separate numbers', async () => {
    h = await host({ background: true, intervals: { resourcesMs: 20, heartbeatMs: 20, renewMs: 1_000 } })
    const hello = h.core.requests.find(request => request.method === 'host.hello')!.params
    expect(hello).toMatchObject({ hostd_version: '0.2.0', cordis_version: '4.0.4', node_version: process.versions.node, strategy: expect.stringMatching(/^(isolate_rebuild|in_place)$/) })
    expect(hello['vendor_fingerprint']).toMatch(/^sha256:[0-9a-f]{64}$/)
    await new Promise(resolve => setTimeout(resolve, 80))
    const resources = h.core.resources.at(-1) as Record<string, unknown>
    expect(Object.keys(resources).filter(key => key !== '_meta').sort()).toEqual(['array_buffers', 'external', 'heap_used'])
    expect(h.core.heartbeats.length).toBeGreaterThan(0)
  })

  it('fault points are compiled into test builds only (the production bundle is checked by scripts/build.mjs)', () => {
    expect(faultsCompiledIn).toBe(true)
  })
})

describe('only the transaction layer mutates the loader tree (plan/03/03 §13 rule 2)', () => {
  it('no other source file calls loader.create/update/remove', async () => {
    const offenders: string[] = []
    const walk = async (dir: string): Promise<void> => {
      for (const entry of await readdir(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name)
        if (entry.isDirectory()) {
          if (!['node_modules', 'vendor', 'vendor-types', 'dist', 'tests', 'examples'].includes(entry.name)) await walk(path)
          continue
        }
        if (!/\.(ts|mts|mjs)$/.test(entry.name) || path.endsWith('loader/transaction.ts')) continue
        if (/\bloader\s*\.\s*(create|update|remove)\s*\(/.test(await readFile(path, 'utf8'))) offenders.push(path)
      }
    }
    for (const pkg of ['host-runtime/src', 'host-sdk/src', 'plugins', 'plugin-fixtures']) await walk(join(packagesDir, pkg)).catch(() => {})
    expect(offenders).toEqual([])
  })
})
