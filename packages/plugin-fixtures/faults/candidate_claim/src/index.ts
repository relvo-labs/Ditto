import { defineDittoPlugin } from '@ditto/host-sdk'

/**
 * Fault fixture: registers a capability and then forces a claim while still a
 * candidate. Registration must stay local; the forced claim must be refused by
 * Core with conflict(candidate_cannot_claim).
 */
export default defineDittoPlugin({
  name: 'ditto-fixture-candidate-claim',
  async apply(ctx) {
    ctx.ditto.capabilities.register({ id: 'plugin.ditto.fixture.fault_candidate_claim.get', version: '1.0.0', handler: () => ({}) })
    const attempts: { via: string; outcome: string }[] = []
    for (const [via, method, input] of [
      ['shortcut', 'desktop.shortcuts.bind', { chord: 'Super+K', command: 'fixture.claim' }],
      ['raw_register', 'host.capability.register', { capability_id: 'plugin.ditto.fixture.fault_candidate_claim.get', version: '1.0.0' }],
    ] as const) {
      try {
        await ctx.ditto.capabilities.call(method, input)
        attempts.push({ via, outcome: 'claimed' })
      } catch (error) {
        attempts.push({ via, outcome: String((error as { data?: { reason?: string } }).data?.reason ?? (error as Error).message) })
      }
    }
    ;(globalThis as Record<symbol, unknown>)[Symbol.for('ditto.fixture.candidate_claim')] = { mode: ctx.ditto.mode, attempts }
  },
})
