import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { duplexPair } from 'node:stream'
import { CoreLink, type HelloResult } from '../bridge/core-link.ts'
import type { FaultPoint } from '../fault.ts'
import { ModulePolicy } from '../loader/module-policy.ts'
import type { HostEntrySpec, HotSwap } from '../loader/projection.ts'
import type { Strategy } from '../loader/transaction.ts'
import { HostLog, type LogRecord } from '../log.ts'
import { HostRuntime } from '../runtime.ts'
import { FakeCore, type FakeCoreOptions } from './fake-core.ts'

export interface TestHostOptions extends FakeCoreOptions {
  /** Directories plugin modules may be loaded from (the package store in production). */
  packageRoots: string[]
  strategy?: Strategy
  pendingWaitMs?: number
  drainTimeoutMs?: number
  intervals?: Partial<{ heartbeatMs: number; renewMs: number; resourcesMs: number; entryStateMs: number }>
  /** Host fault points without environment variables (the process-level DITTO_HOST_FAULT is for Rust tests). */
  faults?: Partial<Record<FaultPoint, () => Promise<void> | void>>
  /** Start heartbeat, renew and resource timers (off by default to keep tests deterministic). */
  background?: boolean
}

export interface EntryInput {
  entry_id: string
  module_path: string
  package?: string
  version?: string
  config?: HostEntrySpec['config']
  disabled?: boolean
  provides?: string[]
  hot_swap?: HotSwap
  health_timeout_ms?: number
  cleanup_timeout_ms?: number
  data_dir?: string
  file_grants?: Record<string, string>
}

export interface TestHost {
  core: FakeCore
  runtime: HostRuntime
  hello: HelloResult
  logs: LogRecord[]
  dataRoot: string
  /** Fill in the projection fields a test does not care about. */
  entry(input: EntryInput): HostEntrySpec
  close(): Promise<void>
}

/**
 * In-process Cordis plus a fake Core, joined by the real framing and bridge
 * code over an in-memory socket pair. Plugin authors and the L-01…L-10
 * contract tests use the same host.
 */
export async function createTestHost(options: TestHostOptions): Promise<TestHost> {
  const [hostSide, coreSide] = duplexPair()
  const core = new FakeCore(coreSide, options)
  const link = CoreLink.overStream(hostSide)
  const logs: LogRecord[] = []
  const log = new HostLog(record => { logs.push(record) }, { component: 'test-hostd' })
  const faults = options.faults
  const runtime = new HostRuntime({
    core: link,
    policy: new ModulePolicy(options.packageRoots),
    log,
    ...(options.strategy ? { strategy: options.strategy } : {}),
    ...(options.pendingWaitMs !== undefined ? { pendingWaitMs: options.pendingWaitMs } : {}),
    ...(options.drainTimeoutMs !== undefined ? { drainTimeoutMs: options.drainTimeoutMs } : {}),
    ...(options.intervals ? { intervals: options.intervals } : {}),
    ...(faults ? { faults: async (point: FaultPoint) => { await faults[point]?.() } } : { faults: async () => {} }),
  })
  link.attach({
    request: (method, params) => runtime.handleRequest(method, params),
    notification: (method, params) => runtime.handleNotification(method, params),
    closed: () => {},
  })
  await runtime.start()
  await link.handshake('test-token', { kind: 'hostd', version: '0.2.0' })
  const hello = await link.request<HelloResult>('host.hello', runtime.helloParams())
  if (options.background) runtime.startBackground(hello)
  const dataRoot = mkdtempSync(join(tmpdir(), 'ditto-testhost-'))

  return {
    core,
    runtime,
    hello,
    logs,
    dataRoot,
    entry: input => ({
      package: input.package ?? `test.${input.entry_id}`,
      version: input.version ?? '1.0.0',
      config: input.config ?? {},
      disabled: input.disabled ?? false,
      provides: input.provides ?? [],
      hot_swap: input.hot_swap ?? 'controlled_handoff',
      health_timeout_ms: input.health_timeout_ms ?? 2_000,
      cleanup_timeout_ms: input.cleanup_timeout_ms ?? 5_000,
      data_dir: input.data_dir ?? join(dataRoot, input.entry_id),
      file_grants: input.file_grants ?? {},
      entry_id: input.entry_id,
      module_path: input.module_path,
    }),
    close: async () => {
      await runtime.stop()
      link.close()
      rmSync(dataRoot, { recursive: true, force: true })
    },
  }
}

export { FakeCore }
