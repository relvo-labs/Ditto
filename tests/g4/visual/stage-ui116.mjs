#!/usr/bin/env node
// #116: stage the Shell's own application surfaces twice, so that
// unit/tst_ui_style_off.qml can render them side by side with no
// DITTO_UI_STYLE and require the same pixels:
//   .staged/ui116/base/shell/…     the files at BASE (87a2462, PR #115)
//   .staged/ui116/current/shell/…  the working tree
// Only layer-shell attached properties are removed (the pure-QML stubs cannot
// provide them) and `ExclusionMode.Ignore` becomes 0, the same adaptation as
// stage-assistant.py; every changed line is listed in .staged/ui116/staging.json.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const out = join(here, '.staged', 'ui116');
export const BASE = '87a2462a9c76f3f6ab1453eb7f14f9d6dfb35b45';
const dirs = ['shell/ui', 'shell/jelly', 'shell/centers', 'shell/chat', 'shell/change', 'shell/assistant', 'shell/avatar', 'shell/wallpapers'];
const files = ['shell/providers/dock_pill/qml/DockPill.qml'];
const sha = (text) => createHash('sha256').update(text).digest('hex');

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, 'base'), { recursive: true });
mkdirSync(join(out, 'current'), { recursive: true });

// Base tree: `git archive` of the pinned commit.
const archive = execFileSync('git', ['-C', root, 'archive', '--format=tar', BASE, ...dirs, ...files], { maxBuffer: 1 << 28 });
execFileSync('tar', ['-x', '-C', join(out, 'base')], { input: archive });
// Current tree: the working copy of the same paths.
for (const path of [...dirs, ...files]) {
  mkdirSync(dirname(join(out, 'current', path)), { recursive: true });
  cpSync(join(root, path), join(out, 'current', path), { recursive: true });
}

const report = [];
const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const path = join(dir, name);
  return statSync(path).isDirectory() ? walk(path) : [path];
});
for (const tree of ['base', 'current']) {
  for (const path of walk(join(out, tree)).filter((p) => p.endsWith('.qml'))) {
    const source = readFileSync(path, 'utf8');
    const removed = [];
    const staged = source.split('\n').flatMap((line, index) => {
      if (/^\s*import Quickshell\.Wayland\s*$/.test(line) || /^\s*WlrLayershell\.\w+\s*:/.test(line)) {
        removed.push({ line: index + 1, text: line.trim() });
        return [];
      }
      if (line.includes('ExclusionMode.Ignore')) {
        removed.push({ line: index + 1, text: line.trim(), replacement: 'ExclusionMode.Ignore -> 0 (stub enum)' });
        return [line.replace('ExclusionMode.Ignore', '0')];
      }
      return [line];
    }).join('\n');
    if (/WlrLayershell|WlrKeyboardFocus|WlrLayer\b/.test(staged)) {
      console.error(`${path}: a layer-shell reference is left after staging`);
      process.exit(1);
    }
    if (removed.length > 0) {
      writeFileSync(path, staged);
      report.push({ tree, file: relative(out, path), source_sha256: sha(source), staged_sha256: sha(staged), removed });
    }
  }
}
writeFileSync(join(out, 'staging.json'), JSON.stringify({ base: BASE, dirs, files, adaptations: report }, null, 2) + '\n');
console.log(`staged #116 base ${BASE.slice(0, 7)} and current trees; ${report.length} file(s) adapted (layer-shell only)`);
