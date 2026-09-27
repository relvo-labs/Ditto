/**
 * A small JSON Schema checker for the subset schemars emits (draft 2020-12):
 * `$ref` into `$defs`, `type` (including arrays of types), `properties`,
 * `required`, `additionalProperties: false`, `enum`, `const`, `oneOf`,
 * `anyOf`, `allOf`, `items`, `minimum`, `maximum`. It exists so the shared
 * contract vectors are judged by the Rust types' own schemas, with no
 * runtime dependency in the protocol package.
 */
type Schema = boolean | { [key: string]: unknown };

export type Problem = { path: string; message: string };

function typeOf(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number';
  return typeof value;
}

function matchesType(value: unknown, wanted: string): boolean {
  const actual = typeOf(value);
  if (wanted === 'number') return actual === 'number' || actual === 'integer';
  return actual === wanted;
}

export function check(root: Schema, value: unknown): Problem[] {
  const problems: Problem[] = [];
  const resolve = (reference: string): Schema => {
    if (!reference.startsWith('#/')) throw new Error(`unsupported $ref ${reference}`);
    let node: unknown = root;
    for (const part of reference.slice(2).split('/')) node = (node as Record<string, unknown>)[part];
    return node as Schema;
  };
  const visit = (schema: Schema, current: unknown, path: string, into: Problem[]): void => {
    if (schema === true) return;
    if (schema === false) { into.push({ path, message: 'no value allowed' }); return; }
    if (typeof schema.$ref === 'string') visit(resolve(schema.$ref), current, path, into);
    if (schema.type !== undefined) {
      const types = Array.isArray(schema.type) ? schema.type as string[] : [schema.type as string];
      if (!types.some(type => matchesType(current, type))) {
        into.push({ path, message: `expected ${types.join('|')}, got ${typeOf(current)}` });
        return;
      }
    }
    if (schema.const !== undefined && JSON.stringify(schema.const) !== JSON.stringify(current)) {
      into.push({ path, message: `expected const ${JSON.stringify(schema.const)}` });
    }
    if (Array.isArray(schema.enum) && !schema.enum.some(item => JSON.stringify(item) === JSON.stringify(current))) {
      into.push({ path, message: `not one of ${JSON.stringify(schema.enum)}` });
    }
    if (typeof current === 'number') {
      if (typeof schema.minimum === 'number' && current < schema.minimum) into.push({ path, message: 'below minimum' });
      if (typeof schema.maximum === 'number' && current > schema.maximum) into.push({ path, message: 'above maximum' });
    }
    if (Array.isArray(schema.allOf)) for (const part of schema.allOf as Schema[]) visit(part, current, path, into);
    for (const [keyword, needExactlyOne] of [['oneOf', true], ['anyOf', false]] as const) {
      const options = schema[keyword];
      if (!Array.isArray(options)) continue;
      const passing = (options as Schema[]).filter(option => {
        const local: Problem[] = [];
        visit(option, current, path, local);
        return local.length === 0;
      }).length;
      if (needExactlyOne ? passing !== 1 : passing === 0) {
        into.push({ path, message: `${keyword}: ${passing} of ${options.length} alternatives match` });
      }
    }
    if (typeOf(current) === 'object') {
      const object = current as Record<string, unknown>;
      const properties = (schema.properties ?? {}) as Record<string, Schema>;
      for (const key of (schema.required ?? []) as string[]) {
        if (!(key in object)) into.push({ path: `${path}/${key}`, message: 'required' });
      }
      for (const [key, item] of Object.entries(object)) {
        if (key in properties) visit(properties[key], item, `${path}/${key}`, into);
        else if (schema.additionalProperties === false) into.push({ path: `${path}/${key}`, message: 'unknown field' });
        else if (typeof schema.additionalProperties === 'object') visit(schema.additionalProperties as Schema, item, `${path}/${key}`, into);
      }
    }
    if (Array.isArray(current) && schema.items !== undefined) {
      current.forEach((item, index) => visit(schema.items as Schema, item, `${path}/${index}`, into));
    }
  };
  visit(root, value, '', problems);
  return problems;
}
