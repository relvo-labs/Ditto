// Offline fallback for the shape-vector suite whose shared beforeAll needs
// a Core socket. Uses the repository's actual TypeScript schema checker.
// node --experimental-strip-types tests/g4/visual/check-assistant-contracts.mjs <25c0b72-profile-schema.json>
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { check } from '../../../packages/protocol/src/schema-check.ts';
const root = resolve(import.meta.dirname, '../../..');
const read = path => JSON.parse(readFileSync(path, 'utf8'));
let count = 0;
for (const name of readdirSync(resolve(root, 'tests/contract-vectors/0.3'))) {
  if (!name.endsWith('.json')) continue;
  const vector = read(resolve(root, 'tests/contract-vectors/0.3', name));
  if (vector.kind !== 'shape') continue;
  const errors = check(read(resolve(root, 'schema', vector.type + '.json')), vector.value);
  assert.equal(errors.length === 0, vector.valid, name + ': ' + JSON.stringify(errors));
  count++;
}
const oldSchema = read(process.argv[2]);
const currentSchema = read(resolve(root, 'schema/profile-document.json'));
const legacy = {
  schema_version: 1, entries: [], slots: {}, layout: { workspace_grid: [3,3], rules: [] },
  appearance: { theme: 'soft-jelly', tokens: {}, reduced_motion: false, reduced_transparency: false, low_power_style: false, locale: 'zh-TW' },
  shortcuts: [], avatar: { enabled: true, hidden: false, scale: 1.75, animations: false, output: 'HDMI-A-2', corner: 'top_left' },
};
assert.deepEqual(check(oldSchema, legacy), []);
assert.deepEqual(check(currentSchema, legacy), []);
const assistant = structuredClone(legacy);
assistant.avatar.presentation = 'assistant';
assert.deepEqual(check(currentSchema, assistant), []);
const refused = check(oldSchema, assistant);
assert(refused.some(error => error.path.includes('presentation')), JSON.stringify(refused));
const downgrade = structuredClone(assistant);
delete downgrade.avatar.presentation; // explicit downgrade, never implicit import behaviour
assert.deepEqual(check(oldSchema, downgrade), []);
assert.deepEqual(downgrade, legacy);
console.log(`${count} shared shape vectors passed; pinned old schema rejects assistant and accepts explicit downgrade`);
