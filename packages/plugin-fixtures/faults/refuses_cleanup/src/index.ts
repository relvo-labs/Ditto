import { defineDittoPlugin } from '@ditto/host-sdk'

/** Fault fixture: an async disposer that never resolves. Cleanup must time out and mark the entry faulted. */
export default defineDittoPlugin({
  name: 'ditto-fixture-refuses-cleanup',
  apply(ctx) {
    ctx.ditto.capabilities.register({ id: 'plugin.ditto.fixture.fault_refuses_cleanup.get', version: '1.0.0', handler: () => ({}) })
    ctx.effect(() => () => new Promise<void>(() => {}), 'fixture: cleanup that never ends')
  },
})
