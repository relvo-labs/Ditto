import { afterEach, describe, expect, it } from 'vitest'
import { FiberState } from '../../src/fiber-state.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { clearRecords, events, probe } from '../fixtures/probe.ts'
import { changeId, fixture, host, pluginFixture, strategy } from '../helpers.ts'

/** L-08 非同步 disposer 未完成即再次掛載 (plan/03/06 §3). */
let h: TestHost
afterEach(async () => {
  for (const release of releases.splice(0)) release()
  await h?.close()
})
const releases: (() => void)[] = []

function watchMain(h: TestHost, entryId: string) {
  let max = 0
  const tick = () => { max = Math.max(max, h.runtime.tx.liveMounts(entryId, 'main')) }
  const stopStatus = h.runtime.root.on('internal/status', tick)
  const timer = setInterval(tick, 2)
  return () => { clearInterval(timer); stopStatus(); return max }
}

describe('L-08 async disposer not finished before the next mount', () => {
  it('positive: replacing an entry waits for the old instance cleanup; at most one main instance at any time', async () => {
    h = await host()
    const x = (tag: string) => h.entry({ entry_id: 'ent-x', module_path: fixture('generic'), config: { tag, disposeDelayMs: 300, register: ['plugin.test.x.get'] }, provides: ['plugin.test.x.get'] })
    await h.core.apply(changeId(), [x('x1')])
    clearRecords()
    const stop = watchMain(h, 'ent-x')
    const { committed } = await h.core.apply(changeId(), [x('x2')])
    const max = stop()
    expect(committed!.items[0]).toMatchObject({ status: 'applied' })
    const oldDisposed = events('disposed', 'x1')[0]!.at
    const rebuiltApplied = events('apply', 'x2').at(-1)!.at
    expect(rebuiltApplied).toBeGreaterThan(oldDisposed)
    expect(max).toBe(1)
    expect(await h.core.invoke('plugin.test.x.get')).toMatchObject({ tag: 'x2' })
  })

  it('positive (Cordis): a provider whose consumer is still cleaning up is not reported gone until that cleanup ends', async () => {
    h = await host()
    const provider = (disabled: boolean) => h.entry({ entry_id: 'ent-p', module_path: fixture('provider'), config: { tag: 'p' }, disabled })
    const slowConsumer = h.entry({ entry_id: 'ent-sc', module_path: fixture('consumer'), config: { tag: 'sc' } })
    await h.core.apply(changeId(), [provider(false), slowConsumer])
    const fiber = h.runtime.tx.active.get('ent-sc')!.fiber!
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    fiber.ctx.effect(() => async () => { await gate }, 'test: slow consumer cleanup')
    clearRecords()

    const disabling = h.core.apply(changeId(), [provider(true), slowConsumer])
    await new Promise(resolve => setTimeout(resolve, 100))
    // Cordis' provide() disposer awaits dependents: the provider cannot finish before the consumer has.
    expect(fiber.state).toBe(FiberState.UNLOADING)
    expect(h.runtime.tx.instancesOf('ent-p')).toHaveLength(1)
    release()
    await disabling
    expect(h.runtime.tx.instancesOf('ent-p')).toHaveLength(0)
    expect(fiber.state).toBe(FiberState.PENDING)

    await h.core.apply(changeId(), [provider(false), slowConsumer])
    await h.runtime.root.loader.await()
    await fiber.await()
    expect(fiber.state).toBe(FiberState.ACTIVE)
    expect(events('apply', 'sc')).toHaveLength(1)
    expect(events('apply', 'sc')[0]!.at).toBeGreaterThan(events('disposed', 'sc')[0]!.at)
    expect(probe().maxLive.get('sc')).toBeLessThanOrEqual(1)
  })

  it('negative: the old instance never finishes cleanup → cleanup timeout, entry faulted, the next mount is refused', async () => {
    h = await host()
    const x = (tag: string, gate?: string) => h.entry({
      entry_id: 'ent-x', module_path: fixture('generic'), cleanup_timeout_ms: 300,
      config: { tag, register: ['plugin.test.x.get'], ...(gate ? { disposeGate: gate } : {}) }, provides: ['plugin.test.x.get'],
    })
    await h.core.apply(changeId(), [x('x1', 'never')])
    // Only the running main-realm x1 hangs; the gate did not exist while its candidate was cleaned up.
    probe().gates.set('never', new Promise(() => {}))
    clearRecords()
    const stop = watchMain(h, 'ent-x')
    const { committed } = await h.core.apply(changeId(), [x('x2')])
    expect(committed!.items[0]).toMatchObject({ key: 'ent-x', status: 'failed', reason: 'cleanup_timeout' })
    expect(h.runtime.tx.faulted.get('ent-x')).toBe('cleanup_timeout')
    // x2 ran only as a candidate (strategy A) and was cleaned up; it never ran next to x1 in the main realm.
    expect(stop()).toBeLessThanOrEqual(1)

    const again = changeId()
    const prepared = await h.core.prepare(again, [x('x3')])
    expect(prepared.items[0]).toMatchObject({ status: 'failed', reason: 'entry_faulted: cleanup_timeout' })
    await h.core.abort(again)
    expect(events('apply', 'x3')).toHaveLength(0)
    expect((await h.core.state()).observed.entries).toEqual([{ entry_id: 'ent-x', fiber_state: 'failed', mode: 'candidate', failure: 'cleanup_timeout' }])
    // The registration disposer ran even though another disposer hangs: no lease survives.
    expect(h.core.bindingOf('plugin.test.x.get')).toBeUndefined()
  })

  it('negative (fault fixture): refuses_cleanup can never produce a second instance', async () => {
    h = await host()
    const stuck = (config: Record<string, unknown>) => h.entry({
      entry_id: 'ent-stuck', module_path: pluginFixture('faults/refuses_cleanup/src/index.ts'), config: config as never,
      provides: ['plugin.ditto.fixture.fault_refuses_cleanup.get'], cleanup_timeout_ms: 300,
    })
    const stop = watchMain(h, 'ent-stuck')
    const first = await h.core.apply(changeId(), [stuck({})])
    if (strategy === 'isolate_rebuild') {
      // Under A the candidate itself must be cleaned up before the rebuild; it cannot be, so the entry never activates.
      expect(first.committed!.items[0]).toMatchObject({ status: 'failed', reason: 'candidate_cleanup_timeout' })
    } else {
      expect(first.committed!.items[0]).toMatchObject({ status: 'applied' })
      const second = await h.core.apply(changeId(), [stuck({ v: 2 })])
      expect(second.committed!.items[0]).toMatchObject({ status: 'failed', reason: 'cleanup_timeout' })
    }
    expect(h.runtime.tx.faulted.get('ent-stuck')).toBe('cleanup_timeout')
    const again = changeId()
    expect((await h.core.prepare(again, [stuck({ v: 3 })])).items[0]).toMatchObject({ status: 'failed', reason: 'entry_faulted: cleanup_timeout' })
    await h.core.abort(again)
    expect(stop()).toBeLessThanOrEqual(1)
    expect(h.core.bindingOf('plugin.ditto.fixture.fault_refuses_cleanup.get')).toBeUndefined()
  })
})
