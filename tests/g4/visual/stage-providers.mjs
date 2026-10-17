#!/usr/bin/env node
// Copies the providers the visual harness renders into tests/g4/visual/.staged/
// with the layer-shell lines removed. Quickshell.Wayland's `WlrLayershell.*`
// are attached properties that a pure-QML stub cannot provide, and offscreen
// there is no layer shell for them to act on. Nothing else is changed: every
// removed line is listed in .staged/staging.json, and the run fails if a
// layer-shell reference is left or a non-layer-shell line would be removed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
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
const sha = (text) => createHash('sha256').update(text).digest('hex');
const report = [];
for (const path of providers) {
  const source = readFileSync(join(root, path), 'utf8');
  const removed = [];
  const kept = source.split('\n').filter((line, index) => {
    if (/^\s*import Quickshell\.Wayland\s*$/.test(line) || /^\s*WlrLayershell\.\w+\s*:/.test(line)) {
      removed.push({ line: index + 1, text: line.trim() });
      return false;
    }
    return true;
  });
  const staged = kept.join('\n');
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
