import type { Context } from '@deepseek-ai/cordis'
import type {} from '../../src/api.ts'
import { record } from './probe.ts'

declare module '@deepseek-ai/cordis' {
  interface Context { counter: { tag: string; next(): number } }
}

/** Injects `counter`; re-registers its capability whenever it restarts. */
export interface ConsumerConfig { tag: string; capability?: string; throwInDispose?: boolean }

export const name = 'fixture-consumer'
export const inject = ['ditto', 'counter']

export function apply(ctx: Context, config: ConsumerConfig) {
  record('apply', config.tag, { provider: ctx.counter.tag })
  if (config.capability) {
    ctx.ditto.capabilities.register({ id: config.capability, version: '1.0.0', handler: () => ({ via: ctx.counter.tag, n: ctx.counter.next() }) })
  }
  ctx.effect(() => () => {
    record('disposed', config.tag)
    if (config.throwInDispose) throw new Error(`consumer ${config.tag} disposer failed`)
  }, 'fixture-consumer cleanup')
}
