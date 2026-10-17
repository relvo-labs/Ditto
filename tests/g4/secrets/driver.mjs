// Launched by production Core; runFlow is also exercised without IPC.
import assert from 'node:assert/strict'
import {readFileSync, writeFileSync} from 'node:fs'
import {pathToFileURL} from 'node:url'
import {connect, sleep} from '../../g1/lib/core-client.mjs'

export async function runFlow(core, {sentinels, verify, save, eventually}) {
  const profile = await eventually(async () => (await core.call('desktop.profiles.get', {})).result)
  const exportParams = {profile_id: profile.profile.profile_id}
  await eventually(async () => (await core.must('desktop.plugins.diagnostics', {})).host.process?.pid)
  verify('real desktop host is running for log coverage', true)
  for (const [label, secret] of Object.entries(sentinels)) {
    const response = await core.call('agent.credentials.create', {provider: 'direct-model', secret, idempotency_key: `qa04-${label}`})
    verify(`${label}: unavailable private keyring refuses credential`, response.error?.name === 'unavailable' && response.error?.message === 'keyring_unavailable')
    save(`diagnostics/credential-${label}`, response)
  }
  const session = await core.must('agent.sessions.create', {title: 'QA04 private conversation', idempotency_key: 'qa04'})
  const settings = await core.must('agent.settings.describe', {})
  const {_meta, ...preferences} = settings
  await core.must('agent.settings.patch', {expected_revision: settings.revision,
    settings: {...preferences, enabled: true, provider: 'direct-model', endpoint: 'https://example.invalid/v1',
      auth: {kind: 'api_key', credential_ref: 'cred-qa04-missing'}}})
  const turn = await core.must('agent.turns.submit', {session_id: session.session_id, client_message_id: 'qa04-message', text: 'QA04_PRIVATE_CONVERSATION_CONTENT'})
  const done = await eventually(async () => {
    const value = await core.must('agent.turns.get', {turn_id: turn.turn_id})
    return ['succeeded', 'failed', 'cancelled', 'unknown', 'partial'].includes(value.state) ? value : false
  })
  verify('real Agent fails closed without key', done.state === 'failed' && done.error_reason === 'provider_unavailable')
  const page = await core.must('agent.sessions.read', {session_id: session.session_id, offset: 0, limit: 50})
  verify('Core retains the conversation for scanner coverage', page.events.some(e => e.type === 'user/message'))
  save('conversations/readback', page)
  const description = JSON.parse(readFileSync(new URL('../../../crates/ditto-generation/examples/tasks-summary.json', import.meta.url)))
  const artifact = await core.must('desktop.plugins.development.create', {description, request_summary: 'QA04 fixed template', idempotency_key: 'qa04-create'})
  verify('generation creates source bundle', !!artifact.source_files['description.json'])
  save('generated/artifact', await core.must('desktop.plugins.development.get', {artifact_id: artifact.artifact_id}))
  save('exports/profile', await core.must('desktop.profiles.export', exportParams))
  save('diagnostics/plugins', await core.must('desktop.plugins.diagnostics', {}))
  save('diagnostics/rescue', await core.must('desktop.rescue.status', {}))
  save('diagnostics/runtime', await core.must('agent.runtime.get', {}))
  // Privacy content may exist in the explicitly saved conversation; it must
  // not enter default diagnostic/export responses.
  for (const [capability, params] of [['desktop.plugins.diagnostics', {}], ['desktop.rescue.status', {}], ['desktop.profiles.export', exportParams]]) {
    verify(`${capability}: no private conversation content`, !JSON.stringify(await core.must(capability, params)).includes('QA04_PRIVATE_CONVERSATION_CONTENT'))
  }
  await core.must('agent.runtime.stop', {})
}

async function main() {
  const root = process.env.DITTO_QA04_ROOT
  const checks = []
  const verify = (name, value) => { assert.ok(value, name); checks.push(name) }
  const save = (path, value) => writeFileSync(`${root}/product/${path}.json`, JSON.stringify(value, null, 2))
  const eventually = async fn => {
    for (let i = 0; i < 200; i++) { const value = await fn(); if (value) return value; await sleep(50) }
    throw new Error('Core readback timed out')
  }
  let core
  try {
    core = await connect()
    await runFlow(core, {sentinels: JSON.parse(process.env.DITTO_QA04_SENTINELS), verify, save, eventually})
    writeFileSync(`${root}/driver.json`, JSON.stringify({ok: true, checks}))
  } catch (error) {
    writeFileSync(`${root}/driver.json`, JSON.stringify({ok: false, checks, error: String(error)}))
    process.exitCode = 1
  } finally { core?.close() }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main()
