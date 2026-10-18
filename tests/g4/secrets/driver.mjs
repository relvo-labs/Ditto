// Launched by production Core; runFlow is also exercised without IPC.
import assert from 'node:assert/strict'
import {readFileSync, writeFileSync} from 'node:fs'
import {pathToFileURL} from 'node:url'
import {startProvider, toolOutputs, call, say} from '../../g2/codex/mock-provider.mjs'
import {connect, sleep} from '../../g1/lib/core-client.mjs'

function findEntry(value) {
  if (!value || typeof value !== 'object') return
  if (value.package === 'ditto.svc.notification-policy' && typeof value.entry_id === 'string') return value
  for (const child of Object.values(value)) { const found = findEntry(child); if (found) return found }
}

export function scriptedReply(body) {
  const outputs = toolOutputs(body)
  if (!outputs.has('read-profile')) return [call('desktop__profiles__get', {}, 'read-profile')]
  if (!outputs.has('propose')) {
    const profile = JSON.parse(outputs.get('read-profile'))
    const entry = findEntry(profile)
    assert.ok(entry, 'notification policy entry must exist')
    return [call('desktop__changes__propose', {base_revision: profile.profile.head_revision,
      ops: [{op: 'set_entry_config', entry_id: entry.entry_id, after: {...entry.config,
        rules: {...entry.config?.rules, focus: {enabled: true, allow: []}}}}]}, 'propose')]
  }
  assert.ok(outputs.get('propose').includes('"committed"'), 'scripted change must commit')
  return [say('QA04 scripted turn complete')]
}

export async function runFlow(core, {sentinels, endpoint, verify, save, eventually}) {
  const profile = await eventually(async () => (await core.call('desktop.profiles.get', {})).result)
  const exportParams = {profile_id: profile.profile.profile_id}
  await eventually(async () => (await core.must('desktop.plugins.diagnostics', {})).host.process?.pid)
  verify('real desktop host is running for log coverage', true)
  // Subject is bound by Core to the caller (cli here), never an input field.
  // A private idempotency key takes a valid proposal through change.draft.
  const proposal = await core.must('desktop.changes.propose', {
    profile_id: profile.profile.profile_id, base_revision: profile.profile.head_revision,
    ops: [], idempotency_key: 'QA04_PRIVATE_PROPOSAL_CONTENT',
  })
  verify('proposal creates a traceable change', !!proposal.change_id)
  const change = await core.must('desktop.changes.get', {change_id: proposal.change_id})
  verify('Core retains the private proposal for scanner coverage',
    change.change_id === proposal.change_id && change.idempotency_key === 'QA04_PRIVATE_PROPOSAL_CONTENT')
  save('conversations/proposal-readback', change)
  assert.match(endpoint, /^http:\/\/127\.0\.0\.1:[1-9][0-9]*\/v1$/)
  const session = await core.must('agent.sessions.create', {title: 'QA04 private conversation', idempotency_key: 'qa04'})
  for (const [label, secret] of Object.entries(sentinels)) {
    const credential = await core.must('agent.credentials.create', {provider: 'direct-model', secret, idempotency_key: `qa04-${label}`})
    verify(`${label}: private keyring stored credential`, credential.available && credential.credential_ref.startsWith('cred-'))
    save(`diagnostics/credential-${label}`, credential)
    const settings = await core.must('agent.settings.describe', {})
    const {_meta, ...preferences} = settings
    await core.must('agent.settings.patch', {expected_revision: settings.revision,
      settings: {...preferences, enabled: true, provider: 'direct-model', endpoint,
        auth: {kind: 'api_key', credential_ref: credential.credential_ref}}})
    const turn = await core.must('agent.turns.submit', {session_id: session.session_id,
      client_message_id: `qa04-message-${label}`, text: 'QA04_PRIVATE_CONVERSATION_CONTENT'})
    const done = await eventually(async () => {
      const value = await core.must('agent.turns.get', {turn_id: turn.turn_id})
      return ['succeeded', 'failed', 'cancelled', 'unknown', 'partial'].includes(value.state) ? value : false
    })
    verify(`${label}: real Agent completed scripted model turn`, done.state === 'succeeded')
    save(`conversations/turn-${label}`, done)
    const readback = await core.must('desktop.profiles.get', {})
    verify(`${label}: hostd notification policy readback is enabled`, findEntry(readback)?.config?.rules?.focus?.enabled === true)
  }
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
  let core, provider
  try {
    assert.equal(process.env.DBUS_SESSION_BUS_ADDRESS, 'unix:path=' + process.env.DITTO_QA04_SCRATCH + '/bus')
    const sentinels = JSON.parse(process.env.DITTO_QA04_SENTINELS)
    provider = await startProvider(scriptedReply)
    core = await connect()
    await runFlow(core, {sentinels, endpoint: `http://127.0.0.1:${provider.port}/v1`, verify, save, eventually})
    const requests = provider.requests
    verify('scripted loopback provider received all three resolved keys',
      Object.values(sentinels).every(secret => requests.some(request => request.authorization === 'Bearer ' + secret)))
    verify('every model request has a known key and only targets the local Responses route',
      requests.length >= 9 && requests.every(request => request.url === '/v1/responses'
        && Object.values(sentinels).some(secret => request.authorization === 'Bearer ' + secret)))
    writeFileSync(`${root}/driver.json`, JSON.stringify({ok: true, checks}))
  } catch (error) {
    writeFileSync(`${root}/driver.json`, JSON.stringify({ok: false, checks, error: String(error)}))
    process.exitCode = 1
  } finally { core?.close(); await provider?.close() }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main()
