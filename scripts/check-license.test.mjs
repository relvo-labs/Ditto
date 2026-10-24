import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { activeDocAgrees, checkLicense } from './check-license.mjs';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root));
const baseline = checkLicense({ read });
function changed(group, path, transform) {
  return checkLicense({ read: candidate => candidate === path ? transform(read(candidate).toString()) : read(candidate) })
    .find(result => result.name === group).errors;
}

for (const group of ['canonical MIT', 'Cargo license fields', 'first-party JSON metadata',
  'generated user default', 'vendor LICENSE/NOTICE hashes']) {
  test(`${group}: actual source passes`, () => {
    const result = baseline.find(result => result.name === group);
    assert.ok(result.cases > 0);
    assert.deepEqual(result.errors, []);
  });
}
test('MIT text rejects a changed copyright or removed permission', () => {
  for (const transform of [text => text.replace('2026 Ditto contributors', '2025 Someone'),
    text => text.replace('free of charge, ', '')]) {
    assert.equal(changed('canonical MIT', 'LICENSE', transform).length, 1);
  }
});
test('Cargo rejects a workspace license change and missing inheritance', () => {
  assert.equal(changed('Cargo license fields', 'Cargo.toml', text => text.replace('license = "MIT"', 'license = "UNLICENSED"')).length, 1);
  assert.equal(changed('Cargo license fields', 'crates/ditto-core/Cargo.toml', text => text.replace('license.workspace = true', 'license = "Apache-2.0"')).length, 1);
});
test('Node and builtin metadata reject missing, different or malformed licenses', () => {
  for (const path of ['package.json', 'shell/providers/dock_pill/manifest.json', 'packaging/builtin/ditto.layout.floating/manifest.json']) {
    for (const transform of [text => text.replace('"license": "MIT",', ''),
      text => text.replace('"MIT"', '"UNLICENSED"'), () => '{']) {
      assert.equal(changed('first-party JSON metadata', path, transform).length, 1);
    }
  }
});
test('generated user license cannot silently become MIT', () => {
  assert.equal(changed('generated user default', 'crates/ditto-protocol/src/generation.rs',
    text => text.replace('"license":"UNLICENSED"', '"license":"MIT"')).length, 1);
});
test('vendor notices reject even a single added byte', () => {
  assert.equal(changed('vendor LICENSE/NOTICE hashes', 'packages/agent-runtime/vendor/harness/LICENSE', text => text + '\n').length, 1);
});
test('deleted or newly tracked vendor notices require review', () => {
  const added = checkLicense({ files: ['packages/new/vendor/test/NOTICE'], read: path => path.endsWith('/NOTICE') ? 'notice' : read(path) });
  assert.equal(added.find(result => result.name === 'vendor LICENSE/NOTICE hashes').errors.length, 1);
  const missing = checkLicense({ read: path => {
    if (path === 'packages/host-runtime/vendor/cordis/LICENSE') throw Error('missing');
    return read(path);
  } });
  assert.equal(missing.find(result => result.name === 'vendor LICENSE/NOTICE hashes').errors.length, 1);
});
test('active docs reject the prior undecided claims', () => {
  assert.equal(activeDocAgrees('Ditto 自有程式碼採 MIT；第三方義務仍由 owner 處理。'), true);
  for (const text of ['Ditto 自有程式碼目前未指定開源授權；Harness MIT。',
    'Ditto 自有實作目前 UNLICENSED；Harness MIT。',
    '產品授權及商業模式尚未定案；MIT。', '產品授權與商業模式未定案；MIT。']) {
    assert.equal(activeDocAgrees(text), false);
  }
});
