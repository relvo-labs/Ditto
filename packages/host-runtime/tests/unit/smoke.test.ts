import { afterEach, describe, expect, it } from 'vitest'
import type { TestHost } from '../../src/testing/index.ts'
import { changeId, fixture, host } from '../helpers.ts'

let h: TestHost
afterEach(async () => { await h?.close() })

describe('smoke', () => {
  it('prepares, commits and routes an invoke', async () => {
    h = await host()
    const entry = h.entry({ entry_id: 'ent-a', module_path: fixture('generic'), config: { tag: 'a', register: ['plugin.test.a.get'] }, provides: ['plugin.test.a.get'] })
    const { prepared, committed } = await h.core.apply(changeId(), [entry])
    expect(prepared.items).toEqual([{ key: 'ent-a', status: 'ready' }])
    expect(committed!.items[0]).toMatchObject({ key: 'ent-a', status: 'applied' })
    expect(await h.core.invoke('plugin.test.a.get')).toMatchObject({ tag: 'a' })
    const state = await h.core.state()
    expect(state.observed.entries).toEqual([{ entry_id: 'ent-a', fiber_state: 'active', mode: 'active' }])
  })
})
