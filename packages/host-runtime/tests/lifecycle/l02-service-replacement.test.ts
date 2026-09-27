import type { Fiber } from '@deepseek-ai/cordis'
import { afterEach, describe, expect, it } from 'vitest'
import { FiberState } from '../../src/fiber-state.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { clearRecords, events } from '../fixtures/probe.ts'
import { changeId, fixture, host, pluginFixture, strategy } from '../helpers.ts'

/** L-02 服務替換 (plan/03/06 §3). */
let h: TestHost
afterEach(async () => { await h?.close() })

function fibers(h: TestHost): Fiber[] {
  return [...h.runtime.root.registry.values()].flatMap(runtime => [...runtime.fibers])
}

function consumer(h: TestHost) {
  return h.entry({ entry_id: 'ent-c', module_path: fixture('consumer'), config: { tag: 'c', capability: 'plugin.test.c.read' }, provides: ['plugin.test.c.read'] })
}

describe('L-02 service replacement', () => {
  it('positive: replacing provider A with B restarts every consumer on B and leaves no fiber of A', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-a', module_path: fixture('provider'), config: { tag: 'A' } }), consumer(h)])
    expect(await h.core.invoke('plugin.test.c.read')).toMatchObject({ via: 'A' })

    const { committed } = await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-b', module_path: fixture('provider'), config: { tag: 'B' } }), consumer(h)])
    expect(committed!.items.find(item => item.key === 'ent-b')).toMatchObject({ status: 'applied' })
    await h.runtime.root.loader.await()

    expect(await h.core.invoke('plugin.test.c.read')).toMatchObject({ via: 'B' })
    expect(events('apply', 'c').at(-1)!.detail).toEqual({ provider: 'B' })
    const providers = fibers(h).filter(fiber => fiber.runtime?.callback === h.runtime.tx.active.get('ent-b')!.fiber!.runtime!.callback)
    expect(providers.map(fiber => fiber.config?.tag)).toEqual(['B'])
    expect(h.runtime.tx.instancesOf('ent-a')).toEqual([])
    expect(h.runtime.tx.active.get('ent-c')!.fiber!.state).toBe(FiberState.ACTIVE)
  })

  it('negative: B throws in apply → the change does not take effect, A keeps serving, consumers are never left PENDING', async () => {
    h = await host()
    await h.core.apply(changeId(), [h.entry({ entry_id: 'ent-a', module_path: fixture('provider'), config: { tag: 'A' } }), consumer(h)])
    clearRecords()
    const consumerFiber = h.runtime.tx.active.get('ent-c')!.fiber!
    const states: number[] = []
    const stop = h.runtime.root.on('internal/status', fiber => { if (fiber === consumerFiber) states.push(fiber.state) })

    const id = changeId()
    const broken = h.entry({ entry_id: 'ent-b', module_path: fixture('provider'), config: { tag: 'B', throwInApply: true } })
    const started = performance.now()
    const prepared = await h.core.prepare(id, [broken, consumer(h)])
    if (strategy === 'isolate_rebuild') {
      // Strategy A: the candidate failed in its own realm; the active set was never touched.
      expect(prepared.items.find(item => item.key === 'ent-b')).toMatchObject({ status: 'failed', reason: expect.stringMatching(/^apply_failed/) })
      await h.core.abort(id)
      expect(states).toEqual([])
      expect(events('disposed', 'c')).toEqual([])
    } else {
      // Strategy B only checks statically; the failure shows at commit and Core rolls back.
      const committed = await h.core.commit(id)
      expect(committed.items.find(item => item.key === 'ent-b')).toMatchObject({ status: 'failed' })
      const rolledBack = await h.core.rollback(id)
      expect(rolledBack.items.every(item => item.status === 'restored')).toBe(true)
      expect(performance.now() - started).toBeLessThan(5_000)
    }
    stop()
    await h.runtime.root.loader.await()
    expect(await h.core.invoke('plugin.test.c.read')).toMatchObject({ via: 'A' })
    expect(h.runtime.tx.active.get('ent-c')!.fiber!.state).toBe(FiberState.ACTIVE)
    expect(h.runtime.tx.instancesOf('ent-b')).toEqual([])
  })

  it('negative (fault fixture): throws_in_apply fails prepare with the apply error and mounts nothing', async () => {
    h = await host()
    const id = changeId()
    const prepared = await h.core.prepare(id, [h.entry({ entry_id: 'ent-t', module_path: pluginFixture('faults/throws_in_apply/src/index.ts') })])
    if (strategy === 'isolate_rebuild') {
      expect(prepared.items[0]).toMatchObject({ status: 'failed', reason: 'apply_failed: fixture: apply refuses to start' })
      await h.core.abort(id)
    } else {
      expect(prepared.items[0]).toMatchObject({ status: 'ready' })
      expect((await h.core.commit(id)).items[0]).toMatchObject({ status: 'failed', reason: 'apply_failed: fixture: apply refuses to start' })
      await h.core.rollback(id)
    }
    expect(h.runtime.tx.instancesOf('ent-t')).toEqual([])
    expect((await h.core.state()).observed.entries).toEqual([])
  })
})
