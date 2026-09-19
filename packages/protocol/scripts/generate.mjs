import { compile } from 'json-schema-to-typescript';
import { readFile, readdir, writeFile, mkdir, unlink } from 'node:fs/promises';
import { resolve, basename, join } from 'node:path';

const root = resolve(import.meta.dirname, '../../..');
const source = join(root, 'schema');
const destination = join(root, 'packages/protocol/src/generated');
const checking = process.argv.includes('--check');
const names = (await readdir(source)).filter(name => name.endsWith('.json') && name !== 'catalog.json').sort();
const expected = new Set(names.map(name => basename(name, '.json') + '.ts'));
let stale = false;
if (!checking) await mkdir(destination, { recursive: true });
for (const name of names) {
  const schema = JSON.parse(await readFile(join(source, name), 'utf8'));
  const output = await compile(schema, basename(name, '.json'), {
    bannerComment: '/* Generated from schema/' + name + '; do not edit. */',
    style: { singleQuote: true },
  });
  const path = join(destination, basename(name, '.json') + '.ts');
  if (checking) {
    let previous;
    try { previous = await readFile(path, 'utf8'); } catch { previous = undefined; }
    if (previous !== output) {
      console.error(`stale generated type: ${path}`);
      stale = true;
    }
  } else {
    await writeFile(path, output);
  }
}
for (const existing of (await readdir(destination)).filter(name => name.endsWith('.ts'))) {
  if (!expected.has(existing)) {
    if (checking) { console.error(`orphan generated type: ${existing}`); stale = true; }
    else await unlink(join(destination, existing));
  }
}
if (stale) process.exitCode = 1;
