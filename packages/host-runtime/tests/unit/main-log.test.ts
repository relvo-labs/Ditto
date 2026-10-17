import { afterEach, beforeEach, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({
  privateText: 'QA04_WINDOW_TITLE QA04_DOCUMENT_CONTENT QA04_CLIPBOARD_CONTENT QA04_CONVERSATION_CONTENT',
  failStartup: false, failStop: false, holdHandshake: false,
  releaseHandshake: undefined as (() => void) | undefined,
  closed: undefined as ((error?: Error) => void) | undefined,
  listeners: new Map<string, (...args: unknown[]) => void>(),
}))
vi.mock('../../src/bridge/core-link.ts', () => ({CoreLink: {connectSocket: async () => {
  if (state.failStartup) throw new TypeError(state.privateText)
  return {attach: (handlers: {closed: (error?: Error) => void}) => { state.closed = handlers.closed },
    handshake: async () => {
      if (state.holdHandshake) await new Promise<void>(resolve => { state.releaseHandshake = resolve })
      return {host_generation: 1}
    }, request: async () => ({host_generation: 1, mode: 'normal'})}
}}}))
vi.mock('../../src/reclaim.ts', () => ({takeCollector: () => undefined,
  Reclaimer: class { available = false; stop() {} request() {} }}))
vi.mock('../../src/runtime.ts', () => ({HostRuntime: class {
  strategy = 'isolate_rebuild'
  async start() {} helloParams() { return {} } startBackground() {}
  async stop() { if (state.failStop) throw new TypeError(state.privateText) }
}}))

let chunks: string[]
beforeEach(() => {
  vi.resetModules()
  vi.useFakeTimers()
  state.failStartup = false; state.failStop = false; state.closed = undefined; state.listeners.clear()
  state.holdHandshake = false; state.releaseHandshake = undefined
  chunks = []
  vi.stubEnv('DITTO_CORE_TOKEN_FD', undefined)
  vi.stubEnv('DITTO_DEV_TOKEN', 'synthetic-development-token')
  vi.stubEnv('DITTO_CORE_SOCKET', '/fixture/core.sock')
  vi.spyOn(process, 'exit').mockImplementation(() => undefined as never)
  vi.spyOn(process, 'on').mockImplementation((event, listener) => { state.listeners.set(String(event), listener); return process })
  vi.spyOn(process.stderr, 'write').mockImplementation(chunk => { chunks.push(String(chunk)); return true })
})
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllEnvs() })

it('a rejection while handshake is pending logs no private content and still exits 1', async () => {
  state.holdHandshake = true
  await import('../../src/main.ts')
  await vi.waitFor(() => expect(state.releaseHandshake).toBeDefined())
  try {
    state.listeners.get('unhandledRejection')!(new Error(state.privateText))
    expect(process.exit).toHaveBeenCalledWith(1)
    expect(chunks.join('')).not.toContain('QA04_')
    expect(chunks.join('')).toContain('fingerprint')
  } finally {
    state.releaseHandshake!()
    await vi.waitFor(() => expect(state.listeners.has('SIGTERM')).toBe(true))
  }
})

it.each(['startup', 'connection-close', 'stop-failure', 'unhandled-rejection', 'uncaught-exception'] as const)('main.ts %s preserves diagnostic metadata without private content', async path => {
  state.failStartup = path === 'startup'
  state.failStop = path === 'stop-failure'
  await import('../../src/main.ts')
  if (path === 'startup') await vi.waitFor(() => expect(process.exit).toHaveBeenCalled())
  else {
    await vi.waitFor(() => expect(state.listeners.has('SIGTERM')).toBe(true))
    if (path === 'connection-close') state.closed!(new TypeError(state.privateText))
    else if (path === 'stop-failure') state.listeners.get('SIGTERM')!()
    else state.listeners.get(path === 'uncaught-exception' ? 'uncaughtException' : 'unhandledRejection')!(new TypeError(state.privateText))
  }
  await vi.waitFor(() => expect(chunks.some(chunk => chunk.includes('fingerprint'))).toBe(true))
  const records = chunks.map(chunk => JSON.parse(chunk))
  expect(records).toContainEqual(expect.objectContaining({error: {name: 'TypeError', fingerprint: expect.stringMatching(/^hmac-sha256:[a-f0-9]{64}$/)}}))
  if (path === 'connection-close') expect(records).toContainEqual(expect.objectContaining({why: 'Core connection closed'}))
  if (path === 'startup') {
    expect(state.listeners.has('uncaughtException')).toBe(true)
    expect(state.listeners.has('unhandledRejection')).toBe(true)
  }
  if (path === 'uncaught-exception') expect(process.exit).toHaveBeenCalledWith(1)
  if (path === 'unhandled-rejection') expect(process.exit).not.toHaveBeenCalled()
  expect(chunks.join('')).not.toContain('QA04_')
})
