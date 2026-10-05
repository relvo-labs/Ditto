import { afterEach, describe, expect, it } from 'vitest'
import type { TestHost } from '../../src/testing/index.ts'
import { events, probe } from '../fixtures/probe.ts'
import { changeId, fixture, host, pluginFixture } from '../helpers.ts'

/**
 * L-04 Context 撤除 (plan/03/06 §3): the TS half. PSS belongs to the nightly
 * measurement on the reference machine; this test holds the counts.
 */
let h: TestHost
afterEach(async () => { await h?.close() })

function hookCount(h: TestHost): number {
  const hooks = h.runtime.root.events._hooks as Record<string, unknown[]>
  return Object.values(hooks).reduce((sum, list) => sum + list.length, 0)
}

/** Everything that could leak across a mount/unmount cycle. */
function snapshot(h: TestHost) {
  const root = h.runtime.root
  return {
    fibers: [...root.registry.values()].reduce((sum, runtime) => sum + runtime.fibers.length, 0),
    runtimes: [...root.registry.values()].length,
    rootEffects: root.fiber.getEffects().length,
    serviceImpls: Reflect.ownKeys(root.reflect.store).length,
    hooks: hookCount(h),
    loaderEntries: Object.keys(root.loader.store).length,
    instances: h.runtime.tx.instances.size,
    hostLeases: h.runtime.leases.size,
    coreBindings: h.core.bindings.size,
    hostSubscriptions: h.runtime.subscriptions.size,
  }
}

describe('L-04 context disposal', () => {
  it('positive: mounting and removing the same entry 100 times leaves fiber, effect, subscription and lease counts unchanged', async () => {
    h = await host()
    const mount = (disabled: boolean) => h.entry({
      entry_id: 'ent-cycle', module_path: fixture('generic'), disabled,
      config: { tag: 'cycle', register: ['plugin.test.cycle.get'], subscribe: ['tasks'], timers: 2 },
      provides: ['plugin.test.cycle.get'],
    })
    // Warm-up cycle: the first import and the loader's own effects happen once.
    await h.core.apply(changeId(), [mount(false)])
    await h.core.apply(changeId(), [mount(true)])
    const first = snapshot(h)
    const counts: ReturnType<typeof snapshot>[] = []
    for (let i = 0; i < 100; i++) {
      const up = await h.core.apply(changeId(), [mount(false)])
      expect(up.committed!.items[0]!.status).toBe('applied')
      const mounted = snapshot(h)
      expect(mounted.coreBindings).toBe(1)
      expect(mounted.hostSubscriptions).toBe(1)
      await h.core.apply(changeId(), [mount(true)])
      if (i % 10 === 9) counts.push(snapshot(h))
    }
    expect(counts).toHaveLength(10)
    for (const count of counts) expect(count).toEqual(first)
    expect(first).toMatchObject({ instances: 0, hostLeases: 0, coreBindings: 0, hostSubscriptions: 0, loaderEntries: 0 })
    expect(probe().live.get('cycle')).toBe(0)
  })

  it('negative: a 2 s async disposer delays the next mount; there are never two instances', async () => {
    h = await host()
    const slow = (disabled: boolean) => h.entry({
      entry_id: 'ent-slow', module_path: pluginFixture('faults/slow_disposer/src/index.ts'), disabled,
      config: {}, provides: ['plugin.ditto.fixture.fault_slow_disposer.get'],
    })
    const generic = (disabled: boolean) => h.entry({
      entry_id: 'ent-slow-g', module_path: fixture('generic'), disabled, config: { tag: 'slow', disposeDelayMs: 2_000 },
    })
    await h.core.apply(changeId(), [slow(false), generic(false)])
    let maxMain = 0
    const sample = setInterval(() => {
      maxMain = Math.max(maxMain, h.runtime.tx.liveMounts('ent-slow', 'main'), h.runtime.tx.liveMounts('ent-slow-g', 'main'))
    }, 5)

    const removalId = changeId()
    await h.core.prepare(removalId, [slow(true), generic(true)])
    const started = performance.now()
    const removal = h.core.commit(removalId)
    // The next change arrives while the removal is still cleaning up; hostd must hold it.
    const remount = h.core.apply(changeId(), [slow(false), generic(false)])
    await removal
    const removed = performance.now()
    await remount
    clearInterval(sample)

    expect(removed - started).toBeGreaterThanOrEqual(1_900)
    const disposedAt = events('disposed', 'slow')[0]!.at
    const remountedAt = events('apply', 'slow').at(-1)!.at
    expect(remountedAt).toBeGreaterThan(disposedAt)
    expect(maxMain).toBeLessThanOrEqual(1)
    expect(probe().maxLive.get('slow')).toBeLessThanOrEqual(1)
    expect(await h.core.invoke('plugin.ditto.fixture.fault_slow_disposer.get')).toEqual({ delay: 2_000 })
  })
})
