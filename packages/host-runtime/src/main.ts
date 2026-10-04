import { closeSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { CoreLink, type HelloResult } from './bridge/core-link.ts'
import { describe } from './errors.ts'
import { faultsCompiledIn } from './fault.ts'
import type { Strategy } from './loader/transaction.ts'
import { ModulePolicy } from './loader/module-policy.ts'
import { HostLog, stderrSink } from './log.ts'
import { Reclaimer, takeCollector } from './reclaim.ts'
import { youngGeneration } from './resources.ts'
import { HostRuntime } from './runtime.ts'
import { hostdVersion } from './version.ts'

/**
 * ditto-hostd entry. Core's launcher starts it (kind `hostd`) inside
 * ditto-hostd.scope and hands the token over a file descriptor. hostd never
 * exits for being idle; it exits when Core goes away, and Core decides whether
 * to start another one (host-protocol §3, §10).
 */
const log = new HostLog(stderrSink, { component: 'ditto-hostd', pid: process.pid })

function readToken(env: NodeJS.ProcessEnv): string {
  const fd = env['DITTO_CORE_TOKEN_FD']
  if (fd !== undefined) {
    const number = Number(fd)
    if (!Number.isInteger(number) || number < 3) throw new Error('DITTO_CORE_TOKEN_FD must name an inherited descriptor ≥3')
    const token = readFileSync(number, 'utf8').trim()
    closeSync(number)
    if (!token) throw new Error('launcher token descriptor was empty')
    return token
  }
  // Shared development token (`ditto-core --development`); not identity evidence.
  const dev = env['DITTO_DEV_TOKEN']
  if (dev) return dev
  throw new Error('no launcher token: DITTO_CORE_TOKEN_FD is not set')
}

function socketPath(env: NodeJS.ProcessEnv): string {
  if (env['DITTO_CORE_SOCKET']) return env['DITTO_CORE_SOCKET']
  const runtime = env['DITTO_RUNTIME_DIR'] ?? (env['XDG_RUNTIME_DIR'] ? join(env['XDG_RUNTIME_DIR'], 'ditto') : undefined)
  if (!runtime) throw new Error('neither DITTO_CORE_SOCKET nor XDG_RUNTIME_DIR is set')
  return join(runtime, 'core.sock')
}

async function main(): Promise<void> {
  const env = process.env
  // Before any plugin module loads: plugins never see `gc`.
  const reclaimer = new Reclaimer(takeCollector())
  const young = youngGeneration()
  if (young.fixed && reclaimer.available) log.info('heap settings applied', { ...young, reclaim: true })
  else log.warn('heap settings missing: start hostd with the flags in packages/host-runtime/hostd.node-flags', { ...young, reclaim: reclaimer.available })
  const token = readToken(env)
  const link = await CoreLink.connectSocket(socketPath(env))
  // One transaction semantics per hostd build (D-32 rule 4); only the test build may be told otherwise, for the trial.
  const trialStrategy = faultsCompiledIn ? env['DITTO_HOST_STRATEGY'] as Strategy | undefined : undefined
  const runtime = new HostRuntime({ core: link, policy: ModulePolicy.fromEnvironment(env), log, reclaim: () => reclaimer.request(), ...(trialStrategy ? { strategy: trialStrategy } : {}) })
  let stopping = false
  const stop = async (code: number, why: string) => {
    if (stopping) return
    stopping = true
    log.info('stopping', { why })
    // Bounded by each entry's cleanup timeout; a hung disposer cannot keep hostd alive.
    const deadline = setTimeout(() => process.exit(code), 8_000)
    deadline.unref()
    try { await runtime.stop() } catch (error) { log.error('stop failed', { error: describe(error) }) }
    reclaimer.stop()
    process.exit(code)
  }

  link.attach({
    request: (method, params) => runtime.handleRequest(method, params),
    notification: (method, params) => runtime.handleNotification(method, params),
    closed: error => { void stop(1, `Core connection closed${error ? `: ${error.message}` : ''}`) },
  })
  await runtime.start()
  const handshake = await link.handshake(token, {
    kind: env['DITTO_CLIENT_KIND'] ?? 'hostd',
    version: env['DITTO_CLIENT_VERSION'] ?? hostdVersion,
  })
  const hello = await link.request<HelloResult>('host.hello', runtime.helloParams())
  log.info('connected', { host_generation: hello.host_generation ?? handshake.host_generation, mode: hello.mode, strategy: runtime.strategy })
  runtime.startBackground(hello)

  process.on('SIGTERM', () => { void stop(0, 'SIGTERM') })
  process.on('SIGINT', () => { void stop(0, 'SIGINT') })
  process.on('unhandledRejection', reason => log.error('unhandled rejection', { error: describe(reason) }))
}

main().catch(error => {
  log.error('hostd failed to start', { error: describe(error) })
  process.exit(1)
})
