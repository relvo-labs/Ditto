#!/usr/bin/env node
// Source metadata guard for #200. Run under .nvmrc; no dependency installation.
// Hashes pin the owner-approved SPDX MIT text and pre-adoption vendor notices.
// This does not audit a built distribution or grant rights to third-party assets.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sha256 = value => createHash('sha256').update(value).digest('hex');
const mitHash = '62763273b8df16e6576662e358536ab046061e258770516656701ad4fd1463af';
const cordisHash = '034fb52b1d57360ecbae6cb1632a88f86fd7c3d3f5631a5f082710203dda0be7';
const vendorHashes = {
  'packages/agent-runtime/vendor/harness/LICENSE': 'ebb4f09972aee8608be255debaf78451a68e95c290f55c240dec2ecfa16ea6be',
  ...Object.fromEntries(['cordis', 'cosmokit', 'loader', 'schemastery', 'timer']
    .map(name => [`packages/host-runtime/vendor/${name}/LICENSE`, cordisHash])),
};
const activeDocs = [
  'README.md', 'docs/product/Ditto-PRD-v0.4.0.md',
  'docs/upstream/deepseek-harness.md', 'docs/upstream/g3-adoption.md',
  '.agents/skills/ditto-release-audit/SKILL.md',
];

// Controlled Cargo fields only, not a general TOML parser. cargo metadata is
// the full parser gate when the pinned Rust toolchain is available.
function section(text, name) {
  const header = `[${name}]`;
  const start = text.split('\n').findIndex(line => line.trim() === header);
  if (start < 0) return '';
  return text.split('\n').slice(start + 1).join('\n').split(/^\s*\[/m)[0];
}

export function activeDocAgrees(text) {
  return /MIT/.test(text) && ![
    /自有(?:程式碼|實作)[^。\n|]*(?:未指定|尚無|UNLICENSED)/,
    /自己的專案授權尚未指定/,
    /產品授權(?:及|與)商業模式(?:尚未定案|未定案)/,
  ].some(pattern => pattern.test(text));
}

// The fixture records old immutable identities, not the version of the latest
// release. Later versions remain free to advance without editing this guard.
export function immutableManifestError(previous, text) {
  const current = JSON.parse(text);
  if (current.id !== previous.id) return 'builtin ID must remain stable';
  if (typeof current.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[\w.-]+)?(?:\+[\w.-]+)?$/.test(current.version))
    return 'expected a package version';
  if (current.version === previous.version && sha256(text) !== previous.sha256)
    return 'changed archived manifest bytes require a new version';
  return null;
}

export function checkLicense({
  files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
    { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean),
  read = path => readFileSync(resolve(root, path)),
} = {}) {
  files = [...new Set(files)].sort();
  const results = [];
  function group(name, paths, verify) {
    const errors = [];
    for (const path of paths) {
      try { verify(path, read(path).toString()); }
      catch (error) { errors.push(`${path}: ${error.message}`); }
    }
    results.push({ name, cases: paths.length, errors });
  }
  const require = (ok, message) => { if (!ok) throw new Error(message); };
  group('canonical MIT', ['LICENSE'], (_path, text) => {
    require(sha256(text) === mitHash, 'expected canonical SPDX MIT, copyright 2026 Ditto contributors');
  });
  const cargo = files.filter(path => /(^|\/)Cargo.toml$/.test(path) && !path.includes('/vendor/'));
  group('Cargo license fields', cargo, (path, text) => {
    const fields = section(text, path === 'Cargo.toml' ? 'workspace.package' : 'package');
    require(path === 'Cargo.toml' ? /^license\s*=\s*"MIT"\s*$/m.test(fields)
      : /^license\.workspace\s*=\s*true\s*$/m.test(fields), 'expected MIT workspace license or inheritance');
    require(!/^license-file\s*=/m.test(fields), 'unexpected license-file override');
  });
  const node = files.filter(path => /(^|\/)package.json$/.test(path) && !path.includes('/vendor/'));
  const manifests = files.filter(path => /^(?:shell\/providers|packaging\/builtin|packages\/plugins)\/[^/]+\/manifest.json$/.test(path)
    || /^packages\/host-sdk\/(?:examples|templates)\/[^/]+\/manifest.json$/.test(path));
  group('first-party JSON metadata', [...node, ...manifests], (_path, text) => {
    require(JSON.parse(text).license === 'MIT', 'expected license: MIT');
  });
  const fixture = 'tests/licensing/pre-mit-builtin-manifests.json';
  try {
    const { packages } = JSON.parse(read(fixture).toString());
    require(Array.isArray(packages) && packages.length > 0, 'expected immutable manifest baselines');
    const previous = new Map();
    for (const item of packages) {
      require(/^(?:shell\/providers|packaging\/builtin)\/[^/]+\/manifest.json$/.test(item.path)
        && typeof item.id === 'string' && typeof item.version === 'string'
        && /^[a-f0-9]{64}$/.test(item.sha256) && !previous.has(item.path), 'invalid or duplicate baseline');
      previous.set(item.path, item);
    }
    group('immutable builtin manifests', [...previous.keys()], (path, text) => {
      const error = immutableManifestError(previous.get(path), text);
      require(!error, error);
    });
  } catch (error) {
    results.push({ name: 'immutable builtin manifests', cases: 1, errors: [`${fixture}: ${error.message}`] });
  }
  group('generated user default', ['crates/ditto-protocol/src/generation.rs'], (_path, text) => {
    const bundle = text.slice(text.indexOf('pub fn bundle('));
    require(/"author"\s*:\s*"Ditto user"\s*,\s*"license"\s*:\s*"UNLICENSED"/.test(bundle),
      'generated user artifacts must keep UNLICENSED');
  });
  const vendorNotices = files.filter(path => path.includes('/vendor/')
    && /^(?:licen[cs]e|notice)(?:\..*)?$/i.test(path.split('/').at(-1)));
  group('vendor LICENSE/NOTICE hashes', [...new Set([...vendorNotices, ...Object.keys(vendorHashes)])], (path, text) => {
    require(Object.hasOwn(vendorHashes, path), 'new vendor notice needs an explicit upstream audit and hash');
    require(sha256(text) === vendorHashes[path], 'vendor notice differs from pre-MIT baseline');
  });
  group('active licensing docs', activeDocs, (_path, text) => {
    require(activeDocAgrees(text), 'active docs must state MIT and remove own-code licensing undecided claims');
  });
  return results;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const results = checkLicense();
  for (const { name, cases, errors } of results) {
    console.log(`${errors.length ? 'FAIL' : 'PASS'} ${name}: ${cases} cases, ${errors.length} failures`);
    for (const error of errors) console.error(`  ${error}`);
  }
  const failures = results.reduce((sum, result) => sum + result.errors.length, 0);
  console.log(`${results.length} groups, ${results.reduce((sum, result) => sum + result.cases, 0)} cases, ${failures} failures`);
  process.exitCode = failures ? 1 : 0;
}
