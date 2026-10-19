import assert from 'node:assert/strict'
import {readFileSync, writeFileSync} from 'node:fs'
import {test} from 'node:test'
import {runFlow, scriptedReply} from './driver.mjs'

const readSchema = name => JSON.parse(readFileSync(new URL(`../../../schema/${name}.json`, import.meta.url)))
const catalog = readSchema('catalog').capabilities
const input = method => {
  const contract = catalog.find(item => item.capability_id === method)
  assert.ok(contract, `unknown capability: ${method}`)
  return contract.input_schema
}

// Only the vocabulary used by these exported input schemas; fail closed on
// new validation keywords rather than silently claiming a full validator.
function validate(schema, value, root = schema) {
  const supported = ['$schema', '$defs', '$ref', 'title', 'description', 'default', 'format',
    'type', 'const', 'enum', 'required', 'properties', 'additionalProperties', 'items',
    'minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems', 'pattern', 'anyOf', 'oneOf']
  for (const key of Object.keys(schema)) assert.ok(supported.includes(key), `unhandled schema keyword: ${key}`)
  if (schema.$ref) {
    assert.ok(schema.$ref.startsWith('#/$defs/'))
    validate(root.$defs[schema.$ref.slice(8)], value, root)
  }
  const matches = candidate => { try { validate(candidate, value, root); return true } catch { return false } }
  if (schema.anyOf) assert.ok(schema.anyOf.some(matches), 'anyOf failed')
  if (schema.oneOf) assert.equal(schema.oneOf.filter(matches).length, 1, 'oneOf failed')
  if ('const' in schema) assert.deepEqual(value, schema.const)
  if (schema.enum) assert.ok(schema.enum.some(item => JSON.stringify(item) === JSON.stringify(value)))
  if (schema.type) {
    const actual = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value
    assert.ok([schema.type].flat().some(type => type === actual || (type === 'integer' && Number.isInteger(value))), `expected ${schema.type}, got ${actual}`)
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const key of schema.required ?? []) assert.ok(Object.hasOwn(value, key), `missing ${key}`)
    for (const [key, child] of Object.entries(value)) {
      if (schema.properties?.[key]) validate(schema.properties[key], child, root)
      else if (schema.additionalProperties === false) assert.fail(`unexpected ${key}`)
      else if (typeof schema.additionalProperties === 'object') validate(schema.additionalProperties, child, root)
    }
  }
  if (Array.isArray(value)) {
    if (schema.items) for (const child of value) validate(schema.items, child, root)
    if ('minItems' in schema) assert.ok(value.length >= schema.minItems)
    if ('maxItems' in schema) assert.ok(value.length <= schema.maxItems)
  }
  if (typeof value === 'number') {
    if ('minimum' in schema) assert.ok(value >= schema.minimum)
    if ('maximum' in schema) assert.ok(value <= schema.maximum)
    if (schema.format === 'uint32') assert.ok(Number.isInteger(value) && value <= 0xffffffff)
    if (schema.format === 'uint64') assert.ok(Number.isSafeInteger(value) && value >= 0)
  }
  if (typeof value === 'string') {
    if ('minLength' in schema) assert.ok([...value].length >= schema.minLength)
    if ('maxLength' in schema) assert.ok([...value].length <= schema.maxLength)
    if (schema.pattern) assert.match(value, new RegExp(schema.pattern))
  }
}

test('the production driver completes with every actual request schema-checked, including both exports', async () => {
  const requests = []
  const saved = []
  const preferences = {revision: 1, enabled: false, provider: 'codex-app-server', max_tool_calls: 20,
    turn_timeout_ms: 120000, retain_conversations: true, approval_mode: 'ask'}
  const responses = {
    'desktop.profiles.get': {profile: {profile_id: 'profile-active-from-readback', head_revision: 'revision-from-readback', entries: [{package: 'ditto.svc.notification-policy', entry_id: 'notification-entry', config: {rules: {focus: {enabled: true}}}}]}},
    'desktop.plugins.diagnostics': {host: {process: {pid: 123}}},
    'desktop.changes.propose': {change_id: 'change-test'},
    'desktop.changes.get': {change_id: 'change-test', idempotency_key: 'QA04_PRIVATE_PROPOSAL_CONTENT'},
    'agent.credentials.create': {available: true, credential_ref: 'cred-from-keyring'},
    'agent.sessions.create': {session_id: 'session-test'},
    'agent.settings.describe': preferences,
    'agent.turns.submit': {turn_id: 'turn-test'},
    'agent.turns.get': {state: 'succeeded'},
    'agent.sessions.read': {events: [{type: 'user/message'}]},
    'desktop.plugins.development.create': {artifact_id: 'artifact-test', source_files: {'description.json': '{}'}},
  }
  const must = async (method, params) => {
    validate(input(method), params)
    requests.push({method, required: input(method).required ?? [], params})
    return responses[method] ?? {}
  }
  const core = {must, call: async (method, params) => {
    const result = await must(method, params)
    return {result}
  }}
  await runFlow(core, {
    endpoint: 'http://127.0.0.1:9123/v1',
    sentinels: {key: 'sk-synthetic', token: 'ghp_synthetic', password: 'synthetic-password'},
    verify: (name, value) => assert.ok(value, name),
    save: path => saved.push(path),
    eventually: async fn => { const result = await fn(); assert.ok(result); return result },
  })
  const turns = requests.filter(item => item.method === 'agent.turns.submit')
  assert.equal(turns.length, 3)
  for (const request of requests.filter(item => item.method === 'agent.settings.patch')) {
    assert.equal(request.params.settings.auth.credential_ref, 'cred-from-keyring')
    assert.equal(request.params.settings.endpoint, 'http://127.0.0.1:9123/v1')
  }
  assert.equal(new Set(requests.map(item => item.method)).size, 17)
  const proposals = requests.filter(item => item.method === 'desktop.changes.propose')
  assert.equal(proposals.length, 1)
  assert.deepEqual(proposals[0].params, {
    profile_id: 'profile-active-from-readback', base_revision: 'revision-from-readback',
    ops: [], idempotency_key: 'QA04_PRIVATE_PROPOSAL_CONTENT',
  })
  assert.deepEqual(requests.find(item => item.method === 'desktop.changes.get').params, {change_id: 'change-test'})
  const exports = requests.filter(item => item.method === 'desktop.profiles.export')
  assert.equal(exports.length, 2)
  for (const request of exports) assert.deepEqual(request.params, {profile_id: 'profile-active-from-readback'})
  assert.ok(saved.includes('exports/profile'))
  assert.ok(saved.includes('conversations/proposal-readback'))
  if (process.env.DITTO_QA04_CONTRACT_REPORT) writeFileSync(process.env.DITTO_QA04_CONTRACT_REPORT, JSON.stringify(requests, null, 2))
})

test('the original empty export params and missing params on every required method are rejected', () => {
  assert.throws(() => validate(input('desktop.profiles.export'), {}), /missing profile_id/)
  for (const method of ['agent.credentials.create', 'agent.sessions.create', 'agent.settings.patch',
    'agent.turns.submit', 'agent.turns.get', 'agent.sessions.read', 'desktop.plugins.development.create', 'desktop.plugins.development.get',
    'desktop.changes.propose']) {
    assert.throws(() => validate(input(method), {}), /missing/)
  }
  assert.throws(() => validate(input('desktop.rescue.status'), {profile_id: 'unexpected'}))
  assert.throws(() => validate(input('desktop.changes.propose'), {base_revision: 'revision-test', ops: [], subject: 'private'}), /unexpected subject/)
  assert.throws(() => validate(input('desktop.changes.propose'), {base_revision: 'revision-test', ops: {}}), /expected array/)
})

test('scripted model exercises an actual hostd config transaction and rejects a failed commit', () => {
  assert.equal(scriptedReply({input: []})[0].name, 'desktop__profiles__get')
  const profile = {profile: {head_revision: 'read-revision', entries: [{package: 'ditto.svc.notification-policy',
    entry_id: 'notification-entry', config: {rules: {focus: {enabled: false}}}}]}}
  const modelInput = [{type: 'function_call_output', call_id: 'read-profile', output: JSON.stringify(profile)}]
  const reply = scriptedReply({input: modelInput})[0]
  assert.equal(reply.name, 'desktop__changes__propose')
  const params = JSON.parse(reply.arguments)
  validate(input('desktop.changes.propose'), params)
  assert.equal(params.base_revision, 'read-revision')
  assert.equal(params.ops[0].entry_id, 'notification-entry')
  assert.equal(params.ops[0].after.rules.focus.enabled, true)
  modelInput.push({type: 'function_call_output', call_id: 'propose', output: '{"state":"failed"}'})
  assert.throws(() => scriptedReply({input: modelInput}), /must commit/)
  modelInput[1].output = '{"state":"committed"}'
  assert.equal(scriptedReply({input: modelInput})[0].type, 'message')
})
