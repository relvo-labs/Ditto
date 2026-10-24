import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

const qt = mkdtempSync(join(tmpdir(), 'ditto-qmllint-test-'));
const result = { stdout: '', stderr: '' };
const argv = process.argv;
const stdoutWrite = process.stdout.write;
const stderrWrite = process.stderr.write;
try {
  mkdirSync(join(qt, 'bin'));
  const mock = join(qt, 'bin/qmllint');
  writeFileSync(mock, `#!/bin/sh
while [ "$1" != "--json" ]; do shift; done
report="$2"
sdk="file://$PWD/shell/sdk/Shell"
printf 'staged-lock-core: %s\\n' "$(readlink shell/lock/core)"
printf 'staged-rescue-ui: %s\\n' "$(readlink shell/rescue/ui)"
printf 'stdout import: %s\\n' "$sdk"
printf 'stderr import: %s\\n' "$sdk" >&2
cat > "$report" <<EOF
{"files":[
  {"filename":"$PWD/shell/centers/HistoryCenter.qml","warnings":[
    {"type":"info","line":7,"column":9,"id":"import","message":"Import $sdk"}
  ]},
  {"filename":"$PWD/shell/chat/ChatBody.qml","warnings":[]},
  {"filename":"$PWD/shell/providers/settings_history/qml/HistoryPage.qml","warnings":[]}
]}
EOF
`);
  chmodSync(mock, 0o755);
  process.argv = [...argv.slice(0, 2), qt];
  process.stdout.write = chunk => { result.stdout += chunk; return true; };
  process.stderr.write = chunk => { result.stderr += chunk; return true; };
  await import('./lint-shell-qml.mjs');
} finally {
  process.argv = argv;
  process.stdout.write = stdoutWrite;
  process.stderr.write = stderrWrite;
  rmSync(qt, { recursive: true, force: true });
}

test('staging preserves relative symlink targets', () => {
  assert.match(result.stdout, /^staged-lock-core: \.\.\/core$/m);
  assert.match(result.stdout, /^staged-rescue-ui: \.\.\/ui$/m);
});

test('SDK diagnostic paths are checkout-relative and retain line and column', () => {
  assert.match(result.stdout, /^stdout import: shell\/sdk\/Shell$/m);
  assert.match(result.stderr, /^stderr import: shell\/sdk\/Shell$/m);
  assert.match(result.stdout,
    /^info: shell\/centers\/HistoryCenter.qml:7:9: Import shell\/sdk\/Shell \[import\]$/m);
  assert.doesNotMatch(result.stdout + result.stderr, /file:\/\/shell\//);
});
