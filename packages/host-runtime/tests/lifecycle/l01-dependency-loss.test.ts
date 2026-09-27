import { afterEach, describe, expect, it } from 'vitest'
import { FiberState } from '../../src/fiber-state.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { clearRecords, events } from '../fixtures/probe.ts'
import { changeId, fixture, host } from '../helpers.ts'

/**
 * L-01 依賴消失 (plan/03/06 §3). Assertions read the fiber state, the fake
 * Core's binding table and what the fixtures recorded, not log lines.
 */
let h: TestHost
afterEach(async () => { await h?.close() })

function entries(h: TestHost, options: { providerDisabled?: boolean; consumers?: { id: string; tag: string; throwInDispose?: boolean }[] } = {}) {
  const consumers = options.consumers ?? [{ id: 'ent-c', tag: 'c' }]
  return [
    h.entry({ entry_id: 'ent-p', module_path: fixture('provider'), config: { tag: 'p' }, disabled: options.providerDisabled ?? false }),
    ...consumers.map(consumer => h.entry({
      entry_id: consumer.id,
      module_path: fixture('consumer'),
      config: { tag: consumer.tag, capability: `plugin.test.${consumer.tag}.read`, ...(consumer.throwInDispose ? { throwInDispose: true } : {}) },
      provides: [`plugin.test.${consumer.tag}.read`],
    })),
  ]
}

async function settled(h: TestHost) {
  await h.runtime.root.loader.await()
  await new Promise(resolve => setTimeout(resolve, 20))
}

describe('L-01 dependency loss', () => {
  it('positive: provider disabled → consumer PENDING and its capability revoked; provider back → consumer ACTIVE and registered again', async () => {
    h = await host()
    expect((await h.core.apply(changeId(), entries(h))).committed!.items.every(item => item.status === 'applied')).toBe(true)
    const consumer = h.runtime.tx.active.get('ent-c')!
    expect(consumer.fiber!.state).toBe(FiberState.ACTIVE)
    const firstLease = h.core.bindingOf('plugin.test.c.read')!.leaseId

    await h.core.apply(changeId(), entries(h, { providerDisabled: true }))
    await settled(h)
    expect(consumer.fiber!.state).toBe(FiberState.PENDING)
    expect(h.core.bindingOf('plugin.test.c.read')).toBeUndefined()
    expect(h.core.revokedLeases.has(firstLease)).toBe(true)
    // PENDING is reported as the service being waited for, not as a failure.
    const observed = (await h.core.state()).observed.entries.find(entry => entry.entry_id === 'ent-c')!
    expect(observed).toEqual({ entry_id: 'ent-c', fiber_state: 'pending', mode: 'active', waiting_for: ['counter'] })

    await h.core.apply(changeId(), entries(h))
    await settled(h)
    expect(consumer.fiber!.state).toBe(FiberState.ACTIVE)
    const lease = h.core.bindingOf('plugin.test.c.read')
    expect(lease).toBeDefined()
    expect(lease!.leaseId).not.toBe(firstLease)
    expect(await h.core.invoke('plugin.test.c.read')).toMatchObject({ via: 'p' })
  })

  it('negative: a consumer disposer that throws is still unloaded, the error is logged and isolated from the other consumer', async () => {
    h = await host()
    const consumers = [{ id: 'ent-c1', tag: 'c1', throwInDispose: true }, { id: 'ent-c2', tag: 'c2' }]
    await h.core.apply(changeId(), entries(h, { consumers }))
    clearRecords()

    await h.core.apply(changeId(), entries(h, { providerDisabled: true, consumers }))
    await settled(h)
    for (const id of ['ent-c1', 'ent-c2']) expect(h.runtime.tx.active.get(id)!.fiber!.state).toBe(FiberState.PENDING)
    expect(events('disposed', 'c1')).toHaveLength(1)
    expect(events('disposed', 'c2')).toHaveLength(1)
    expect(h.core.bindingOf('plugin.test.c1.read')).toBeUndefined()
    expect(h.core.bindingOf('plugin.test.c2.read')).toBeUndefined()
    expect(h.logs.some(log => log.level === 'error' && log['source'] === 'cordis' && /c1 disposer failed/.test(log.msg))).toBe(true)

    await h.core.apply(changeId(), entries(h, { consumers }))
    await settled(h)
    expect(await h.core.invoke('plugin.test.c1.read')).toMatchObject({ via: 'p' })
    expect(await h.core.invoke('plugin.test.c2.read')).toMatchObject({ via: 'p' })
  })
})
