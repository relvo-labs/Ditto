import type { Json } from './api.ts'
import type { CoreChannel } from './bridge/core-link.ts'
import { DittoError } from './errors.ts'
import type { HostLog } from './log.ts'

interface Pending { name: string; payload: Json; coalesceKey?: string; resync?: boolean }

/** Reserved event name hostd sends when it had to drop events (host-protocol §7). */
export const resyncEventName = 'resync_required'

class EntryQueue {
  readonly items: Pending[] = []
  dropped = 0
  pumping = false
}

/**
 * Per-entry outbound event queues. Events go out one at a time per entry, so
 * order holds. `latest` events merge by key while queued. A full queue drops
 * the new event and queues exactly one resync marker, never a silent loss.
 */
export class EventBridge {
  private readonly queues = new Map<string, EntryQueue>()

  constructor(private readonly core: CoreChannel, private readonly log: HostLog, readonly limit = 256) {}

  depth(entryId: string): number { return this.queues.get(entryId)?.items.length ?? 0 }

  emit(entryId: string, name: string, payload: Json, coalesce: 'none' | 'latest', coalesceKey?: string): void {
    if (name === resyncEventName) throw new DittoError('invalid_params', `${resyncEventName} is reserved`)
    const queue = this.queue(entryId)
    const key = coalesce === 'latest' ? (coalesceKey ?? name) : undefined
    if (key !== undefined) {
      const queued = queue.items.find(item => !item.resync && item.coalesceKey === key)
      if (queued) {
        queued.payload = payload
        return
      }
    }
    if (queue.items.filter(item => !item.resync).length >= this.limit) {
      if (!queue.dropped) queue.items.push({ name: resyncEventName, payload: null, resync: true })
      queue.dropped += 1
      return
    }
    queue.items.push({ name, payload, ...(key !== undefined ? { coalesceKey: key } : {}) })
    void this.pump(entryId, queue)
  }

  /** Drop queued events of an entry that went away. */
  forget(entryId: string): void { this.queues.delete(entryId) }

  /** Resolve once every queued event of this entry was handed to Core (or failed). */
  async flush(entryId: string): Promise<void> {
    const queue = this.queues.get(entryId)
    while (queue && (queue.items.length || queue.pumping)) await new Promise(resolve => setTimeout(resolve, 5))
  }

  private queue(entryId: string): EntryQueue {
    let queue = this.queues.get(entryId)
    if (!queue) this.queues.set(entryId, queue = new EntryQueue())
    return queue
  }

  private async pump(entryId: string, queue: EntryQueue): Promise<void> {
    if (queue.pumping) return
    queue.pumping = true
    try {
      while (queue.items.length) {
        // Leave the queue before sending: an in-flight event must not absorb later `latest` merges.
        const item = queue.items.shift()!
        const dropped = item.resync ? queue.dropped : 0
        if (item.resync) queue.dropped = 0
        const params: Record<string, unknown> = item.resync
          ? { name: resyncEventName, payload: { reason: 'queue_overflow', dropped } }
          : { name: item.name, payload: item.payload, ...(item.coalesceKey ? { coalesce_key: item.coalesceKey } : {}) }
        try {
          await this.core.request('host.event', params, { onBehalfOf: entryId })
        } catch (error) {
          if (error instanceof DittoError && error.reason === 'host_unavailable') return
          // An undeclared event (invalid_params) is a plugin bug; log and move on.
          this.log.warn('event rejected by Core', { entry_id: entryId, name: item.name, error })
        }
      }
    } finally {
      queue.pumping = false
    }
  }
}
