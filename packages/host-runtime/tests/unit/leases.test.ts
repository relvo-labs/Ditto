import { afterEach, describe, expect, it } from 'vitest'
import { DittoError } from '../../src/errors.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { changeId, fixture, host, strategy } from '../helpers.ts'

let h: TestHost
afterEach(async () => { await h?.close() })

const until = async (check: () => boolean, ms = 3_000) => {
  const end = Date.now() + ms
  while (!check()) {
    if (Date.now() > end) throw new Error('condition not reached')
    await new Promise(resolve => setTimeout(resolve, 10))
  }
}

describe('leases (G1-HOST-03)', () => {
  it('renews every lease in one batched request', async () => {
    h = await host({ background: true, intervals: { renewMs: 40, heartbeatMs: 1_000, resourcesMs: 60_000 } })
    await h.core.apply(changeId(), [h.entry({
      entry_id: 'ent-l', module_path: fixture('generic'), config: { tag: 'l', register: ['plugin.test.l.a', 'plugin.test.l.b'] },
      provides: ['plugin.test.l.a', 'plugin.test.l.b'],
    })])
    await until(() => h.core.requests.some(request => request.method === 'host.lease.renew'))
    const renew = h.core.requests.find(request => request.method === 'host.lease.renew')!
    expect((renew.params['lease_ids'] as string[]).sort()).toEqual([...h.core.bindings.keys()].sort())
    expect(renew.params['_meta']).not.toHaveProperty('on_behalf_of')
  })

  it('L-07 (hostd side): renewals stop → Core expires the binding; renewals resume → a new lease; the old lease id is refused', async () => {
    let paused = true
    h = await host({
      background: true, leaseTtlMs: 150,
      intervals: { renewMs: 40, heartbeatMs: 1_000, resourcesMs: 60_000 },
      faults: { 'lease.renew': async () => { if (paused) throw new Error('renewals paused') } },
    })
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-l', module_path: fixture('generic'), config: { tag: 'l', register: ['plugin.test.l.get'] }, provides: ['plugin.test.l.get'] })])
    const old = h.core.bindingOf('plugin.test.l.get')!
    await new Promise(resolve => setTimeout(resolve, 250))
    await expect(h.core.invoke('plugin.test.l.get')).rejects.toMatchObject({ errorName: 'unavailable', data: { reason: 'lease_expired' } })

    paused = false
    await until(() => { const binding = h.core.bindingOf('plugin.test.l.get'); return !!binding && binding.leaseId !== old.leaseId })
    expect(await h.core.invoke('plugin.test.l.get')).toMatchObject({ tag: 'l' })
    const refused = await h.core.invokeWithLease(old.leaseId, 'ent-l', 'plugin.test.l.get').catch(error => error)
    expect(refused).toBeInstanceOf(DittoError)
    expect(refused).toMatchObject({ errorName: 'unavailable', data: { reason: 'not_bound' } })
  })

  it('a refused registration is reported, not retried silently, and leaves no local lease', async () => {
    h = await host()
    h.core.faults.set('host.capability.register', { action: 'refuse', error: { name: 'conflict', data: { reason: 'single_provider_taken' } } })
    const { committed } = await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-r', module_path: fixture('generic'), config: { tag: 'r', register: ['plugin.test.r.get'] }, provides: ['plugin.test.r.get'] })])
    expect(committed!.items[0]).toMatchObject({ status: 'failed', reason: 'registration_refused: single_provider_taken' })
    expect(h.runtime.leases.size).toBe(0)
    expect(h.runtime.tx.active.has('ent-r')).toBe(false)
  })

  it('refuses to register a capability that is not in the entry provides', async () => {
    h = await host()
    const { prepared, committed } = await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-u', module_path: fixture('generic'), config: { tag: 'u', register: ['plugin.test.undeclared'] } })])
    // Strategy A sees it in the candidate; strategy B only when it mounts at commit.
    const item = strategy === 'isolate_rebuild' ? prepared.items[0] : committed!.items[0]
    expect(item).toMatchObject({ status: 'failed', reason: expect.stringContaining('not in the manifest provides') })
    expect(h.core.bindings.size).toBe(0)
  })
})
