import { afterEach, describe, expect, it } from 'vitest'
import type { TestHost } from '../../src/testing/index.ts'
import { changeId, fixture, host, pluginFixture, strategy } from '../helpers.ts'

/** L-03 重複註冊 (plan/03/06 §3, plan/03/03 §4.3). */
let h: TestHost
afterEach(async () => { await h?.close() })

const capability = 'plugin.test.x.get'

function x(h: TestHost, tag: string) {
  return h.entry({ entry_id: 'ent-x', module_path: fixture('generic'), config: { tag, register: [capability] }, provides: [capability] })
}

describe('L-03 duplicate registration', () => {
  it('positive: candidate and active declare the same single-provider capability → one binding before commit and one after', async () => {
    h = await host()
    await h.core.apply(changeId(), [x(h, 'x1')])
    const before = h.core.bindingOf(capability)!
    const registerCalls = () => h.core.requests.filter(request => request.method === 'host.capability.register').length
    const callsBefore = registerCalls()

    const id = changeId()
    const prepared = await h.core.prepare(id, [x(h, 'x2')])
    expect(prepared.items[0]).toMatchObject({ status: 'ready' })
    // Prepared: the candidate (strategy A) recorded its registration locally and sent nothing.
    expect(registerCalls()).toBe(callsBefore)
    expect([...h.core.bindings.values()].filter(binding => binding.capabilityId === capability)).toHaveLength(1)
    expect(h.core.bindingOf(capability)!.leaseId).toBe(before.leaseId)
    if (strategy === 'isolate_rebuild') {
      const [candidate] = h.runtime.tx.instancesOf('ent-x').filter(instance => instance.realm === 'candidate')
      expect(candidate!.mode).toBe('candidate')
      expect(candidate!.registrations.get(capability)!.leaseId).toBeUndefined()
    }
    expect(await h.core.invoke(capability)).toMatchObject({ tag: 'x1' })

    await h.core.commit(id)
    const bound = [...h.core.bindings.values()].filter(binding => binding.capabilityId === capability)
    expect(bound).toHaveLength(1)
    expect(bound[0]!.leaseId).not.toBe(before.leaseId)
    expect(h.core.revokedLeases.has(before.leaseId)).toBe(true)
    expect(await h.core.invoke(capability)).toMatchObject({ tag: 'x2' })
  })

  it('negative: a candidate forcing a claim (shortcut bind, raw host.capability.register) gets conflict(candidate_cannot_claim)', async () => {
    h = await host()
    const id = changeId()
    const entry = h.entry({ entry_id: 'ent-claim', module_path: pluginFixture('faults/candidate_claim/src/index.ts'), provides: ['plugin.ditto.fixture.fault_candidate_claim.get'] })
    const prepared = await h.core.prepare(id, [entry])
    const result = (globalThis as Record<symbol, { mode: string; attempts: { via: string; outcome: string }[] } | undefined>)[Symbol.for('ditto.fixture.candidate_claim')]
    if (strategy === 'isolate_rebuild') {
      expect(prepared.items[0]).toMatchObject({ status: 'ready' })
      expect(result).toEqual({
        mode: 'candidate',
        attempts: [{ via: 'shortcut', outcome: 'candidate_cannot_claim' }, { via: 'raw_register', outcome: 'candidate_cannot_claim' }],
      })
      expect(h.core.bindings.size).toBe(0)
      await h.core.abort(id)
    } else {
      // Strategy B mounts nothing before commit, so there is no candidate to make the claim.
      expect(prepared.items[0]).toMatchObject({ status: 'ready' })
      await h.core.abort(id)
    }
    expect(h.core.bindings.size).toBe(0)
    // The only register that reached Core was the forced raw call, and Core refused it.
    expect(h.core.requests.filter(request => request.method === 'host.capability.register')).toHaveLength(strategy === 'isolate_rebuild' ? 1 : 0)
  })
})
