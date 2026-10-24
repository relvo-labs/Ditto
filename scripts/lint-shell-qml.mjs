// qmllint cannot use Quickshell's root: URL interceptor. Lint a temporary
// source tree with SDK directory imports mapped to the real Shell qmldir.
import { spawn } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const qt = process.argv[2] || process.env.QT_PREFIX;
if (!qt) throw new Error('QT_PREFIX or a Qt prefix argument is required');

async function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    // Fail-safe against hung tools, with headroom for slower CI runners.
    const child = spawn(command, args, { cwd, timeout: 120_000 });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (status, signal) => {
      if (signal) reject(new Error(`${command} terminated by ${signal}`));
      else resolve({ status, stdout, stderr });
    });
  });
}

// Keep the workflow's exclusions and unlimited warnings for other Shell files.
const found = await run('find', [
  'shell', '-name', '*.qml',
  '-not', '-path', '*/tests/fixtures/dock_broken_syntax/*',
  '-not', '-path', 'shell/lock/core/*',
  '-not', '-path', 'shell/rescue/*/*', '-print0',
], root);
if (found.status !== 0) throw new Error(found.stderr);
const files = found.stdout.split('\0').filter(Boolean);
const budgets = new Map([
  ['shell/centers/HistoryCenter.qml', 0],
  ['shell/chat/ChatBody.qml', 0],
  ['shell/providers/settings_history/qml/HistoryPage.qml', 0],
]);
const stage = mkdtempSync(join(tmpdir(), 'ditto-qmllint-'));
try {
  // Include relative dependencies and the SDK's original qmldir, without
  // copying assets or generating another set of SDK type declarations.
  cpSync(join(root, 'shell'), join(stage, 'shell'), {
    recursive: true,
    verbatimSymlinks: true,
    filter: source => statSync(source).isDirectory()
      || /(?:\.(qml|js|mjs|qmltypes)|\/qmldir)$/.test(source),
  });
  for (const file of files) {
    const path = join(stage, file);
    const source = readFileSync(path, 'utf8');
    const mapped = source.replace(/^(\s*import\s+)(["'])root:\/sdk\/([^"'\r\n]+)\2/gm,
      (_, prefix, quote, sdkPath) => {
        const target = resolve(stage, 'shell/sdk', sdkPath);
        if (!target.startsWith(join(stage, 'shell/sdk/'))) throw new Error(`Invalid SDK import: ${sdkPath}`);
        return `${prefix}${quote}${pathToFileURL(target).href}${quote}`;
      });
    if (mapped !== source) writeFileSync(path, mapped);
  }
  const report = join(stage, 'report.json');
  const lint = await run(join(qt, 'bin/qmllint'), [
    '-I', join(qt, 'qml'), '--max-warnings', '-1', '--json', report, ...files,
  ], stage);
  const display = text => (text || '')
    .replaceAll(pathToFileURL(`${stage}/`).href, '')
    .replaceAll(`${stage}/`, '').replaceAll(stage, '.');
  process.stdout.write(display(lint.stdout));
  process.stderr.write(display(lint.stderr));
  process.exitCode = lint.status ?? 1;
  const results = JSON.parse(readFileSync(report, 'utf8')).files;
  let total = 0;
  const seen = new Set();
  for (const result of results) {
    const file = relative(stage, result.filename);
    for (const diagnostic of result.warnings) {
      console.log(`${diagnostic.type}: ${file}:${diagnostic.line}:${diagnostic.column}: ${display(diagnostic.message)} [${diagnostic.id}]`);
    }
    const warnings = result.warnings.filter(warning => warning.type === 'warning');
    total += warnings.length;
    if (!budgets.has(file)) continue;
    seen.add(file);
    const categories = {};
    for (const warning of warnings) categories[warning.id] = (categories[warning.id] || 0) + 1;
    console.log(`${file}: ${warnings.length} warnings (budget ${budgets.get(file)}); ${JSON.stringify(categories)}`);
    if (warnings.length > budgets.get(file)) process.exitCode = 1;
  }
  for (const file of budgets.keys()) {
    if (!seen.has(file)) throw new Error(`Missing qmllint result: ${file}`);
  }
  console.log(`shell/: ${total} warnings`);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
