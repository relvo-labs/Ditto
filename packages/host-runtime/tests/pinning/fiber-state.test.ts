import * as cordis from '@deepseek-ai/cordis'
import { FiberState as Vendored } from '@deepseek-ai/cordis'
import { describe, expect, it } from 'vitest'
import { FiberState, fiberStateName } from '../../src/fiber-state.ts'

/** Upstream `FiberState` is a const enum; hostd mirrors it. A sync that renumbers it must fail here. */
describe('FiberState mirror', () => {
  it('matches the vendored values', () => {
    expect(FiberState.PENDING).toBe(Vendored.PENDING)
    expect(FiberState.LOADING).toBe(Vendored.LOADING)
    expect(FiberState.ACTIVE).toBe(Vendored.ACTIVE)
    expect(FiberState.FAILED).toBe(Vendored.FAILED)
    expect(FiberState.DISPOSED).toBe(Vendored.DISPOSED)
    expect(FiberState.UNLOADING).toBe(Vendored.UNLOADING)
    // Test builds compile the const enum to an object; a state added upstream shows up here.
    const vendoredNames = Object.keys((cordis as unknown as Record<string, object>)['FiberState']!).filter(key => Number.isNaN(Number(key)))
    expect(vendoredNames.sort()).toEqual(Object.keys(FiberState).sort())
  })

  it('names every state and refuses unknown ones', () => {
    expect(Object.values(FiberState).map(fiberStateName)).toEqual(['pending', 'loading', 'active', 'failed', 'disposed', 'unloading'])
    expect(() => fiberStateName(9)).toThrow(TypeError)
  })
})
