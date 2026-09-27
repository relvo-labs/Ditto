import type { Context } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import type {} from '../../src/api.ts'
import { probe, record } from './probe.ts'

/** A plugin whose behaviour is chosen by config, so one module plays many parts. */
export interface GenericConfig {
  tag: string
  register?: string[]
  disposeDelayMs?: number
  disposeGate?: string
  subscribe?: string[]
  timers?: number
  emit?: string
  claim?: string
  state?: number
  rules?: { threshold: number }
}

export const name = 'fixture-generic'
export const inject = ['ditto']
export const events = [{ name: 'fixture/changed', coalesce: 'latest' }]

export const Config = Schema.object({
  tag: Schema.string().required(),
  register: Schema.array(Schema.string()),
  disposeDelayMs: Schema.number(),
  disposeGate: Schema.string(),
  subscribe: Schema.array(Schema.string()),
  timers: Schema.number(),
  emit: Schema.string(),
  claim: Schema.string(),
  state: Schema.number(),
  rules: Schema.object({ threshold: Schema.number().default(3) }).volatile(),
})

export async function apply(ctx: Context, config: GenericConfig & { rules?: { get(): { threshold: number } } }) {
  record('apply', config.tag, { mode: ctx.ditto.mode })
  let state = config.state ?? 0
  for (const id of config.register ?? []) {
    ctx.ditto.capabilities.register({ id, version: '1.0.0', handler: () => ({ tag: config.tag, state, threshold: config.rules?.get().threshold }) })
  }
  for (let i = 0; i < (config.timers ?? 0); i++) {
    ctx.effect(() => {
      const timer = setInterval(() => {}, 60_000)
      return () => clearInterval(timer)
    }, `ctx.interval(fixture-${i})`)
  }
  if (config.subscribe) ctx.ditto.events.subscribe(config.subscribe, event => record('event', config.tag, event))
  if (config.emit) ctx.ditto.events.emit(config.emit, { tag: config.tag })
  if (config.claim) {
    try {
      await ctx.ditto.capabilities.call(config.claim, { chord: 'Super+K' })
      record('claimed', config.tag)
    } catch (error) {
      record('claim-refused', config.tag, (error as { data?: unknown }).data)
    }
  }
  ctx.ditto.lifecycle.exportState(() => ({ state }))
  ctx.ditto.lifecycle.importState(imported => {
    state = (imported as { state: number }).state
    record('imported', config.tag, imported)
  })
  ctx.on('loader/volatile-update' as never, ((paths: string[][]) => record('volatile', config.tag, paths)) as never)
  ctx.effect(() => async () => {
    if (config.disposeDelayMs) await new Promise(resolve => setTimeout(resolve, config.disposeDelayMs))
    if (config.disposeGate) await probe().gates.get(config.disposeGate)
    record('disposed', config.tag)
  }, 'fixture-generic cleanup')
}
