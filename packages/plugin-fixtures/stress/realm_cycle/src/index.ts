import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * Stress fixture for EX1-04 ③ and L-04: a plugin that provides a Cordis
 * service, so the isolate_rebuild strategy mounts its candidate in an isolate
 * realm. It also registers a capability and holds timers, so a candidate that
 * is not cleaned up shows in the fiber, effect, timer and registration counts.
 *
 * With `refuse_as_candidate` its health check fails while it is a candidate:
 * the change aborts after prepare, so each proposal mounts the plugin in an
 * isolate realm and takes it down again without touching the main realm.
 * Never shipped; packed only with DITTO_PACK_FIXTURES=1.
 */
export interface RealmCycleConfig {
  refuse_as_candidate?: boolean
  timers?: number
}

export default defineDittoPlugin<RealmCycleConfig>({
  name: 'ditto-fixture-realm-cycle',
  services: ['realmCycle'],
  apply(ctx, config) {
    let calls = 0
    ctx.provide('realmCycle', { next: () => ++calls })
    ctx.ditto.capabilities.register({
      id: 'plugin.ditto.fixture.realm_cycle.get',
      version: '1.0.0',
      handler: () => ({ mode: ctx.ditto.mode, calls }),
    })
    for (let i = 0; i < (config?.timers ?? 2); i++) {
      ctx.effect(() => {
        const timer = setInterval(() => {}, 60_000)
        return () => clearInterval(timer)
      }, `ctx.interval(realm-cycle-${i})`)
    }
    if (config?.refuse_as_candidate) {
      ctx.ditto.lifecycle.health(() => ctx.ditto.mode === 'candidate'
        ? { healthy: false, detail: 'realm-cycle fixture refuses to leave the candidate realm' }
        : { healthy: true })
    }
  },
})
