import { defineDittoPlugin } from '@ditto/host-sdk'

/** Fault fixture: cleanup takes 2 s (configurable). A second mount must wait for it. */
export default defineDittoPlugin<{ delayMs?: number }>({
  name: 'ditto-fixture-slow-disposer',
  apply(ctx, config) {
    const delay = config?.delayMs ?? 2_000
    ctx.ditto.capabilities.register({ id: 'plugin.ditto.fixture.fault_slow_disposer.get', version: '1.0.0', handler: () => ({ delay }) })
    ctx.effect(() => () => new Promise<void>(resolve => setTimeout(resolve, delay)), 'fixture: slow cleanup')
  },
})
