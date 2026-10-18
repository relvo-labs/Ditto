import type { Context, Exporter } from '@deepseek-ai/cordis'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { DittoError } from '../../src/errors.ts'
import { faultPoint, resetFaultHits } from '../../src/fault-enabled.ts'
import { errorDiagnostic, safeLogStringFields, HostLog, installCordisExporter, type LogRecord, stderrSink } from '../../src/log.ts'

const markers = ['QA04_WINDOW_TITLE', 'QA04_DOCUMENT_CONTENT', 'QA04_CLIPBOARD_CONTENT', 'QA04_CONVERSATION_CONTENT']
const privateText = markers.join(' ')
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); resetFaultHits() })

describe('default host log privacy', () => {
  it('groups the same short message within one host instance but not across two startup keys', async () => {
    // Reload the host module to exercise two independent startup key lifetimes, without IPC.
    vi.resetModules()
    const firstHost = await import('../../src/log.ts')
    vi.resetModules()
    const secondHost = await import('../../src/log.ts')
    const first = firstHost.errorDiagnostic(new Error('4821'))
    const second = secondHost.errorDiagnostic(new Error('4821'))
    expect(first).toEqual(firstHost.errorDiagnostic(new Error('4821')))
    expect(second).toEqual(secondHost.errorDiagnostic(new Error('4821')))
    expect(first.fingerprint).not.toBe(second.fingerprint)
  })

  it('retains the fixed dependency_not_ready code and redacts its private detail', () => {
    const records: LogRecord[] = []
    new HostLog(record => records.push(record)).info('participant.result', {
      items: [{key: 'ent-test', status: 'failed', reason: 'dependency_not_ready: ' + privateText}],
    })
    expect(records[0]).toMatchObject({items: [{reason: {code: 'dependency_not_ready'}}]})
    expect(JSON.stringify(records)).not.toContain('QA04_')
  })
  it.each(markers)('keeps error class/code/fingerprint and correlation without %s', marker => {
    const records: LogRecord[] = []
    const log = new HostLog(record => records.push(record), { plugin_id: 'test.plugin', entry_id: 'ent-test' })
    const error = new DittoError('permission_denied', marker, { content: marker })
    log.error('subscription refused', { error, change_id: 'chg-test', operation_id: 'op-test', session_id: 'sess-test' })
    expect(records[0]).toMatchObject({ plugin_id: 'test.plugin', entry_id: 'ent-test', change_id: 'chg-test',
      operation_id: 'op-test', session_id: 'sess-test', error: { name: 'DittoError', code: -32003,
        fingerprint: expect.stringMatching(/^hmac-sha256:[a-f0-9]{64}$/) } })
    expect(JSON.stringify(records)).not.toContain(marker)
    expect(errorDiagnostic(error)).toEqual(errorDiagnostic(new DittoError('permission_denied', marker)))
    expect(errorDiagnostic(error).fingerprint).not.toBe(errorDiagnostic(new DittoError('permission_denied', marker + ' changed')).fingerprint)
  })

  it('covers child fields, nested transaction reasons, Rust content keys, payloads and home paths at the sink', () => {
    const records: LogRecord[] = []
    vi.stubEnv('HOME', '/home/qa04')
    const log = new HostLog(record => records.push(record)).child({ title: privateText, entry_id: 'ent-test' })
    log.info('participant.result', { items: [{key: 'ent-test', status: 'failed', reason: privateText}],
      summary: privateText, body: privateText, clipboard: privateText, text: privateText,
      content: privateText, window_title: privateText, message: privateText, stack: privateText,
      payload: { [privateText]: privateText }, config: {value: privateText}, path: '/home/qa04/private.odt',
      error: Object.assign(new TypeError(privateText), { code: 'ENOENT' }) })
    const chunks: string[] = []
    vi.spyOn(process.stderr, 'write').mockImplementation(chunk => { chunks.push(String(chunk)); return true })
    stderrSink(records[0]!)
    const written = JSON.parse(chunks.join(''))
    expect(written).toEqual(records[0]) // A second pass preserves safe diagnostic metadata.
    expect(written.error).toMatchObject({ name: 'TypeError', code: 'ENOENT' })
    expect(written.items[0]).toMatchObject({ key: 'ent-test', status: 'failed', reason: {name: 'NonError'} })
    expect(written.path).toBe('~/…')
    for (const marker of markers) expect(chunks.join('')).not.toContain(marker)
    stderrSink({ts: 'test', level: 'error', msg: 'test.failure', error: new Error(privateText)})
    expect(chunks.at(-1)).not.toContain(privateText)
  })

  it('redacts Cordis Error, formatted messages, object payloads and custom logger names, retaining Core-owned identity', () => {
    const records: LogRecord[] = []
    let exporter!: Exporter
    const root = {logger: {exporter: (value: Exporter) => { exporter = value }}} as unknown as Context
    const context = {} as Context
    installCordisExporter(root, new HostLog(record => records.push(record)), 2,
      () => ({entry_id: 'ent-test', plugin_id: 'test.plugin'}))
    for (const args of [[new TypeError(privateText)], ['%s %o', privateText, {content: privateText}],
      [{[privateText]: privateText}], [privateText]]) {
      exporter.export({sn: 1, ts: 1, type: 'error', level: 0, name: privateText, args, fiber: new WeakRef({ctx: context})} as Parameters<Exporter['export']>[0])
    }
    expect(records).toHaveLength(4)
    for (const record of records) {
      expect(record).toMatchObject({source: 'cordis', entry_id: 'ent-test', plugin_id: 'test.plugin',
        error: {fingerprint: expect.stringMatching(/^hmac-sha256:/)} })
      for (const marker of markers) expect(JSON.stringify(record)).not.toContain(marker)
    }
  })

  it('does not serialize custom error class/code or toJSON content, and still tolerates a broken sink', () => {
    const error = Object.assign(new Error(privateText), {name: privateText, code: privateText, toJSON: () => ({body: privateText})})
    expect(errorDiagnostic(error)).toMatchObject({name: 'Error'})
    expect(errorDiagnostic(error)).not.toHaveProperty('code')
    expect(JSON.stringify(errorDiagnostic(error))).not.toContain(privateText)
    expect(() => new HostLog(() => { throw error }).error('test.failure', {error})).not.toThrow()
  })

  it('unknown free-text messages cannot bypass redaction via HostLog or a direct stderr sink call', () => {
    const records: LogRecord[] = []
    new HostLog(record => records.push(record)).error(privateText)
    expect(records[0]).toMatchObject({msg: 'host.message', message_fingerprint: expect.stringMatching(/^hmac-sha256:/)})
    const chunks: string[] = []
    vi.spyOn(process.stderr, 'write').mockImplementation(chunk => { chunks.push(String(chunk)); return true })
    stderrSink({ts: 'test', level: 'error', msg: privateText})
    expect(JSON.parse(chunks.join(''))).toMatchObject({msg: 'host.message', message_fingerprint: records[0]!['message_fingerprint']})
    expect(JSON.stringify(records) + chunks.join('')).not.toContain('QA04_')
  })

  it('the test-only fault path also emits only classified actions', async () => {
    const chunks: string[] = []
    vi.spyOn(process.stderr, 'write').mockImplementation(chunk => { chunks.push(String(chunk)); return true })
    vi.stubEnv('DITTO_HOST_FAULT', `heartbeat:${privateText}`)
    await faultPoint('heartbeat')
    expect(JSON.parse(chunks.join(''))).toMatchObject({msg: 'host.fault', action: 'unknown', point: 'heartbeat'})
    expect(chunks.join('')).not.toContain(privateText)
  })
})

it('redacts unknown string fields at every depth including arrays, children and a direct sink', () => {
  const records: LogRecord[] = []
  new HostLog(record => records.push(record)).child({new_field: privateText}).info('connected', {
    nested: {unexpected: privateText}, values: [privateText],
    // Safe field names cannot bless strings inside an unknown container.
    unknown: {entry_id: privateText},
  })
  const chunks: string[] = []
  vi.spyOn(process.stderr, 'write').mockImplementation(chunk => { chunks.push(String(chunk)); return true })
  stderrSink({ts: 'test', level: 'info', msg: 'connected', surprise: privateText})
  expect(JSON.stringify(records) + chunks.join('')).not.toContain('QA04_')
})

it('pins the reviewed string allow-list and preserves each field including lease arrays', () => {
  expect([...safeLogStringFields]).toEqual([
    'component', 'part', 'source', 'entry_id', 'plugin_id', 'change_id',
    'operation_id', 'session_id', 'grant_id', 'subscription_id', 'capability_id',
    'lease_id', 'presented', 'renewed', 'expired', 'method', 'key', 'status',
    'why', 'mode', 'strategy', 'point', 'action', 'path',
  ])
  const records: LogRecord[] = []
  const fields = Object.fromEntries(safeLogStringFields.map(key => [key, 'safe-value']))
  new HostLog(record => records.push(record)).info('connected', {
    ...fields, presented: ['lease-1'], renewed: ['lease-2'], expired: ['lease-3'],
    items: [{key: 'entry', status: 'failed', reason: 'apply_failed: private'}],
  })
  expect(records[0]).toMatchObject({...fields, presented: ['lease-1'], renewed: ['lease-2'], expired: ['lease-3'],
    items: [{key: 'entry', status: 'failed', reason: {code: 'apply_failed'}}]})
})
