import { mkdirSync, writeFileSync } from 'node:fs'
import { cpus } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import type { Strategy } from '../../src/loader/transaction.ts'
import { changeId, fixture, host } from '../helpers.ts'

/**
 * D-32 trial (.agents/notes/decisions/2026-09-27-d32-host-candidate-strategy.md).
 * Development evidence only: this machine, in-process fake Core. Run with
 * DITTO_D32_TRIAL=1; raw numbers go to artifacts/g1-dev/.
 */
const enabled = process.env['DITTO_D32_TRIAL'] === '1'
const runs = Number(process.env['DITTO_D32_RUNS'] ?? 100)
const out = fileURLToPath(new URL('../../../../artifacts/g1-dev/', import.meta.url))

function percentile(values: number[], p: number): number {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)]!
}

async function trial(strategy: Strategy) {
  const h = await host({ strategy, pendingWaitMs: 3_000 })
  const entries = (tag: string) => [
    h.entry({ entry_id: 'ent-svc', module_path: fixture('provider'), config: { tag, capability: 'plugin.test.svc.get' }, provides: ['plugin.test.svc.get'] }),
    h.entry({ entry_id: 'ent-use', module_path: fixture('consumer'), config: { tag: 'use', capability: 'plugin.test.use.get' }, provides: ['plugin.test.use.get'] }),
  ]
  await h.core.apply(changeId(), entries('v0'))
  const commitMs: number[] = []
  const prepareMs: number[] = []
  const gapMs: number[] = []
  const failures: unknown[] = []
  for (let i = 1; i <= runs; i++) {
    const id = changeId()
    const tag = `v${i}`
    const prepared = await h.core.prepare(id, entries(tag))
    if (prepared.items.some(item => item.status !== 'ready')) {
      failures.push({ run: i, phase: 'prepare', items: prepared.items })
      await h.core.abort(id)
      continue
    }
    const committed = await h.core.commit(id)
    const timings = h.runtime.tx.timings(id)!
    prepareMs.push(timings.prepareMs!)
    commitMs.push(timings.commitMs!)
    const gap = timings.gaps['ent-svc']
    if (gap !== undefined) gapMs.push(gap)
    if (committed.items.some(item => item.status !== 'applied')) failures.push({ run: i, phase: 'commit', items: committed.items })
    const served = await h.core.invoke('plugin.test.use.get') as { via: string }
    if (served.via !== tag) failures.push({ run: i, phase: 'readback', served })
  }
  const result = {
    strategy,
    runs,
    evidence: 'development (this machine, createTestHost in-process fake Core); not reference-machine exit evidence',
    node: process.versions.node,
    cpu: cpus()[0]?.model,
    at: new Date().toISOString(),
    commit_ms: { p50: percentile(commitMs, 50), p95: percentile(commitMs, 95), max: Math.max(...commitMs) },
    prepare_ms: { p50: percentile(prepareMs, 50), p95: percentile(prepareMs, 95), max: Math.max(...prepareMs) },
    gap_ms: gapMs.length ? { p50: percentile(gapMs, 50), p95: percentile(gapMs, 95), max: Math.max(...gapMs) } : null,
    candidate_healthy_rebuild_unhealthy: h.runtime.tx.stats.candidateHealthyRebuildUnhealthy,
    failures,
    raw: { commit_ms: commitMs, prepare_ms: prepareMs, gap_ms: gapMs },
  }
  await h.close()
  return result
}

describe.skipIf(!enabled)('D-32 trial', () => {
  it('measures both strategies', async () => {
    mkdirSync(out, { recursive: true })
    const results = []
    for (const strategy of ['isolate_rebuild', 'in_place'] as const) results.push(await trial(strategy))
    const stamp = new Date().toISOString().replace(/[:.]/g, '-')
    writeFileSync(join(out, `d32-trial-${stamp}.json`), JSON.stringify(results, null, 2) + '\n')
    for (const result of results) {
      const { raw: _raw, ...summary } = result
      console.log(JSON.stringify(summary))
    }
    expect(results.every(result => result.failures.length === 0)).toBe(true)
  }, 600_000)
})

/** Same replacement loop against the real bundled hostd over a Unix socket (test build, so the strategy can be chosen). */
async function processTrial(strategy: Strategy, plugin: 'fixture' | 'svc-tasks' = 'fixture') {
  const { spawn } = await import('node:child_process')
  const { createServer } = await import('node:net')
  const { mkdtempSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { FakeCore } = await import('../../src/testing/fake-core.ts')
  const { fixtures, packagesDir } = await import('../helpers.ts')
  const { writeFileSync } = await import('node:fs')
  const root = fileURLToPath(new URL('../../', import.meta.url))
  const scratch = mkdtempSync(join(tmpdir(), 'ditto-d32-'))
  const socketPath = join(scratch, 'core.sock')
  let resolveCore!: (core: InstanceType<typeof FakeCore>) => void
  const corePromise = new Promise<InstanceType<typeof FakeCore>>(resolve => { resolveCore = resolve })
  const server = createServer(socket => resolveCore(new FakeCore(socket)))
  await new Promise<void>(resolve => server.listen(socketPath, resolve))
  const child = spawn(process.execPath, [join(root, 'dist', 'ditto-hostd-fault.mjs')], {
    stdio: ['ignore', 'ignore', 'inherit'],
    env: { ...process.env, DITTO_CORE_SOCKET: socketPath, DITTO_DEV_TOKEN: 'trial', DITTO_DEV_PACKAGES: `${fixtures}:${packagesDir}plugins/`, XDG_DATA_HOME: scratch, DITTO_HOST_STRATEGY: strategy },
  })
  const core = await corePromise
  while (!core.requests.some(request => request.method === 'host.hello')) await new Promise(resolve => setTimeout(resolve, 5))
  const todo = join(scratch, 'todo.txt')
  writeFileSync(todo, '(A) 繳電話費\nx 買牛奶\n')
  const entry = (tag: string): import('../../src/loader/projection.ts').HostEntrySpec => plugin === 'fixture' ? {
    entry_id: 'ent-svc', package: 'test.process', version: '1.0.0', module_path: join(fixtures, 'process-plugin.mjs'),
    data_dir: join(scratch, 'data'), config: { tag }, disabled: false, provides: ['plugin.test.process.get'],
    hot_swap: 'controlled_handoff' as const, health_timeout_ms: 2_000, cleanup_timeout_ms: 5_000, file_grants: {},
  } : {
    // The real tasks service: file grant, fs.watch, data area, controlled handoff. The demo flag flips so each run is a replacement.
    entry_id: 'ent-svc', package: 'ditto.svc.tasks', version: '1.0.0', module_path: `${packagesDir}plugins/svc-tasks/dist/index.mjs`,
    data_dir: join(scratch, 'plugin-data', 'ditto.svc.tasks'), config: { source: { kind: 'todo_txt', path_grant: 'grant-todo' }, demo: Number(tag.slice(1)) % 2 === 1 },
    disabled: false, provides: ['desktop.tasks.list', 'desktop.tasks.add', 'desktop.tasks.complete', 'desktop.tasks.subscribe'],
    hot_swap: 'controlled_handoff' as const, health_timeout_ms: 2_000, cleanup_timeout_ms: 5_000, file_grants: { 'grant-todo': todo },
  }
  await core.apply('chg-p0', [entry('v0')])
  const commitMs: number[] = []
  const failures: unknown[] = []
  for (let i = 1; i <= runs; i++) {
    const prepared = await core.prepare(`chg-p${i}`, [entry(`v${i}`)])
    if (prepared.items.some(item => item.status !== 'ready')) { failures.push({ run: i, prepared }); await core.abort(`chg-p${i}`); continue }
    const started = performance.now()
    const committed = await core.commit(`chg-p${i}`)
    commitMs.push(performance.now() - started)
    if (committed.items.some(item => item.status !== 'applied')) failures.push({ run: i, committed })
    if (plugin === 'fixture') {
      const served = await core.invoke('plugin.test.process.get') as { tag: string }
      if (served.tag !== `v${i}`) failures.push({ run: i, served })
    } else {
      const served = await core.invoke('desktop.tasks.list') as { demo: boolean; sources: { source: string; status: string }[] }
      if (served.sources[0]?.status !== 'ok') failures.push({ run: i, served })
    }
  }
  child.kill('SIGTERM')
  server.close()
  rmSync(scratch, { recursive: true, force: true })
  return {
    strategy, plugin, runs, transport: 'unix socket, bundled hostd (test build)', measured_at: 'fake Core: participant.commit sent → answer received',
    evidence: 'development (this machine); not reference-machine exit evidence',
    commit_ms: { p50: percentile(commitMs, 50), p95: percentile(commitMs, 95), max: Math.max(...commitMs) },
    failures, raw: { commit_ms: commitMs },
  }
}

describe.skipIf(!enabled)('D-32 trial through the hostd process', () => {
  it('measures both strategies over the socket', async () => {
    const { existsSync } = await import('node:fs')
    const { spawnSync } = await import('node:child_process')
    const root = fileURLToPath(new URL('../../', import.meta.url))
    if (!existsSync(join(root, 'dist', 'ditto-hostd-fault.mjs'))) {
      spawnSync(process.execPath, [join(root, 'scripts', 'build.mjs')], { env: { ...process.env, DITTO_HOST_FAULT_ENABLE: '1' }, stdio: 'inherit' })
    }
    const results = []
    for (const plugin of ['fixture', 'svc-tasks'] as const) {
      for (const strategy of ['isolate_rebuild', 'in_place'] as const) results.push(await processTrial(strategy, plugin))
    }
    mkdirSync(out, { recursive: true })
    writeFileSync(join(out, `d32-trial-process-${new Date().toISOString().replace(/[:.]/g, '-')}.json`), JSON.stringify(results, null, 2) + '\n')
    for (const result of results) {
      const { raw: _raw, ...summary } = result
      console.log(JSON.stringify(summary))
    }
    expect(results.every(result => result.failures.length === 0)).toBe(true)
  }, 600_000)
})
