import { afterEach, expect, it, vi } from 'vitest'
import { DittoError } from '../../src/errors.ts'
import type { TestHost } from '../../src/testing/index.ts'
import { changeId, fixture, host } from '../helpers.ts'

const privateText = 'QA04_WINDOW_TITLE QA04_DOCUMENT_CONTENT QA04_CLIPBOARD_CONTENT QA04_CONVERSATION_CONTENT'
let h: TestHost
afterEach(async () => { vi.restoreAllMocks(); await h?.close() })

async function expectSafeFailure(msg: string, correlation: Record<string, unknown> = {}) {
  await vi.waitFor(() => expect(h.logs).toContainEqual(expect.objectContaining({msg})))
  const record = h.logs.find(item => item.msg === msg)!
  expect(record).toMatchObject({...correlation, error: {fingerprint: expect.stringMatching(/^sha256:[a-f0-9]{64}$/)}})
  expect(JSON.stringify(h.logs)).not.toContain('QA04_')
}

async function mount(config: Record<string, unknown> = {}) {
  const entry = h.entry({entry_id: 'ent-private', module_path: fixture('generic'),
    config: {tag: 'base', ...config}, provides: ['plugin.test.private.get']})
  await h.core.apply(changeId(), [entry])
  return entry
}

it('runtime background task failures retain type without thrown text', async () => {
  h = await host({background: true, intervals: {heartbeatMs: 10, renewMs: 60000, resourcesMs: 60000},
    faults: {heartbeat: () => { throw new TypeError(privateText) }}})
  await expectSafeFailure('background task failed')
  expect(h.logs.find(item => item.msg === 'background task failed')!['error']).toMatchObject({name: 'TypeError'})
})

it('participant refusals and result item reasons are redacted only in logs', async () => {
  h = await host()
  await expect(h.runtime.handleRequest('participant.' + privateText, {change_id: 'chg-log'})).rejects.toBeInstanceOf(DittoError)
  await expectSafeFailure('participant.refused', {change_id: 'chg-log', method: '[redacted]'})
  const reason = 'module_load_failed: ' + privateText
  vi.spyOn(h.runtime.tx, 'prepare').mockResolvedValue({items: [{key: 'ent-private', status: 'failed', reason}]})
  const result = await h.runtime.handleRequest('participant.prepare', {change_id: 'chg-log'})
  expect(result).toMatchObject({items: [{reason}]}) // Wire response is unchanged.
  expect(h.logs.find(item => item.msg === 'participant.result')).toMatchObject({change_id: 'chg-log',
    method: 'participant.prepare', items: [{key: 'ent-private', status: 'failed', reason: {code: 'module_load_failed', fingerprint: expect.stringMatching(/^sha256:/)}}]})
  expect(JSON.stringify(h.logs)).not.toContain('QA04_')
})

it('event and revoke handlers cannot log their exception or event payload', async () => {
  h = await host()
  await mount()
  h.runtime.subscriptions.set('sub-log', {topics: [], handler: () => { throw new TypeError(privateText) }})
  h.runtime.handleNotification('desktop.events', {subscription_id: 'sub-log', seq: 1, payload: privateText})
  await expectSafeFailure('event handler failed', {subscription_id: 'sub-log'})
  h.runtime.tx.active.get('ent-private')!.revokeHandlers.add(() => { throw new TypeError(privateText) })
  h.runtime.handleNotification('host.permission_revoked', {entry_id: 'ent-private', grant_id: 'grant-log', scope: privateText})
  await expectSafeFailure('revoke handler failed', {entry_id: 'ent-private'})
})

it('DittoService subscription and capability registration failures retain entry and closed code', async () => {
  h = await host()
  h.core.faults.set('desktop.events.subscribe', {action: 'refuse', error: {name: 'permission_denied', message: privateText}})
  await mount({subscribe: [privateText]})
  await expectSafeFailure('subscription refused', {entry_id: 'ent-private'})
  expect(h.logs.find(item => item.msg === 'subscription refused')!['error']).toMatchObject({name: 'DittoError', code: -32003})
  h.core.faults.set('host.capability.register', {action: 'refuse', error: {name: 'unavailable', message: privateText}})
  const entry = h.entry({entry_id: 'ent-registration', module_path: fixture('generic'),
    config: {tag: 'registration', register: ['plugin.test.register.get']}, provides: ['plugin.test.register.get']})
  await h.core.apply(changeId(), [entry])
  await expectSafeFailure('capability registration refused', {entry_id: 'ent-registration', capability_id: 'plugin.test.register.get'})
})

it('EventBridge rejection logs neither plugin event name nor payload', async () => {
  h = await host()
  await mount()
  h.core.faults.set('host.event', {action: 'refuse', error: {name: 'invalid_params', message: privateText}})
  h.runtime.tx.active.get('ent-private')!.fiber!.ctx.ditto.events.emit(privateText, {text: privateText})
  await expectSafeFailure('event rejected by Core', {entry_id: 'ent-private', name: '[redacted]'})
})

it.each(['revoke', 're-register'] as const)('LeaseTable %s failure keeps capability/lease correlation', async path => {
  h = await host()
  await mount({register: ['plugin.test.private.get']})
  const lease = h.core.bindingOf('plugin.test.private.get')!.leaseId
  if (path === 'revoke') {
    h.core.faults.set('host.capability.revoke', {action: 'refuse', error: {name: 'unavailable', message: privateText}})
    await h.runtime.leases.revoke(h.runtime.leases.lookup(lease)!)
    await expectSafeFailure('lease revoke failed', {lease_id: lease})
  } else {
    h.core.faults.set('host.capability.register', {action: 'refuse', error: {name: 'unavailable', message: privateText}})
    h.core.expireLeases()
    await h.runtime.leases.renew()
    await expectSafeFailure('re-registration failed', {capability_id: 'plugin.test.private.get'})
  }
})

it.each(['drain', 'exportState'] as const)('transaction %s exceptions do not become log content', async hook => {
  h = await host()
  const entry = await mount()
  h.runtime.tx.active.get('ent-private')!.hooks[hook] = () => { throw new TypeError(privateText) }
  await h.core.apply(changeId(), [{...entry, config: {tag: 'next'}}])
  await expectSafeFailure(hook === 'drain' ? 'drain failed' : 'exportState failed', {entry_id: 'ent-private'})
})

it('transaction dispose failures are redacted even when the fiber rejects directly', async () => {
  h = await host()
  await mount()
  const instance = h.runtime.tx.active.get('ent-private')!
  vi.spyOn(instance.fiber!, 'dispose').mockRejectedValueOnce(new TypeError(privateText))
  await h.core.apply(changeId(), [])
  await expectSafeFailure('dispose failed', {entry_id: 'ent-private'})
})
