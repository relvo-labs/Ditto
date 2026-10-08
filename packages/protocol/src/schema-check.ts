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

export function check(root: Schema, value: unknown, options: {strict?:boolean} = {}): Problem[] {
  const problems: Problem[] = [];
  const allowed=new Set(['$schema','$id','$ref','$defs','definitions','title','description','default','examples','deprecated','readOnly','writeOnly','type','properties','required','additionalProperties','enum','const','oneOf','anyOf','allOf','items','minimum','maximum','exclusiveMinimum','exclusiveMaximum','minItems','maxItems','minLength','maxLength','pattern','format']);
  let visited=0;
  if(options.strict){
    // Inspect the whole schema, including absent optional properties and
    // unused alternatives. Unsupported constraints must never be ignored.
    let count=0;
    const inspect=(schema:Schema,depth=0):void=>{
      if(++count>10000||depth>128)throw new Error('schema inspection budget exceeded');
      if(typeof schema==='boolean')return;
      if(!schema||typeof schema!=='object'||Array.isArray(schema))throw new Error('invalid schema');
      for(const keyword of Object.keys(schema))if(!allowed.has(keyword))throw new Error(`unsupported schema keyword ${keyword}`);
      if(typeof schema.format==='string'&&!['uint','uint32','uint64','int32','int64','float','double'].includes(schema.format))throw new Error('unsupported schema format');
      for(const key of ['$defs','definitions','properties']){
        const children=schema[key];if(children&&typeof children==='object')for(const child of Object.values(children))inspect(child as Schema,depth+1);
      }
      for(const key of ['oneOf','anyOf','allOf'])if(Array.isArray(schema[key]))for(const child of schema[key] as Schema[])inspect(child,depth+1);
      for(const key of ['items','additionalProperties'])if(schema[key]!==undefined)inspect(schema[key] as Schema,depth+1);
    };
    inspect(root);
  }
  const resolve = (reference: string): Schema => {
    if (!reference.startsWith('#/')) throw new Error(`unsupported $ref ${reference}`);
    let node: unknown = root;
    for (const part of reference.slice(2).split('/')) {
      const key=part.replaceAll('~1','/').replaceAll('~0','~');
      if(!node||typeof node!=='object'||!Object.hasOwn(node,key))throw new Error('unresolved schema reference');
      node = (node as Record<string, unknown>)[key];
    }
    return node as Schema;
  };
  const visit = (schema: Schema, current: unknown, path: string, into: Problem[]): void => {
    if(++visited>100_000||path.split('/').length>128)throw new Error('schema validation budget exceeded');
    if (schema === true) return;
    if (schema === false) { into.push({ path, message: 'no value allowed' }); return; }
    if(!schema||typeof schema!=='object'||Array.isArray(schema))throw new Error('invalid schema');
    if(options.strict){
      for(const keyword of Object.keys(schema))if(!allowed.has(keyword))throw new Error(`unsupported schema keyword ${keyword}`);
      if(typeof schema.format==='string'&&!['uint','uint32','uint64','int32','int64','float','double'].includes(schema.format))throw new Error('unsupported schema format');
    }
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
      if(!Number.isFinite(current)||Object.is(current,-0)||Number.isInteger(current)&&!Number.isSafeInteger(current))into.push({path,message:'number is not lossless JSON'});
      if (typeof schema.minimum === 'number' && current < schema.minimum) into.push({ path, message: 'below minimum' });
      if (typeof schema.maximum === 'number' && current > schema.maximum) into.push({ path, message: 'above maximum' });
      if(typeof schema.exclusiveMinimum==='number'&&current<=schema.exclusiveMinimum)into.push({path,message:'below exclusive minimum'});
      if(typeof schema.exclusiveMaximum==='number'&&current>=schema.exclusiveMaximum)into.push({path,message:'above exclusive maximum'});
    }
    if(typeof current==='string'){
      const length=[...current].length;
      if(typeof schema.minLength==='number'&&length<schema.minLength)into.push({path,message:'string is too short'});
      if(typeof schema.maxLength==='number'&&length>schema.maxLength)into.push({path,message:'string is too long'});
      if(typeof schema.pattern==='string'&&!new RegExp(schema.pattern,'u').test(current))into.push({path,message:'pattern mismatch'});
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
        if (!Object.hasOwn(object,key)) into.push({ path: `${path}/${key}`, message: 'required' });
      }
      for (const [key, item] of Object.entries(object)) {
        if (Object.hasOwn(properties,key)) visit(properties[key], item, `${path}/${key}`, into);
        else if (schema.additionalProperties === false) into.push({ path: `${path}/${key}`, message: 'unknown field' });
        else if (typeof schema.additionalProperties === 'object') visit(schema.additionalProperties as Schema, item, `${path}/${key}`, into);
      }
    }
    if (Array.isArray(current)) {
      if(typeof schema.minItems==='number'&&current.length<schema.minItems)into.push({path,message:'too few array items'});
      if(typeof schema.maxItems==='number'&&current.length>schema.maxItems)into.push({path,message:'too many array items'});
      if(schema.items!==undefined)current.forEach((item, index) => visit(schema.items as Schema, item, `${path}/${index}`, into));
    }
  };
  visit(root, value, '', problems);
  return problems;
}
