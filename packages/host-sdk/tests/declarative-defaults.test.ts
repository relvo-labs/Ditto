import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { validateManifest, type JsonSchema } from '../src/manifest/index.ts'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const schema = JSON.parse(readFileSync(join(root, 'schema/manifest.json'), 'utf8'))
const builtin = JSON.parse(readFileSync(join(root, 'packaging/builtin/ditto.layout.floating/manifest.json'), 'utf8'))
// These defaults come from Manifest's serde attributes, published in the generated schema.
const defaultRows: [string, unknown][] = [
  ['runtime', {}], ['platform', []], ['slots', []], ['provides', []], ['requires', []], ['optional', []],
  ['conflicts', []], ['config_schema', { type: 'object' }], ['commands', []], ['shortcuts', []],
  ['events', []], ['permissions', []], ['migrations', []], ['activation_events', []],
]
const defaults = Object.fromEntries(defaultRows)
const explicit = { ...defaults, ...builtin }
const serialized = (manifest: unknown) => JSON.parse(JSON.stringify(manifest))
const without = (manifest: Record<string, unknown>, field: string) => {
  const result = { ...manifest }
  delete result[field]
  return result
}

describe.each([
  ['schema-free', {}], ['Rust-generated schema', { schema: schema as JsonSchema }],
] as const)('declarative defaults (%s)', (_mode, options) => {
  it.each(defaultRows)('accepts omitted %s with its canonical default', (field, value) => {
    expect(schema.properties[field].default).toEqual(value)
    expect(validateManifest(serialized(without(explicit, field)), options).errors).toEqual([])
  })

  it.each(defaultRows)('accepts explicit default %s', (field, value) => {
    expect(validateManifest(serialized({ ...explicit, [field]: value }), options).errors).toEqual([])
  })

  it('accepts all defaults omitted or explicit, without modifying the input or granting permissions', () => {
    const omitted = defaultRows.reduce((m, [field]) => without(m, field), builtin)
    for (const manifest of [omitted, { ...builtin, ...defaults }]) {
      const before = JSON.stringify(manifest)
      expect(validateManifest(manifest, options)).toEqual({ ok: true, errors: [], warnings: [] })
      expect(JSON.stringify(manifest)).toBe(before)
    }
    expect(omitted.permissions).toBeUndefined()
  })

  it.each(defaultRows)('rejects explicit null and wrong types for %s', (field) => {
    const badValues = field === 'runtime' || field === 'config_schema' ? [null, [], 7, true, 'bad'] : [null, {}, 7, true, 'bad']
    for (const value of badValues) {
      expect(validateManifest(serialized({ ...explicit, [field]: value }), options).errors)
        .toContainEqual(expect.objectContaining({ path: `/${field}`, code: 'schema_invalid' }))
    }
  })

  it.each([
    ['runtime node syntax', { runtime: { node: 'not-a-range' } }, '/runtime/node', 'schema_invalid'],
    ['runtime qt syntax', { runtime: { qt: 'not-a-range' } }, '/runtime/qt', 'schema_invalid'],
    ['runtime node type', { runtime: { node: 22 } }, '/runtime/node', 'schema_invalid'],
    ['runtime qt type', { runtime: { qt: [] } }, '/runtime/qt', 'schema_invalid'],
    ['runtime unknown field', { runtime: { other: '^1' } }, '/runtime/other', 'schema_invalid'],
    ['declared incompatible Node', { runtime: { node: '^24' } }, '/runtime/node', 'protocol_incompatible'],
    ['platform item', { platform: [7] }, '/platform', 'schema_invalid'],
    ['slot id', { slots: ['bad'] }, '/slots/0', 'schema_invalid'],
    ['provided namespace', { provides: [{ capability: 'plugin.other.id.get' }] }, '/provides/0', 'schema_invalid'],
    ['provided shape', { provides: [{}] }, '/provides/0', 'schema_invalid'],
    ['required package id', { requires: [{ package: 'Bad' }] }, '/requires/0/package', 'schema_invalid'],
    ['required version', { requires: [{ package: 'ditto.other', version: 'bad' }] }, '/requires/0/version', 'schema_invalid'],
    ['optional shape', { optional: [null] }, '/optional/0', 'schema_invalid'],
    ['conflict id', { conflicts: ['Bad'] }, '/conflicts/0', 'schema_invalid'],
    ['self conflict', { conflicts: [builtin.id] }, '/conflicts/0', 'declared_conflict'],
    ['config type', { config_schema: { type: 'string' } }, '/config_schema/type', 'schema_invalid'],
    ['config keyword', { config_schema: { type: 'object', pattern: 'x' } }, '/config_schema/pattern', 'schema_invalid'],
    ['config default', { config_schema: { type: 'object', properties: { x: { type: 'integer', minimum: 2, default: 1 } } } }, '/config_schema/x', 'schema_invalid'],
    ['command shape', { commands: [{ id: 'test' }] }, '/commands/0', 'schema_invalid'],
    ['duplicate command', { commands: [{ id: 'test', title_key: 't' }, { id: 'test', title_key: 't' }] }, '/commands/1', 'command_conflict'],
    ['reserved shortcut', { commands: [{ id: 'test', title_key: 't' }], shortcuts: [{ chord: 'Super+L', command: 'test' }] }, '/shortcuts/0', 'shortcut_conflict'],
    ['unbound shortcut', { shortcuts: [{ chord: 'Super+T', command: 'missing' }] }, '/shortcuts/0/command', 'schema_invalid'],
    ['event shape', { events: [{ name: 'test/changed', coalesce: 'latest' }] }, '/events/0/schema', 'schema_invalid'],
    ['event coalesce', { events: [{ name: 'test/changed', schema: {}, coalesce: 'bad' }] }, '/events/0/coalesce', 'schema_invalid'],
    ['unknown permission', { permissions: ['everything'] }, '/permissions/0', 'schema_invalid'],
    ['reserved scope', { permissions: ['core'] }, '/permissions/0', 'permission_required'],
    ['permission item type', { permissions: [7] }, '/permissions/0', 'schema_invalid'],
    ['activation event type', { activation_events: [7] }, '/activation_events', 'schema_invalid'],
    ['invalid trust', { trust_level: 'bad' }, '/trust_level', 'schema_invalid'],
    ['kind/host mismatch', { host_kind: 'cordis' }, '/host_kind', 'schema_invalid'],
    ['mismatched service kind', { plugin_kind: 'service' }, '/host_kind', 'schema_invalid'],
    ['mismatched QML kind', { plugin_kind: 'qml_provider' }, '/host_kind', 'schema_invalid'],
  ] as [string, Record<string, unknown>, string, string][])('rejects declared %s', (_label, patch, path, code) => {
    expect(validateManifest(serialized({ ...explicit, ...patch }), options).errors)
      .toContainEqual(expect.objectContaining({ path, code }))
  })

  it.each([
    'manifest_version', 'id', 'version', 'name', 'author', 'license', 'source', 'trust_level',
    'plugin_kind', 'host_kind', 'required_protocol_version', 'hot_swap', 'health', 'cleanup', 'idle_policy',
  ])('still requires %s', field => {
    expect(validateManifest(without(explicit, field), options).errors.some(issue => issue.path.startsWith(`/${field}`))).toBe(true)
  })

  it('preserves Core trust warnings and accepts optional runtime members as defined by Rust', () => {
    expect(validateManifest({ ...explicit, trust_level: 'community' }, options).warnings)
      .toContainEqual(expect.objectContaining({ code: 'precondition_failed' }))
    for (const runtime of [{}, { node: null, qt: null }, { node: '^22.19.0', qt: '>=6.10' }]) {
      expect(validateManifest({ ...explicit, runtime }, options).errors).toEqual([])
    }
  })

  it.each([
    ['packages/host-sdk/examples/counter/manifest.json', 'entry', 'node'],
    ['shell/providers/panel_top/manifest.json', 'qml_entry', 'qt'],
  ])('keeps runtime and entry constraints on %s', (path, entry, runtimeKey) => {
    const manifest = JSON.parse(readFileSync(join(root, path), 'utf8'))
    for (const runtime of [undefined, null, {}, { [runtimeKey]: 'bad' }]) {
      expect(validateManifest({ ...manifest, runtime }, options).errors.some(issue => issue.path.startsWith('/runtime'))).toBe(true)
    }
    expect(validateManifest(without(manifest, entry), options).errors)
      .toContainEqual(expect.objectContaining({ path: `/${entry}`, code: 'schema_invalid' }))
  })
})
