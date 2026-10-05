import { defineCapability, defineDittoPlugin } from '@ditto/host-sdk'

declare module '@deepseek-ai/cordis' {
  interface Context {
    dittoExampleCounter: { value(): number; add(step: number): number }
  }
}

/**
 * The smallest useful Ditto service plugin. Everything it holds is released by
 * Cordis effects; its state crosses a replacement only as exported data.
 */
export default defineDittoPlugin<{ step?: number }>({
  name: 'ditto-example-counter',
  services: ['dittoExampleCounter'],
  events: [{ name: 'counter/changed', coalesce: 'latest' }],
  apply(ctx, config) {
    const step = config?.step ?? 1
    let value = 0
    let accepting = true

    // A Cordis service other plugins can `inject`. Registered as an effect: gone on unload.
    ctx.provide('dittoExampleCounter', {
      value: () => value,
      add: (by: number) => (value += by),
    })

    ctx.ditto.capabilities.register(defineCapability({
      id: 'plugin.ditto.example.counter.get',
      version: '1.0.0',
      handler: () => ({ value }),
    }))
    ctx.ditto.capabilities.register(defineCapability<Record<string, never>, { value: number }>({
      id: 'plugin.ditto.example.counter.increment',
      version: '1.0.0',
      handler: () => {
        if (!accepting) throw new Error('draining')
        value += step
        ctx.ditto.events.emit('counter/changed', { value })
        return { value }
      },
    }))

    // Controlled handoff: stop taking work, hand over data (never objects or closures).
    ctx.ditto.lifecycle.onDrain(() => { accepting = false })
    ctx.ditto.lifecycle.exportState(() => ({ value }))
    ctx.ditto.lifecycle.importState(state => { value = (state as { value: number }).value })
    ctx.ditto.lifecycle.health(() => ({ healthy: Number.isFinite(value) }))
  },
})
