import type { EffectMeta } from '@deepseek-ai/cordis'
import { FiberState, fiberStateName, type FiberStateName } from './fiber-state.ts'
import type { Instance } from './loader/instance.ts'

/**
 * `host.resources` (host-protocol §8). The three V8 numbers are reported side
 * by side and never summed, and never added to PSS: process PSS/RSS/CPU come
 * from Core reading /proc, not from hostd (NFR-15, RUN-08).
 */
export interface NodeResources {
  heap_used: number
  external: number
  array_buffers: number
}

export function nodeResources(): NodeResources {
  const usage = process.memoryUsage()
  return { heap_used: usage.heapUsed, external: usage.external, array_buffers: usage.arrayBuffers }
}

export interface EntryStateReport {
  entry_id: string
  fiber_state: FiberStateName
  mode: 'candidate' | 'active'
  waiting_for: string[]
  failure?: string
  effects: number
  timers: number
  subscriptions: number
  capabilities: number
}

function flatten(effects: EffectMeta[]): EffectMeta[] {
  return effects.flatMap(effect => [effect, ...flatten(effect.children)])
}

/** Services an instance's fiber is waiting for. PENDING is "waiting for these", never an error. */
export function waitingFor(instance: Instance): string[] {
  const fiber = instance.fiber
  if (!fiber || fiber.state !== FiberState.PENDING) return []
  return Object.keys(fiber.inject).filter(name => !fiber.ctx.reflect._getImpl(name, true))
}

/** Counts only: an in-process plugin has no memory number of its own (RUN-08). */
export function entryState(instance: Instance): EntryStateReport {
  const fiber = instance.fiber
  const state = instance.failure ? 'failed' : fiber ? fiberStateName(fiber.state) : 'pending'
  const effects = fiber ? flatten(fiber.getEffects()) : []
  const waiting = waitingFor(instance)
  return {
    entry_id: instance.entryId,
    fiber_state: state,
    mode: instance.mode,
    waiting_for: waiting,
    ...(instance.failure ? { failure: instance.failure } : {}),
    effects: effects.length,
    timers: effects.filter(effect => /^ctx\.(timeout|interval)\(/.test(effect.label)).length,
    subscriptions: instance.subscriptions.size,
    capabilities: instance.registrations.size,
  }
}
