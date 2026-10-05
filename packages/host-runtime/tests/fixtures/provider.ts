import type { Context } from '@deepseek-ai/cordis'
import type {} from '../../src/api.ts'
import { record } from './probe.ts'

/** Provides the Cordis service `counter`; the tag in config tells A from B. */
export interface ProviderConfig { tag: string; throwInApply?: boolean; unhealthy?: boolean; disposeDelayMs?: number; capability?: string }

export const name = 'fixture-provider'
export const inject = ['ditto']
export const services = ['counter']

export function apply(ctx: Context, config: ProviderConfig) {
  if (config.throwInApply) throw new Error(`provider ${config.tag} refuses to start`)
  let n = 0
  const counter = { tag: config.tag, next: () => ++n }
  ctx.provide('counter', counter)
  record('apply', config.tag, { mode: ctx.ditto.mode })
  if (config.capability) {
    ctx.ditto.capabilities.register({ id: config.capability, version: '1.0.0', handler: () => ({ tag: config.tag, n: counter.next() }) })
  }
  if (config.unhealthy) ctx.ditto.lifecycle.health(() => ({ healthy: false, detail: 'fixture says no' }))
  ctx.effect(() => async () => {
    if (config.disposeDelayMs) await new Promise(resolve => setTimeout(resolve, config.disposeDelayMs))
    record('disposed', config.tag)
  }, 'fixture-provider cleanup')
}
