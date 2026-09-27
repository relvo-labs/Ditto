import { describe, expect, it } from 'vitest'
import type { CallOptions, CoreChannel } from '../../src/bridge/core-link.ts'
import { EventBridge, resyncEventName } from '../../src/events.ts'
import { HostLog } from '../../src/log.ts'

/** A Core whose `host.event` answers only when released, so queues actually build up. */
function slowCore() {
  const sent: { name: unknown; payload: unknown; onBehalfOf?: string }[] = []
  let release!: () => void
  let gate = new Promise<void>(resolve => { release = resolve })
  const core: CoreChannel = {
    async request<T>(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<T> {
      if (method !== 'host.event') return {} as T
      await gate
      sent.push({ name: params['name'], payload: params['payload'], ...(options?.onBehalfOf ? { onBehalfOf: options.onBehalfOf } : {}) })
      return {} as T
    },
  }
  return { core, sent, open: () => { release(); gate = Promise.resolve() } }
}

const log = new HostLog(() => {})

describe('event bridge (G1-HOST-04)', () => {
  it('keeps order per entry and merges queued `latest` events by key', async () => {
    const { core, sent, open } = slowCore()
    const bridge = new EventBridge(core, log)
    bridge.emit('ent-a', 'tasks/changed', { rev: 1 }, 'latest')
    bridge.emit('ent-a', 'tasks/added', { id: 1 }, 'none')
    bridge.emit('ent-a', 'tasks/changed', { rev: 2 }, 'latest')
    bridge.emit('ent-a', 'tasks/changed', { rev: 3 }, 'latest')
    bridge.emit('ent-a', 'tasks/added', { id: 2 }, 'none')
    open()
    await bridge.flush('ent-a')
    // The first event was already in flight when the gate closed; the rest merged behind it.
    expect(sent.map(item => [item.name, item.payload])).toEqual([
      ['tasks/changed', { rev: 1 }], ['tasks/added', { id: 1 }], ['tasks/changed', { rev: 3 }], ['tasks/added', { id: 2 }],
    ])
    expect(sent.every(item => item.onBehalfOf === 'ent-a')).toBe(true)
  })

  it('a full queue drops new events and sends exactly one resync marker — never a silent loss', async () => {
    const { core, sent, open } = slowCore()
    const bridge = new EventBridge(core, log, 4)
    for (let i = 0; i < 10; i++) bridge.emit('ent-a', 'tasks/added', { i }, 'none')
    // One in flight, four queued, one marker; five dropped.
    expect(bridge.depth('ent-a')).toBe(5)
    open()
    await bridge.flush('ent-a')
    expect(sent.map(item => item.name)).toEqual([...Array(5).fill('tasks/added'), resyncEventName])
    expect(sent.map(item => (item.payload as { i?: number }).i).slice(0, 5)).toEqual([0, 1, 2, 3, 4])
    expect(sent.at(-1)!.payload).toEqual({ reason: 'queue_overflow', dropped: 5 })
  })

  it('reserves the resync name', () => {
    const bridge = new EventBridge(slowCore().core, log)
    expect(() => bridge.emit('ent-a', resyncEventName, null, 'none')).toThrow(/reserved/)
  })
})
