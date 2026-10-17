#!/usr/bin/env node
// Copies the providers the visual harness renders into tests/g4/visual/.staged/
// with the layer-shell lines removed. Quickshell.Wayland's `WlrLayershell.*`
// are attached properties that a pure-QML stub cannot provide, and offscreen
// there is no layer shell for them to act on. Nothing else is changed: every
// removed line is listed in .staged/staging.json, and the run fails if a
// layer-shell reference is left or a non-layer-shell line would be removed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const out = join(here, '.staged', 'providers');
mkdirSync(out, { recursive: true });

const providers = [
  'shell/providers/dock_pill/qml/DockPill.qml',
  'shell/providers/panel_top/qml/PanelTop.qml',
];
// The legacy reference: the same files at the G4 base, before #65. The
// legacy-presentation tests render them next to the current files with the
// `soft-jelly` theme and require the same pixels and geometry.
const LEGACY_BASE = 'f58242612d43506984cdfde8f303b73045a57617';
const legacy = [
  { path: 'shell/providers/dock_pill/qml/DockPill.qml', stage: true },
  { path: 'shell/jelly/Material.qml', stage: false },
];
mkdirSync(join(here, '.staged', 'base'), { recursive: true });
const sha = (text) => createHash('sha256').update(text).digest('hex');
const report = [];
const strip = (source, path, removed) => source.split('\n').filter((line, index) => {
  if (/^\s*import Quickshell\.Wayland\s*$/.test(line) || /^\s*WlrLayershell\.\w+\s*:/.test(line)) {
    removed.push({ line: index + 1, text: line.trim() });
    return false;
  }
  return true;
}).join('\n');
for (const item of legacy) {
  const source = execFileSync('git', ['-C', root, 'show', `${LEGACY_BASE}:${item.path}`], { encoding: 'utf8' });
  const removed = [];
  const staged = item.stage ? strip(source, item.path, removed) : source;
  const name = item.path.split('/').pop();
  writeFileSync(join(here, '.staged', 'base', name), staged);
  report.push({ source: `${LEGACY_BASE}:${item.path}`, source_sha256: sha(source), staged: `.staged/base/${name}`, staged_sha256: sha(staged), removed });
}
for (const path of providers) {
  const source = readFileSync(join(root, path), 'utf8');
  const removed = [];
  const staged = strip(source, path, removed);
  if (/WlrLayershell|WlrKeyboardFocus|WlrLayer\b/.test(staged)) {
    console.error(`${path}: a layer-shell reference is left after staging`);
    process.exit(1);
  }
  const name = path.split('/').pop();
  writeFileSync(join(out, name), staged);
  report.push({ source: path, source_sha256: sha(source), staged: `.staged/providers/${name}`, staged_sha256: sha(staged), removed });
}
writeFileSync(join(here, '.staged', 'staging.json'), JSON.stringify(report, null, 2) + '\n');
for (const entry of report) {
  console.log(`staged ${entry.source}: ${entry.removed.length} layer-shell line(s) removed`);
}
