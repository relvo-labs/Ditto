import { fileURLToPath } from 'node:url'
import { createTestHost, type TestHost, type TestHostOptions } from '../src/testing/index.ts'
import { resetProbe } from './fixtures/probe.ts'

export const fixtures = fileURLToPath(new URL('./fixtures/', import.meta.url))
export const packagesDir = fileURLToPath(new URL('../../', import.meta.url))
export const fixture = (name: string) => `${fixtures}${name}.ts`
export const pluginFixture = (path: string) => `${packagesDir}plugin-fixtures/${path}`

/** D-32 trial runs the suite once per strategy; the default is the proposal's A. */
export const strategy = (process.env['DITTO_TEST_STRATEGY'] ?? 'isolate_rebuild') as 'isolate_rebuild' | 'in_place'

export async function host(options: Partial<TestHostOptions> = {}): Promise<TestHost> {
  resetProbe()
  return createTestHost({ packageRoots: [fixtures, `${packagesDir}plugin-fixtures/`, `${packagesDir}plugins/`, `${packagesDir}host-sdk/`], strategy, pendingWaitMs: 500, ...options })
}

let sequence = 0
export const changeId = () => `chg-${++sequence}`
