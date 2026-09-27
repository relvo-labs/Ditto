import type { FiberState as VendoredFiberState } from '@deepseek-ai/cordis'

/**
 * Runtime mirror of Cordis `FiberState`. Upstream declares it as a `const enum`,
 * which a bundle cannot read across packages; the values are pinned by
 * tests/pinning/fiber-state.test.ts against the vendored source.
 */
export const FiberState = {
  PENDING: 0 as VendoredFiberState.PENDING,
  LOADING: 1 as VendoredFiberState.LOADING,
  ACTIVE: 2 as VendoredFiberState.ACTIVE,
  FAILED: 3 as VendoredFiberState.FAILED,
  DISPOSED: 4 as VendoredFiberState.DISPOSED,
  UNLOADING: 5 as VendoredFiberState.UNLOADING,
} as const

export type FiberStateName = 'pending' | 'loading' | 'active' | 'failed' | 'disposed' | 'unloading'

const names: Record<number, FiberStateName> = {
  [FiberState.PENDING]: 'pending',
  [FiberState.LOADING]: 'loading',
  [FiberState.ACTIVE]: 'active',
  [FiberState.FAILED]: 'failed',
  [FiberState.DISPOSED]: 'disposed',
  [FiberState.UNLOADING]: 'unloading',
}

export function fiberStateName(state: number): FiberStateName {
  const name = names[state]
  if (!name) throw new TypeError(`unknown fiber state ${state}`)
  return name
}
