import { spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { bareImports } from '../scripts/bundle-plugin.mjs'
import { validateManifest, type JsonSchema } from '../src/manifest/index.ts'
import { packPackage, validatePackage } from '../src/package.ts'

const packages = fileURLToPath(new URL('../../', import.meta.url))
const root = join(packages, '..')
const schema = JSON.parse(readFileSync(join(root, 'schema/manifest.json'), 'utf8')) as JsonSchema
const manifestDirs = (parent: string) => readdirSync(parent).map(name => join(parent, name))
  .filter(dir => existsSync(join(dir, 'manifest.json')))
const counter = JSON.parse(readFileSync(join(packages, 'host-sdk/examples/counter/manifest.json'), 'utf8')) as Record<string, unknown>
const scratch = mkdtempSync(join(tmpdir(), 'ditto-sdk-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

const codes = (manifest: unknown, options = {}) => validateManifest(manifest, options).errors.map(issue => issue.code)
const withField = (patch: Record<string, unknown>) => ({ ...counter, ...patch })

describe('manifest rules (docs/contracts/manifest.md)', () => {
  it('accepts SDK examples/templates, plugin fixtures and every builtin manifest producer', () => {
    // Keep all three producer roots from scripts/build-builtin-packages.sh in the inventory.
    const builtins = ['shell/providers', 'packaging/builtin', 'packages/plugins'].flatMap(dir => manifestDirs(join(root, dir)))
    const kinds = builtins.map(dir => JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')).plugin_kind)
    expect(builtins).toHaveLength(13)
    expect(kinds.filter(kind => kind === 'qml_provider')).toHaveLength(9)
    expect(kinds.filter(kind => kind === 'service')).toHaveLength(2)
    expect(kinds.filter(kind => kind === 'declarative_bundle')).toHaveLength(2)
    const dirs = [
      ...['cordis', 'qml', 'faults', 'stress'].flatMap(group => manifestDirs(join(packages, 'plugin-fixtures', group))),
      join(packages, 'host-sdk/examples/counter'), join(packages, 'host-sdk/templates/qml-provider'),
      ...builtins,
    ]
    // Validate the entire inventory before asserting, so one failure cannot hide later producers.
    const results = dirs.flatMap(dir => [{}, { schema }].map((options, i) => ({
      dir, schema: i === 1,
      errors: validateManifest(JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')), options).errors,
    })))
    expect(results).toEqual(results.map(({ dir, schema }) => ({ dir, schema, errors: [] })))
  })

  it.each([
    ['manifest_version 2', { manifest_version: 2 }, 'schema_invalid'],
    ['a plain-string name (the Rust type is a locale map)', { name: 'Counter' }, 'schema_invalid'],
    ['a missing licence', { license: undefined }, 'schema_invalid'],
    ['a non reverse-domain id', { id: 'Counter' }, 'schema_invalid'],
    ['a non-semver version', { version: '1.0' }, 'schema_invalid'],
    ['service on the qml host', { host_kind: 'qml' }, 'schema_invalid'],
    ['a Node range that excludes 22.23.2', { runtime: { node: '^24.0.0' } }, 'protocol_incompatible'],
    ['a protocol range that excludes 0.2.0', { required_protocol_version: '^0.1' }, 'protocol_incompatible'],
    ['a plugin capability outside its namespace', { provides: [{ capability: 'plugin.other.pkg.get' }] }, 'schema_invalid'],
    ['a capability declared twice', { provides: [{ capability: 'desktop.tasks.list' }, { capability: 'desktop.tasks.list' }] }, 'single_provider_violation'],
    ['an absolute entry', { entry: '/abs/index.mjs' }, 'schema_invalid'],
    ['a config_schema keyword outside the subset', { config_schema: { type: 'object', properties: { a: { type: 'string', pattern: 'x' } } } }, 'schema_invalid'],
    ['a default that violates its schema', { config_schema: { type: 'object', properties: { a: { type: 'integer', minimum: 2, default: 1 } } } }, 'schema_invalid'],
    ['a duplicate command', { commands: [{ id: 'a', title_key: 't' }, { id: 'a', title_key: 't' }] }, 'command_conflict'],
    ['a Core-reserved chord', { commands: [{ id: 'a', title_key: 't' }], shortcuts: [{ chord: 'Super+L', command: 'a' }] }, 'shortcut_conflict'],
    ['an event without a schema', { events: [{ name: 'counter/changed', coalesce: 'latest' }] }, 'schema_invalid'],
    ['an unknown coalesce policy', { events: [{ name: 'counter/changed', schema: {}, coalesce: 'merge' }] }, 'schema_invalid'],
    ['an unknown permission scope', { permissions: ['everything'] }, 'schema_invalid'],
    ['requesting the core scope', { permissions: ['core'] }, 'permission_required'],
    ['an unknown hot_swap level', { hot_swap: 'magic' }, 'schema_invalid'],
    ['a zero cleanup timeout', { cleanup: { timeout_ms: 0 } }, 'schema_invalid'],
    ['a service budget over policy', { resource_budget: { memory_mib: 128, cpu_percent: 5 } }, 'budget_exceeded'],
    ['conflicting with itself', { conflicts: ['ditto.example.counter'] }, 'declared_conflict'],
  ])('rejects %s', (_label, patch, code) => {
    expect(codes(withField(patch))).toContain(code)
  })

  it('accepts additive settings metadata with or without the generated schema', () => {
    for (const options of [{}, { schema }]) {
      for (const settings_page of [undefined, null, { page_id: 'history', title_key: 'command.history.open', order: 30 }, { page_id: 'a_1', title_key: '', order: -2147483648, category: 'general' }]) {
        const result = validateManifest(settings_page === undefined ? counter : withField({ settings_page }), options)
        expect(result.errors).toEqual([])
        expect(result.warnings.some(w => w.path === '/settings_page')).toBe(false)
      }
    }
  })

  it.each([
    { page_id: 'History' }, { page_id: '' }, { page_id: 'a'.repeat(33) }, { page_id: 'a-b' },
    { title_key: 1 }, { order: 1.2 }, { order: 2147483648 }, { category: 4 }, { extra: true },
  ])('rejects malformed settings metadata %j', patch => {
    for (const options of [{}, { schema }]) expect(codes(withField({ settings_page: { page_id: 'history', title_key: 'history', order: 30, ...patch } }), options)).toContain('schema_invalid')
  })

  it('warns, without failing, where only Core policy can decide', () => {
    const result = validateManifest(withField({ trust_level: 'community', extra: 1 }))
    expect(result.ok).toBe(true)
    expect(result.warnings.map(issue => issue.code)).toEqual(expect.arrayContaining(['precondition_failed', 'unknown_field']))
  })

  it('runs a plugged-in JSON Schema (the Rust-generated schema/manifest.json) before the TypeScript rules', () => {
    const schema: JsonSchema = {
      $defs: { Kind: { enum: ['service', 'qml_provider'] } },
      type: 'object',
      required: ['id', 'plugin_kind'],
      properties: { plugin_kind: { $ref: '#/$defs/Kind' }, id: { type: 'string', pattern: '^ditto\\.' } },
    }
    expect(validateManifest(counter, { schema }).ok).toBe(true)
    const result = validateManifest(withField({ id: 'acme.counter' }), { schema })
    expect(result.errors.filter(issue => issue.code === 'schema_invalid').map(issue => issue.path)).toContain('/id')
  })
})

describe('ditto-plugin validate / pack', () => {
  it('finds a provided capability without a handler by mounting the entry in the test host', async () => {
    const dir = join(scratch, 'missing-handler')
    cpSync(join(packages, 'plugin-fixtures/cordis/greeting'), dir, { recursive: true })
    const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'))
    manifest.provides.push({ capability: 'plugin.ditto.fixture.greeting.set' })
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest))
    await packPackage(dir).catch(() => {})
    const result = await validatePackage(dir)
    expect(result.ok).toBe(false)
    expect(result.errors).toEqual([expect.objectContaining({ code: 'handler_missing', message: expect.stringContaining('plugin.ditto.fixture.greeting.set') })])
    expect(result.registered).toEqual(['plugin.ditto.fixture.greeting.get'])
  })

  it('packs manifest.json plus dist/ as tar+zstd, reproducibly, and reports the sha256 of the whole file', async () => {
    const dir = join(scratch, 'counter')
    cpSync(join(packages, 'host-sdk/examples/counter'), dir, { recursive: true, filter: source => !source.includes('/dist') })
    const first = await packPackage(dir, { out: join(scratch, 'a.dittopkg') })
    const second = await packPackage(dir, { out: join(scratch, 'b.dittopkg') })
    expect(first.sha256).toMatch(/^[0-9a-f]{64}$/)
    expect(second.sha256).toBe(first.sha256)
    const listing = spawnSync('tar', ['--zstd', '-tf', first.file], { encoding: 'utf8' }).stdout.trim().split('\n')
    expect(listing).toEqual(['manifest.json', 'dist/', 'dist/index.mjs'])
    const sum = spawnSync('sha256sum', [first.file], { encoding: 'utf8' }).stdout.split(' ')[0]
    expect(sum).toBe(first.sha256)
  })

  it('refuses to pack an invalid manifest', async () => {
    const dir = join(scratch, 'bad')
    cpSync(join(packages, 'plugin-fixtures/qml/clock'), dir, { recursive: true })
    const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'))
    manifest.required_protocol_version = '^0.1'
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest))
    await expect(packPackage(dir)).rejects.toThrow(/protocol_incompatible/)
  })

  it('detects bare imports a bundle would need at run time', () => {
    expect(bareImports('import { a } from "node:fs"; import x from "lodash"; const y = import("left-pad")')).toEqual(['lodash', 'left-pad'])
    expect(bareImports('export { a as b } from "node:path"')).toEqual([])
  })
})
