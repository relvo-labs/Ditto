import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';
import { activeDocAgrees, checkLicense, immutableManifestError } from './check-license.mjs';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root));
const baseline = checkLicense({ read });
function changed(group, path, transform) {
  return checkLicense({ read: candidate => candidate === path ? transform(read(candidate).toString()) : read(candidate) })
    .find(result => result.name === group).errors;
}

for (const group of ['canonical MIT', 'Cargo license fields', 'first-party JSON metadata',
  'generated user default', 'vendor LICENSE/NOTICE hashes', 'active licensing docs', 'immutable builtin manifests']) {
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
test('every relicensed builtin rejects restoration of its former version', () => {
  const { packages } = JSON.parse(read('tests/licensing/pre-mit-builtin-manifests.json'));
  for (const previous of packages) {
    const errors = changed('immutable builtin manifests', previous.path, text => {
      const current = JSON.parse(text);
      current.version = previous.version;
      return JSON.stringify(current);
    });
    assert.equal(errors.length, 1, previous.path);
    assert.match(errors[0], /changed archived manifest bytes require a new version/);
  }
});
test('metadata-only archived edits need a new identity; unchanged bytes and later versions pass', () => {
  const old = JSON.stringify({ id: 'ditto.test.provider', version: '1.0.0', license: 'UNLICENSED', author: 'Ditto' });
  const previous = { id: 'ditto.test.provider', version: '1.0.0', sha256: createHash('sha256').update(old).digest('hex') };
  assert.equal(immutableManifestError(previous, old), null);
  for (const patch of [{ license: 'MIT' }, { author: 'Ditto contributors' }]) {
    const current = { ...JSON.parse(old), ...patch };
    assert.match(immutableManifestError(previous, JSON.stringify(current)), /new version/);
    for (const version of ['1.0.1', '1.2.0', '2.0.0']) {
      assert.equal(immutableManifestError(previous, JSON.stringify({ ...current, version })), null);
    }
  }
  assert.match(immutableManifestError(previous, old.replace('ditto.test.provider', 'ditto.test.other')), /ID/);
});
test('missing or malformed immutable baseline fails closed', () => {
  const path = 'tests/licensing/pre-mit-builtin-manifests.json';
  for (const text of ['{', '{}', '{"packages":[]}', '{"packages":[{}]}']) {
    assert.equal(changed('immutable builtin manifests', path, () => text).length, 1);
  }
  const result = checkLicense({ read: candidate => {
    if (candidate === path) throw Error('missing fixture');
    return read(candidate);
  } });
  assert.equal(result.find(group => group.name === 'immutable builtin manifests').errors.length, 1);
});

// Parse and execute the actual fixture JavaScript without provisioning Qt or
// claiming a QML runtime test. These pins describe real source providers.
function qmlFunction(text, name) {
  const source = text.match(new RegExp(`^    function ${name}\\([^)]*\\) \\{[\\s\\S]*?^    \\}`, 'm'))?.[0];
  assert.ok(source, `missing ${name}`);
  return source;
}
test('visual client fixture entries and package metadata match authoritative manifests', () => {
  const text = read('tests/g4/visual/fixtures/AppFixtureClient.qml').toString();
  const source = qmlFunction(text, 'packageVersion');
  const manifests = baseline.find(group => group.name === 'immutable builtin manifests');
  assert.deepEqual(manifests.errors, []);
  const rows = JSON.parse(read('tests/licensing/pre-mit-builtin-manifests.json')).packages;
  const lookup = new Map(rows.map(row => [row.id, JSON.parse(read(row.path)).version]));
  const entries = text.match(/readonly property var entries: (\[[\s\S]*?\n    \])/)[1];
  const installed = text.match(/readonly property var installed: (\[[\s\S]*?\n    \])/)[1];
  const value = runInNewContext(`${source}; ({ entries: ${entries}, installed: ${installed} })`);
  for (const entry of value.entries) assert.equal(entry.version, lookup.get(entry.package), entry.package);
  for (const [id] of value.installed) assert.equal(runInNewContext(`${source}; packageVersion(id)`, { id }), lookup.get(id), id);
});
test('shell extension source fixtures use the real provider versions', () => {
  const text = read('tests/shell-extensions/unit/tst_extensions.qml').toString();
  const source = qmlFunction(text, 'packagedVersion');
  for (const id of ['history', 'composition', 'plugins', 'personalization', 'ai', 'background']) {
    const directory = id === 'background' ? 'background_default' : `settings_${id}`;
    const manifest = JSON.parse(read(`shell/providers/${directory}/manifest.json`));
    assert.equal(runInNewContext(`${source}; packagedVersion(id)`, { id }), manifest.version, id);
  }
  assert.match(text, /binding\.version = packagedVersion\(data\.id\)/);
  assert.equal((text.match(/version: packagedVersion\("background"\)/g) || []).length, 3);
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
