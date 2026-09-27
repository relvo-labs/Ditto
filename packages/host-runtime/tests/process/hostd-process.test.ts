import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { createServer, type Server } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { FakeCore } from '../../src/testing/fake-core.ts'
import { vendorFingerprint } from '../../src/version.ts'
import { fixtures } from '../helpers.ts'

/**
 * The bundled hostd as a real process: token over an inherited descriptor,
 * handshake, host.hello, a pushed entry, invoke through the lease, and exit
 * when Core goes away (hostd never exits on its own for being idle).
 */
const root = fileURLToPath(new URL('../../', import.meta.url))
const bundle = join(root, 'dist', 'ditto-hostd.mjs')
const scratch = mkdtempSync(join(tmpdir(), 'ditto-hostd-proc-'))
const socketPath = join(scratch, 'core.sock')
let server: Server
let core: Promise<FakeCore>
let child: ChildProcess
let stderr = ''

beforeAll(async () => {
  if (!existsSync(bundle)) {
    const built = spawnSync(process.execPath, [join(root, 'scripts', 'build.mjs')], { stdio: 'inherit' })
    if (built.status !== 0) throw new Error('hostd bundle did not build')
  }
  core = new Promise(resolve => {
    server = createServer(socket => resolve(new FakeCore(socket)))
  })
  await new Promise<void>(resolve => server.listen(socketPath, resolve))
  child = spawn(join(root, 'bin', 'ditto-hostd'), [], {
    stdio: ['ignore', 'ignore', 'pipe', 'pipe'],
    env: { ...process.env, DITTO_CORE_SOCKET: socketPath, DITTO_CORE_TOKEN_FD: '3', DITTO_DEV_PACKAGES: fixtures, XDG_DATA_HOME: scratch },
  })
  child.stderr!.on('data', chunk => { stderr += chunk })
  const tokenPipe = child.stdio[3] as NodeJS.WritableStream
  tokenPipe.end('launcher-token-from-fd\n')
})

afterAll(() => {
  child?.kill('SIGKILL')
  server?.close()
  rmSync(scratch, { recursive: true, force: true })
})

async function until(check: () => boolean, ms = 5_000) {
  const end = Date.now() + ms
  while (!check()) {
    if (Date.now() > end) throw new Error(`condition not reached; hostd stderr:\n${stderr}`)
    await new Promise(resolve => setTimeout(resolve, 10))
  }
}

describe('ditto-hostd process', () => {
  it('hands the token over the descriptor, handshakes as hostd and says hello with the bundle fingerprint', async () => {
    const fake = await core
    await until(() => fake.requests.some(request => request.method === 'host.hello'))
    const handshake = fake.requests.find(request => request.method === 'core.handshake')!.params
    expect(handshake).toMatchObject({ protocol_version: '0.2.0', client: { kind: 'hostd', version: '0.2.0' }, auth: { token: 'launcher-token-from-fd' } })
    const hello = fake.requests.find(request => request.method === 'host.hello')!.params
    expect(hello).toMatchObject({ hostd_version: '0.2.0', cordis_version: '4.0.4', strategy: 'isolate_rebuild', vendor_fingerprint: vendorFingerprint(join(root, 'vendor')) })
    // The launcher's PID is the PID that connected: the wrapper execs node.
    expect(child.pid).toBeGreaterThan(0)
  })

  it('loads nothing until Core pushes, then serves the pushed entry through its lease', async () => {
    const fake = await core
    expect((await fake.state()).observed.entries).toEqual([])
    const entry = (tag: string) => ({
      entry_id: 'ent-proc', package: 'test.process', version: '1.0.0', module_path: join(fixtures, 'process-plugin.mjs'),
      data_dir: join(scratch, 'plugin-data', 'test.process'), config: { tag, emit: true }, disabled: false,
      provides: ['plugin.test.process.get'], hot_swap: 'controlled_handoff' as const, health_timeout_ms: 2_000, cleanup_timeout_ms: 5_000, file_grants: {},
    })
    const { committed } = await fake.apply('chg-proc-1', [entry('one')])
    expect(committed!.items).toEqual([expect.objectContaining({ key: 'ent-proc', status: 'applied' })])
    expect(await fake.invoke('plugin.test.process.get')).toMatchObject({ tag: 'one', mode: 'active' })
    await until(() => fake.hostEvents.length > 0)
    expect(fake.hostEvents[0]).toMatchObject({ entryId: 'ent-proc', name: 'fixture/changed', payload: { tag: 'one' } })
    expect(fake.requests.some(request => request.method === 'host.entry_state')).toBe(true)
  })

  it('refuses a module_path outside the package store and the dev root', async () => {
    const fake = await core
    const prepared = await fake.prepare('chg-proc-bad', [{
      entry_id: 'ent-bad', package: 'test.bad', version: '1.0.0', module_path: '/etc/hostname', data_dir: join(scratch, 'x'),
      config: {}, disabled: false, provides: [], hot_swap: 'instant', health_timeout_ms: 2_000, cleanup_timeout_ms: 5_000, file_grants: {},
    }])
    expect(prepared.items[0]).toMatchObject({ status: 'failed', reason: expect.stringMatching(/^module_load_failed: module_path is outside the package store/) })
    await fake.abort('chg-proc-bad')
  })

  it('with every entry removed it keeps running and heartbeating: hostd never exits for being idle (Core decides reclaim)', async () => {
    const fake = await core
    const { committed } = await fake.apply('chg-proc-empty', [])
    expect(committed!.items).toEqual([expect.objectContaining({ key: 'ent-proc', status: 'applied' })])
    expect((await fake.state()).observed.entries).toEqual([])
    expect(fake.bindings.size).toBe(0)
    const beats = fake.heartbeats.length
    await new Promise(resolve => setTimeout(resolve, 2_300))
    expect(child.exitCode).toBeNull()
    expect(fake.heartbeats.length).toBeGreaterThan(beats)
  })

  it('exits when the Core connection closes', async () => {
    const fake = await core
    const exited = new Promise<number | null>(resolve => child.once('exit', code => resolve(code)))
    fake.disconnect()
    expect(await exited).toBe(1)
    expect(stderr).toMatch(/Core connection closed/)
  })
})
