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

/**
 * Own keys only, everywhere: a schema keyword, a `$ref` step, a property of a value or of an `enum`
 * member is read only when the object itself has it, never through the prototype. `toString`,
 * `constructor`, `hasOwnProperty` and `__proto__` (an own key after `JSON.parse`) are ordinary names,
 * as they are for Core (crates/ditto-protocol/src/config_schema.rs).
 */
function hasOwn(object: object, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, key)
}

function own(object: unknown, key: string): unknown {
  return typeof object === 'object' && object !== null && hasOwn(object, key)
    ? (object as Record<string, unknown>)[key]
    : undefined
}

/** JSON equality: same type, numbers by value, arrays item by item, objects by their own keys. */
function equal(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  const ka = Object.keys(a)
  const kb = Object.keys(b)
  return ka.length === kb.length && ka.every(key => hasOwn(b, key) && equal(own(a, key), own(b, key)))
}

function resolveRef(root: JsonSchema, ref: string): JsonSchema {
  if (!ref.startsWith('#')) throw new Error(`only local $ref is supported: ${ref}`)
  let node: unknown = root
  for (const part of ref.slice(1).split('/').filter(Boolean)) {
    node = own(node, part.replace(/~1/g, '/').replace(/~0/g, '~'))
  }
  if (node === undefined) throw new Error(`unresolved $ref ${ref}`)
  return node as JsonSchema
}

export function validateJsonSchema(schema: JsonSchema, value: unknown, root: JsonSchema = schema, path = ''): SchemaIssue[] {
  if (schema === true) return []
  if (schema === false) return [{ path: path || '/', message: 'no value is allowed here' }]
  const issues: SchemaIssue[] = []
  const at = path || '/'
  const keyword = (name: string) => own(schema, name)

  const ref = keyword('$ref')
  if (typeof ref === 'string') issues.push(...validateJsonSchema(resolveRef(root, ref), value, root, path))

  const type = keyword('type')
  if (type !== undefined) {
    const types = Array.isArray(type) ? type as string[] : [type as string]
    if (!types.some(t => matchesType(value, t))) {
      issues.push({ path: at, message: `expected ${types.join(' | ')}, got ${typeOf(value)}` })
      return issues
    }
  }
  if (hasOwn(schema, 'const') && !equal(value, keyword('const'))) issues.push({ path: at, message: `must equal ${JSON.stringify(keyword('const'))}` })
  const choices = keyword('enum')
  if (Array.isArray(choices) && !choices.some(item => equal(item, value))) {
    issues.push({ path: at, message: `must be one of ${choices.map(item => JSON.stringify(item)).join(', ')}` })
  }

  const bound = (name: string) => { const n = keyword(name); return typeof n === 'number' ? n : undefined }
  if (typeof value === 'number') {
    const minimum = bound('minimum'), maximum = bound('maximum')
    const exclusiveMinimum = bound('exclusiveMinimum'), exclusiveMaximum = bound('exclusiveMaximum')
    if (minimum !== undefined && value < minimum) issues.push({ path: at, message: `must be ≥ ${minimum}` })
    if (maximum !== undefined && value > maximum) issues.push({ path: at, message: `must be ≤ ${maximum}` })
    if (exclusiveMinimum !== undefined && value <= exclusiveMinimum) issues.push({ path: at, message: `must be > ${exclusiveMinimum}` })
    if (exclusiveMaximum !== undefined && value >= exclusiveMaximum) issues.push({ path: at, message: `must be < ${exclusiveMaximum}` })
  }
  if (typeof value === 'string') {
    const minLength = bound('minLength'), maxLength = bound('maxLength'), pattern = keyword('pattern')
    if (minLength !== undefined && [...value].length < minLength) issues.push({ path: at, message: `must be at least ${minLength} characters` })
    if (maxLength !== undefined && [...value].length > maxLength) issues.push({ path: at, message: `must be at most ${maxLength} characters` })
    if (typeof pattern === 'string' && !new RegExp(pattern, 'u').test(value)) issues.push({ path: at, message: `must match ${pattern}` })
  }
  if (Array.isArray(value)) {
    const minItems = bound('minItems'), maxItems = bound('maxItems')
    if (minItems !== undefined && value.length < minItems) issues.push({ path: at, message: `needs at least ${minItems} items` })
    if (maxItems !== undefined && value.length > maxItems) issues.push({ path: at, message: `allows at most ${maxItems} items` })
    if (keyword('uniqueItems') === true && value.some((item, i) => value.findIndex(other => equal(other, item)) !== i)) issues.push({ path: at, message: 'items must be unique' })
    const prefixItems = keyword('prefixItems')
    const prefix = Array.isArray(prefixItems) ? prefixItems as JsonSchema[] : []
    const items = keyword('items')
    value.forEach((item, i) => {
      const itemSchema = i < prefix.length ? prefix[i] : items
      if (itemSchema !== undefined) issues.push(...validateJsonSchema(itemSchema as JsonSchema, item, root, `${path}/${i}`))
    })
  }
  if (typeOf(value) === 'object') {
    const object = value as Record<string, unknown>
    const properties = keyword('properties') ?? {}
    const additional = keyword('additionalProperties')
    for (const key of (keyword('required') as string[] | undefined) ?? []) {
      if (!hasOwn(object, key)) issues.push({ path: `${path}/${key}`, message: 'is required' })
    }
    for (const [key, item] of Object.entries(object)) {
      if (hasOwn(properties as object, key)) issues.push(...validateJsonSchema(own(properties, key) as JsonSchema, item, root, `${path}/${key}`))
      else if (additional !== undefined) issues.push(...validateJsonSchema(additional as JsonSchema, item, root, `${path}/${key}`))
    }
  }

  const allOf = keyword('allOf'), anyOf = keyword('anyOf'), oneOf = keyword('oneOf')
  if (Array.isArray(allOf)) for (const sub of allOf as JsonSchema[]) issues.push(...validateJsonSchema(sub, value, root, path))
  if (Array.isArray(anyOf) && !(anyOf as JsonSchema[]).some(sub => validateJsonSchema(sub, value, root, path).length === 0)) {
    issues.push({ path: at, message: 'matches none of the allowed shapes (anyOf)' })
  }
  if (Array.isArray(oneOf)) {
    const matches = (oneOf as JsonSchema[]).filter(sub => validateJsonSchema(sub, value, root, path).length === 0).length
    if (matches !== 1) issues.push({ path: at, message: `must match exactly one shape (oneOf), matched ${matches}` })
  }
  return issues
}

/**
 * Keywords manifest.md allows inside a plugin's `config_schema`. Core checks entry configs with the
 * same subset and the same judgement as `validateJsonSchema` (crates/ditto-protocol/src/config_schema.rs);
 * change both together. tests/config-schema/parity.json holds cases both sides run.
 */
export const configSchemaKeywords = new Set([
  'type', 'properties', 'required', 'enum', 'items', 'default', 'minimum', 'maximum', 'additionalProperties',
  // Annotations that change nothing about validation.
  'title', 'description', '$schema',
])

const isSchemaObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

/**
 * Is this a `config_schema` Core can judge? The same rule as Core's `config_schema::supported`, which
 * Core runs when a package is installed: an object schema with `"type": "object"` at the top, only
 * `configSchemaKeywords`, `properties` an object (or null), `required` a list of strings (or null), and
 * every subschema (a property, `items`, `additionalProperties`) an object or a boolean. Runs on the
 * schema alone, whatever defaults it declares.
 */
export function configSchemaIssues(schema: unknown, path = '/config_schema'): SchemaIssue[] {
  if (!isSchemaObject(schema)) return [{ path, message: 'config_schema must be a JSON Schema object' }]
  if (own(schema, 'type') !== 'object') return [{ path: `${path}/type`, message: 'the top level must be an object schema' }]
  return subschemaIssues(schema, path)
}

function subschemaIssues(node: unknown, path: string): SchemaIssue[] {
  if (typeof node === 'boolean') return []
  if (!isSchemaObject(node)) return [{ path, message: 'a subschema must be an object or a boolean' }]
  const issues: SchemaIssue[] = []
  for (const [key, value] of Object.entries(node)) {
    const here = `${path}/${key}`
    if (!configSchemaKeywords.has(key)) {
      issues.push({ path: here, message: `keyword "${key}" is outside the config_schema subset` })
    } else if (key === 'properties') {
      if (value === null) continue
      if (!isSchemaObject(value)) issues.push({ path: here, message: 'properties must be an object' })
      else for (const [name, sub] of Object.entries(value)) issues.push(...subschemaIssues(sub, `${here}/${name}`))
    } else if (key === 'required') {
      if (value !== null && !(Array.isArray(value) && value.every(name => typeof name === 'string'))) {
        issues.push({ path: here, message: 'required must be a list of property names' })
      }
    } else if (key === 'items' || key === 'additionalProperties') {
      issues.push(...subschemaIssues(value, here))
    }
  }
  return issues
}

/** @deprecated Keywords only; use `configSchemaIssues`, which also checks the shape Core needs. */
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
