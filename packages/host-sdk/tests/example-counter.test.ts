import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'
import { createTestHost, type TestHost } from '../src/testing.ts'

/**
 * G1-HOST-08 判準: the example plugin passes L-01, L-03, L-04 and L-08 in
 * createTestHost(), the way a plugin author would test their own plugin.
 */
const example = fileURLToPath(new URL('../examples/counter/', import.meta.url))
const fixtures = fileURLToPath(new URL('./fixtures/', import.meta.url))
const counterPath = join(example, 'src', 'index.ts')
const consumerPath = join(fixtures, 'counter-consumer.mjs')

let h: TestHost
afterEach(async () => { await h?.close() })

const provides = ['plugin.ditto.example.counter.get', 'plugin.ditto.example.counter.increment']
let n = 0
const id = () => `chg-example-${++n}`

async function start() {
  h = await createTestHost({ packageRoots: [example, fixtures], pendingWaitMs: 500 })
  return h
}
const counter = (h: TestHost, config: Record<string, number> = {}, disabled = false) => h.entry({
  entry_id: 'ent-counter', module_path: counterPath, package: 'ditto.example.counter', config, provides, disabled,
})
const consumer = (h: TestHost) => h.entry({ entry_id: 'ent-peek', module_path: consumerPath, provides: ['plugin.test.consumer.peek'] })

describe('counter example with createTestHost()', () => {
  it('serves, emits a declared event, and hands its value over on replacement', async () => {
    await start()
    await h.core.apply(id(), [counter(h)])
    await h.core.invoke('plugin.ditto.example.counter.increment')
    await h.core.invoke('plugin.ditto.example.counter.increment')
    await h.runtime.events.flush('ent-counter')
    expect(h.core.hostEvents.map(event => event.payload)).toEqual([{ value: 1 }, { value: 2 }])
    await h.core.apply(id(), [counter(h, { step: 5 })])
    expect(await h.core.invoke('plugin.ditto.example.counter.increment')).toEqual({ value: 7 })
  })

  it('L-01: a consumer of the counter service waits (PENDING) while the counter is disabled and comes back with it', async () => {
    await start()
    await h.core.apply(id(), [counter(h), consumer(h)])
    await h.core.apply(id(), [counter(h, {}, true), consumer(h)])
    await h.runtime.root.loader.await()
    expect((await h.core.state()).observed.entries.find(entry => entry.entry_id === 'ent-peek')).toMatchObject({ fiber_state: 'pending', waiting_for: ['dittoExampleCounter'] })
    expect(h.core.bindingOf('plugin.test.consumer.peek')).toBeUndefined()
    await h.core.apply(id(), [counter(h), consumer(h)])
    await h.runtime.root.loader.await()
    expect(await h.core.invoke('plugin.test.consumer.peek')).toEqual({ seen: 0 })
  })

  it('L-03: a replacement never has two bindings for the same capability', async () => {
    await start()
    await h.core.apply(id(), [counter(h)])
    const change = id()
    await h.core.prepare(change, [counter(h, { step: 2 })])
    for (const capability of provides) expect([...h.core.bindings.values()].filter(binding => binding.capabilityId === capability)).toHaveLength(1)
    await h.core.commit(change)
    for (const capability of provides) expect([...h.core.bindings.values()].filter(binding => binding.capabilityId === capability)).toHaveLength(1)
  })

  it('L-04: 100 mount/unmount cycles leave nothing behind', async () => {
    await start()
    await h.core.apply(id(), [counter(h)])
    await h.core.apply(id(), [counter(h, {}, true)])
    const count = () => [h.runtime.tx.instances.size, h.runtime.leases.size, h.core.bindings.size, h.runtime.root.fiber.getEffects().length, Reflect.ownKeys(h.runtime.root.reflect.store).length]
    const first = count()
    for (let i = 0; i < 100; i++) {
      await h.core.apply(id(), [counter(h)])
      await h.core.apply(id(), [counter(h, {}, true)])
    }
    expect(count()).toEqual(first)
  })

  it('L-08: the rebuilt counter starts only after the previous instance finished cleaning up', async () => {
    await start()
    await h.core.apply(id(), [counter(h)])
    const old = h.runtime.tx.active.get('ent-counter')!
    let released = 0
    old.fiber!.ctx.effect(() => async () => { await new Promise(resolve => setTimeout(resolve, 200)); released = performance.now() }, 'test: slow flush')
    await h.core.apply(id(), [counter(h, { step: 3 })])
    expect(h.runtime.tx.active.get('ent-counter')!.mountedAt).toBeGreaterThan(released)
    expect(h.runtime.tx.liveMounts('ent-counter', 'main')).toBe(1)
  })
})
