/**
 * A small JSON Schema (draft 2020-12) evaluator: enough for the subset
 * manifest.md allows in `config_schema`, and for the keywords a
 * schemars-generated `schema/manifest.json` uses ($ref/$defs, anyOf/oneOf/allOf,
 * const, pattern, length and item bounds). Unknown keywords are ignored, as the
 * spec requires; `format` is annotation only.
 */
export type JsonSchema = boolean | { [keyword: string]: unknown }

export interface SchemaIssue {
  path: string
  message: string
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json }

function typeOf(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number'
  return typeof value
}

function matchesType(value: unknown, type: string): boolean {
  const actual = typeOf(value)
  return actual === type || (type === 'number' && actual === 'integer')
}

function equal(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  const ka = Object.keys(a)
  const kb = Object.keys(b)
  return ka.length === kb.length && ka.every(key => equal((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key]))
}

function resolveRef(root: JsonSchema, ref: string): JsonSchema {
  if (!ref.startsWith('#')) throw new Error(`only local $ref is supported: ${ref}`)
  let node: unknown = root
  for (const part of ref.slice(1).split('/').filter(Boolean)) {
    node = (node as Record<string, unknown>)?.[part.replace(/~1/g, '/').replace(/~0/g, '~')]
  }
  if (node === undefined) throw new Error(`unresolved $ref ${ref}`)
  return node as JsonSchema
}

export function validateJsonSchema(schema: JsonSchema, value: unknown, root: JsonSchema = schema, path = ''): SchemaIssue[] {
  if (schema === true) return []
  if (schema === false) return [{ path: path || '/', message: 'no value is allowed here' }]
  const issues: SchemaIssue[] = []
  const at = path || '/'
  const s = schema as Record<string, unknown>

  if (typeof s['$ref'] === 'string') issues.push(...validateJsonSchema(resolveRef(root, s['$ref']), value, root, path))

  const type = s['type']
  if (type !== undefined) {
    const types = Array.isArray(type) ? type as string[] : [type as string]
    if (!types.some(t => matchesType(value, t))) {
      issues.push({ path: at, message: `expected ${types.join(' | ')}, got ${typeOf(value)}` })
      return issues
    }
  }
  if ('const' in s && !equal(value, s['const'])) issues.push({ path: at, message: `must equal ${JSON.stringify(s['const'])}` })
  if (Array.isArray(s['enum']) && !s['enum'].some(item => equal(item, value))) {
    issues.push({ path: at, message: `must be one of ${s['enum'].map(item => JSON.stringify(item)).join(', ')}` })
  }

  if (typeof value === 'number') {
    if (typeof s['minimum'] === 'number' && value < s['minimum']) issues.push({ path: at, message: `must be ≥ ${s['minimum']}` })
    if (typeof s['maximum'] === 'number' && value > s['maximum']) issues.push({ path: at, message: `must be ≤ ${s['maximum']}` })
    if (typeof s['exclusiveMinimum'] === 'number' && value <= s['exclusiveMinimum']) issues.push({ path: at, message: `must be > ${s['exclusiveMinimum']}` })
    if (typeof s['exclusiveMaximum'] === 'number' && value >= s['exclusiveMaximum']) issues.push({ path: at, message: `must be < ${s['exclusiveMaximum']}` })
  }
  if (typeof value === 'string') {
    if (typeof s['minLength'] === 'number' && [...value].length < s['minLength']) issues.push({ path: at, message: `must be at least ${s['minLength']} characters` })
    if (typeof s['maxLength'] === 'number' && [...value].length > s['maxLength']) issues.push({ path: at, message: `must be at most ${s['maxLength']} characters` })
    if (typeof s['pattern'] === 'string' && !new RegExp(s['pattern'], 'u').test(value)) issues.push({ path: at, message: `must match ${s['pattern']}` })
  }
  if (Array.isArray(value)) {
    if (typeof s['minItems'] === 'number' && value.length < s['minItems']) issues.push({ path: at, message: `needs at least ${s['minItems']} items` })
    if (typeof s['maxItems'] === 'number' && value.length > s['maxItems']) issues.push({ path: at, message: `allows at most ${s['maxItems']} items` })
    if (s['uniqueItems'] === true && value.some((item, i) => value.findIndex(other => equal(other, item)) !== i)) issues.push({ path: at, message: 'items must be unique' })
    const prefix = Array.isArray(s['prefixItems']) ? s['prefixItems'] as JsonSchema[] : []
    value.forEach((item, i) => {
      const itemSchema = i < prefix.length ? prefix[i] : s['items']
      if (itemSchema !== undefined) issues.push(...validateJsonSchema(itemSchema as JsonSchema, item, root, `${path}/${i}`))
    })
  }
  if (typeOf(value) === 'object') {
    const object = value as Record<string, unknown>
    const properties = (s['properties'] ?? {}) as Record<string, JsonSchema>
    for (const key of (s['required'] as string[] | undefined) ?? []) {
      if (!(key in object)) issues.push({ path: `${path}/${key}`, message: 'is required' })
    }
    for (const [key, item] of Object.entries(object)) {
      if (key in properties) issues.push(...validateJsonSchema(properties[key]!, item, root, `${path}/${key}`))
      else if (s['additionalProperties'] !== undefined) issues.push(...validateJsonSchema(s['additionalProperties'] as JsonSchema, item, root, `${path}/${key}`))
    }
  }

  if (Array.isArray(s['allOf'])) for (const sub of s['allOf'] as JsonSchema[]) issues.push(...validateJsonSchema(sub, value, root, path))
  if (Array.isArray(s['anyOf']) && !(s['anyOf'] as JsonSchema[]).some(sub => validateJsonSchema(sub, value, root, path).length === 0)) {
    issues.push({ path: at, message: 'matches none of the allowed shapes (anyOf)' })
  }
  if (Array.isArray(s['oneOf'])) {
    const matches = (s['oneOf'] as JsonSchema[]).filter(sub => validateJsonSchema(sub, value, root, path).length === 0).length
    if (matches !== 1) issues.push({ path: at, message: `must match exactly one shape (oneOf), matched ${matches}` })
  }
  return issues
}

/** Keywords manifest.md allows inside a plugin's `config_schema`. */
export const configSchemaKeywords = new Set([
  'type', 'properties', 'required', 'enum', 'items', 'default', 'minimum', 'maximum', 'additionalProperties',
  // Annotations that change nothing about validation.
  'title', 'description', '$schema',
])

export function unsupportedKeywords(schema: unknown, path = '/config_schema'): SchemaIssue[] {
  if (typeof schema !== 'object' || schema === null) return []
  const issues: SchemaIssue[] = []
  for (const [key, value] of Object.entries(schema)) {
    if (!configSchemaKeywords.has(key)) issues.push({ path: `${path}/${key}`, message: `keyword "${key}" is outside the config_schema subset` })
    if (key === 'properties' && value && typeof value === 'object') {
      for (const [name, sub] of Object.entries(value)) issues.push(...unsupportedKeywords(sub, `${path}/properties/${name}`))
    }
    if ((key === 'items' || key === 'additionalProperties') && typeof value === 'object') issues.push(...unsupportedKeywords(value, `${path}/${key}`))
  }
  return issues
}

export type { Json }
