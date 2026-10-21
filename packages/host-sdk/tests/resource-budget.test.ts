import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { validateManifest, type JsonSchema } from '../src/manifest/index.ts'
import { validatePackage } from '../src/package.ts'

const root = fileURLToPath(new URL('../../../', import.meta.url))
const panelDir = join(root, 'shell/providers/panel_top')
const panel = JSON.parse(readFileSync(join(panelDir, 'manifest.json'), 'utf8'))
const service = JSON.parse(readFileSync(join(root, 'packages/host-sdk/examples/counter/manifest.json'), 'utf8'))
const schema = JSON.parse(readFileSync(join(root, 'schema/manifest.json'), 'utf8')) as JsonSchema
const scratch = mkdtempSync(join(tmpdir(), 'ditto-budget-'))
cpSync(panelDir, scratch, { recursive: true })
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

// Rust ResourceBudget: deny_unknown_fields, two defaulted Option<u32> fields.
const valid: [string, unknown][] = [
  ['absent budget', undefined], ['empty object', {}],
  ['memory only', { memory_mib: 8 }], ['CPU only', { cpu_percent: 2 }],
  ['both fields', { memory_mib: 8, cpu_percent: 2 }],
  ['null memory', { memory_mib: null }], ['null CPU', { cpu_percent: null }],
  ['both null', { memory_mib: null, cpu_percent: null }],
  ['memory with null sibling', { memory_mib: 8, cpu_percent: null }],
  ['CPU with null sibling', { memory_mib: null, cpu_percent: 2 }],
  ['zero memory', { memory_mib: 0 }], ['zero CPU', { cpu_percent: 0 }],
  ['both zero', { memory_mib: 0, cpu_percent: 0 }],
  ['u32 maximum memory', { memory_mib: 4_294_967_295 }],
  ['u32 maximum CPU', { cpu_percent: 4_294_967_295 }],
]
const invalid: [string, unknown, string][] = [
  ['null budget', null, '/resource_budget'], ['array budget', [], '/resource_budget'],
  ['number budget', 8, '/resource_budget'], ['string budget', '8', '/resource_budget'],
  ['boolean budget', false, '/resource_budget'],
  ['unknown key', { memory_mib: 8, cpu_percent: 2, extra: 1 }, '/resource_budget/extra'],
  ...['memory_mib', 'cpu_percent'].flatMap(field => [
    ['overflow', 4_294_967_296], ['unsafe integer', Number.MAX_SAFE_INTEGER + 1],
    ['fraction', 0.5], ['negative', -1], ['string', '8'], ['boolean', true], ['array', []], ['object', {}],
  ].map(([label, value]): [string, unknown, string] => [
    `${field} ${label}`, { memory_mib: 0, cpu_percent: 0, [field]: value }, `/resource_budget/${field}`,
  ])),
]

describe.each([
  ['without schema', {}], ['with Rust-generated schema', { schema }],
] as const)('resource budget %s', (_mode, options) => {
  // Exercise serialized manifests through the same package validator the CLI/packer use.
  it.each(valid)('accepts %s', async (_label, budget) => {
    const manifest = { ...panel, resource_budget: budget }
    const serialized = JSON.stringify(manifest)
    expect(validateManifest(JSON.parse(serialized), options).errors).toEqual([])
    writeFileSync(join(scratch, 'manifest.json'), serialized)
    expect((await validatePackage(scratch, options)).errors).toEqual([])
  })

  it.each(invalid)('rejects %s', async (_label, budget, path) => {
    const serialized = JSON.stringify({ ...panel, resource_budget: budget })
    const expected = expect.arrayContaining([expect.objectContaining({ path, code: 'schema_invalid' })])
    expect(validateManifest(JSON.parse(serialized), options).errors).toEqual(expected)
    writeFileSync(join(scratch, 'manifest.json'), serialized)
    expect((await validatePackage(scratch, options)).errors).toEqual(expected)
  })

  it.each(['memory_mib', 'cpu_percent'])('rejects nonfinite %s before serialization', field => {
    // JSON.stringify turns these into null; the direct SDK API must reject the original numbers.
    for (const value of [NaN, Infinity, -Infinity]) {
      expect(validateManifest({ ...panel, resource_budget: { memory_mib: 0, cpu_percent: 0, [field]: value } }, options).errors)
        .toContainEqual(expect.objectContaining({ path: `/resource_budget/${field}`, code: 'schema_invalid' }))
    }
  })

  it.each([
    { memory_mib: 64 }, { cpu_percent: 10 }, { memory_mib: 64, cpu_percent: 10 },
    { memory_mib: 64, cpu_percent: null }, { memory_mib: null, cpu_percent: 10 },
  ])('accepts service ceilings independently: %j', budget => {
    expect(validateManifest(JSON.parse(JSON.stringify({ ...service, resource_budget: budget })), options).errors).toEqual([])
  })

  it.each([
    { memory_mib: 65 }, { cpu_percent: 11 }, { memory_mib: 65, cpu_percent: null },
    { memory_mib: null, cpu_percent: 11 }, { memory_mib: 65, cpu_percent: 2 },
    { memory_mib: 8, cpu_percent: 11 },
  ])('refuses an over-ceiling service value even with an absent/null sibling: %j', budget => {
    expect(validateManifest(JSON.parse(JSON.stringify({ ...service, resource_budget: budget })), options).errors)
      .toContainEqual(expect.objectContaining({ path: '/resource_budget', code: 'budget_exceeded' }))
  })
})
