import assert from 'node:assert/strict'
import {readFileSync, writeFileSync} from 'node:fs'
import {test} from 'node:test'
import {runFlow} from './driver.mjs'

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
    'desktop.profiles.get': {profile: {profile_id: 'profile-active-from-readback'}},
    'desktop.plugins.diagnostics': {host: {process: {pid: 123}}},
    'agent.sessions.create': {session_id: 'session-test'},
    'agent.settings.describe': preferences,
    'agent.turns.submit': {turn_id: 'turn-test'},
    'agent.turns.get': {state: 'failed', error_reason: 'provider_unavailable'},
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
    return method === 'agent.credentials.create' ? {error: {name: 'unavailable', message: 'keyring_unavailable'}} : {result}
  }}
  await runFlow(core, {
    sentinels: {key: 'sk-synthetic', token: 'ghp_synthetic', password: 'synthetic-password'},
    verify: (name, value) => assert.ok(value, name),
    save: path => saved.push(path),
    eventually: async fn => { const result = await fn(); assert.ok(result); return result },
  })
  assert.equal(new Set(requests.map(item => item.method)).size, 15)
  const exports = requests.filter(item => item.method === 'desktop.profiles.export')
  assert.equal(exports.length, 2)
  for (const request of exports) assert.deepEqual(request.params, {profile_id: 'profile-active-from-readback'})
  assert.ok(saved.includes('exports/profile'))
  if (process.env.DITTO_QA04_CONTRACT_REPORT) writeFileSync(process.env.DITTO_QA04_CONTRACT_REPORT, JSON.stringify(requests, null, 2))
})

test('the original empty export params and missing params on every required method are rejected', () => {
  assert.throws(() => validate(input('desktop.profiles.export'), {}), /missing profile_id/)
  for (const method of ['agent.credentials.create', 'agent.sessions.create', 'agent.settings.patch',
    'agent.turns.submit', 'agent.turns.get', 'agent.sessions.read', 'desktop.plugins.development.create', 'desktop.plugins.development.get']) {
    assert.throws(() => validate(input(method), {}), /missing/)
  }
  assert.throws(() => validate(input('desktop.rescue.status'), {profile_id: 'unexpected'}))
})
