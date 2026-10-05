#!/usr/bin/env node
// Shell i18n lint (EX1-13 ④) and catalogue tool.
//
//   node scripts/lint-shell-i18n.mjs            lint (CI): exit 1 on any problem
//   node scripts/lint-shell-i18n.mjs --update   add new qsTr sources to both .ts
//                                               catalogues (English left unfinished),
//                                               drop sources no QML uses any more
//   node scripts/lint-shell-i18n.mjs --write    regenerate the runtime JSON
//                                               catalogues from the .ts files
//   node scripts/lint-shell-i18n.mjs --scan-core  also list translation-key-like
//                                               literals in crates/ that have no
//                                               translation (informational)
//
// Rules checked by the lint:
//   1. No string literal in shell/**/*.qml contains CJK characters unless it
//      is the first argument of qsTr() or QT_TR_NOOP().
//   2. Every qsTr()/QT_TR_NOOP() source exists in shell/i18n/ditto_zh_TW.ts and
//      shell/i18n/ditto_en.ts, and the English translation is finished.
//   3. Every translation key Core emits (the DittoKeys context: preflight codes
//      read from crates/ditto-protocol/src/change.rs plus REQUIRED_KEYS below)
//      is translated in both catalogues.
//   4. shell/i18n/ditto_*.json are up to date with the .ts files. Quickshell
//      0.3.1 installs no QTranslator, so the Shell reads these JSON catalogues
//      at runtime (shell/core/Tr.qml); the .ts files stay the source of truth
//      and remain lupdate/lrelease compatible (contexts are QML file names).
import { readFileSync, writeFileSync, readdirSync, statSync, lstatSync, existsSync } from 'node:fs';
import { join, relative, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const shellDir = join(root, 'shell');
const i18nDir = join(shellDir, 'i18n');
const KEYS_CONTEXT = 'DittoKeys';
const LANGUAGES = [
  { file: 'ditto_zh_TW', ts: 'zh_TW', runtime: 'zh-TW' },
  { file: 'ditto_en', ts: 'en', runtime: 'en' },
];

// Keys Core (and the Shell's own key-based lookups) produce besides the
// preflight codes. Keep in step with crates/ditto-core (see --scan-core).
const REQUIRED_KEYS = [
  // change-card titles and kinds (docops::card)
  ...['profile_switch', 'provider_swap', 'appearance', 'layout', 'plugin_state', 'mixed'].map((kind) => `change.title.${kind}`),
  ...['profile_switch', 'provider_swap', 'appearance', 'layout', 'plugin_state', 'mixed', 'diff'].map((kind) => `card.kind.${kind}`),
  'change.appearance',
  // failure keys (coordinator)
  'change.candidate_not_ready', 'change.commit_failed', 'change.commit_write_failed', 'change.participant_unavailable',
  'change.prepare_failed', 'change.readback_mismatch', 'change.storage_error', 'change.storage_full',
  'change.timed_revert_failed',
  'recovery.interrupted', 'recovery.head_moved', 'recovery.no_base', 'recovery.no_target', 'recovery.participant_remembers',
  'recovery.participant_unavailable', 'recovery.read_failed', 'recovery.state_failed', 'recovery.transition_failed',
  'recovery.decided',
  // participant outcome reasons
  'participant.unavailable', 'participant.disconnected', 'participant.timeout', 'participant.refused',
  // outcome item reasons that are codes, not diagnostic text
  'reason.next_login', 'reason.rescue_mode', 'reason.host_not_running', 'reason.dependency_not_ready',
  'reason.window_closed',
  // why an entry runs (plugins.list started_reason)
  'started.profile',
  // diff labels (docops::diff)
  'diff.slot.changed', 'diff.entry.added', 'diff.entry.removed', 'diff.entry.config', 'diff.entry.disabled',
  'diff.entry.enabled', 'diff.entry.version', 'diff.area.joined', 'diff.area.left', 'diff.shortcuts', 'diff.appearance.token',
  ...['theme', 'locale', 'reduced_motion', 'reduced_transparency', 'low_power_style'].map((field) => `diff.appearance.${field}`),
  ...['enabled', 'hidden', 'scale', 'animations', 'output', 'corner'].map((field) => `diff.avatar.${field}`),
  'diff.layout.workspace_grid', 'diff.layout.rules',
  // import problems (exports::problem)
  ...['schema_invalid', 'format_unsupported', 'protocol_incompatible', 'digest_mismatch', 'package_missing',
    'integrity_mismatch', 'grant_required', 'secret_detected', 'private_path_detected'].map((kind) => `import.${kind}`),
  // install jobs
  'install.integrity_mismatch', 'install.invalid_package', 'install.storage_full', 'install.failed', 'job.interrupted',
  // trust notes, diagnostics, layout strategies, commands
  'trust.core_builtin', 'trust.same_host_no_isolation.cordis', 'trust.same_host_no_isolation.qml',
  'diagnostics.shared_host_no_per_plugin_memory',
  'layout.strategy.floating', 'layout.strategy.simple-tile',
  'command.composition.open', 'command.history.open', 'command.launcher.toggle', 'command.personalization.open',
  'command.plugins.open', 'command.rescue.open', 'command.session.lock',
  'shortcut.command_failed',
  // slot names (Tr.slotName)
  ...['ui.panel_top', 'ui.dock', 'ui.launcher', 'ui.tasks_panel', 'ui.notifications', 'layout.strategy', 'svc.tasks',
    'svc.notification_policy', 'ui.status_item'].map((slot) => `slot.${slot}`),
  // error names and reasons (DittoClient.errorText)
  ...['unsupported', 'invalid_params', 'not_found', 'permission_denied', 'timeout', 'cancelled', 'conflict', 'unavailable',
    'protocol_version_unsupported', 'identity_rejected', 'preflight_rejected', 'internal'].map((name) => `error.${name}`),
  ...['base_revision_stale', 'candidate_cannot_claim', 'single_provider_taken', 'undo_blocked_by_newer_change',
    'profile_in_use', 'change_in_progress', 'readback_mismatch'].map((reason) => `conflict.${reason}`),
  ...['compositor_offline', 'host_unavailable', 'host_crash_loop', 'lease_expired', 'not_bound', 'rescue_mode', 'recovering',
    'system_unavailable', 'participant_unavailable', 'session_locked', 'storage_full', 'storage_error'].map((reason) => `unavailable.${reason}`),
  ...['not_granted', 'policy_denied', 'approval_unavailable'].map((reason) => `permission_denied.${reason}`),
  // fallbacks for keys this catalogue does not know yet (Tr.key)
  ...['preflight', 'diff', 'change', 'import', 'install', 'job', 'recovery', 'participant', 'command', 'layout', 'trust'].map((prefix) => `generic.${prefix}`),
  // application categories (launcher grid)
  ...['AudioVideo', 'Development', 'Education', 'Game', 'Graphics', 'Network', 'Office', 'Science', 'Settings', 'System',
    'Utility'].map((category) => `category.${category}`),
];

const args = new Set(process.argv.slice(2));
const problems = [];

// ---- QML scanning ---------------------------------------------------------------
function qmlFiles(directory) {
  const found = [];
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    const stat = lstatSync(path);
    // lock/ and rescue/ link the shared directories in; scan each file once.
    if (stat.isSymbolicLink()) {
      continue;
    }
    if (stat.isDirectory()) {
      found.push(...qmlFiles(path));
    } else if (name.endsWith('.qml')) {
      found.push(path);
    }
  }
  return found.sort();
}

const CJK = /[⺀-⿟　-〿぀-ヿ㄀-ㄯ㆐-ㇿ㐀-䶿一-鿿가-힯豈-﫿︰-﹏＀-￯]/;

function unescape(body) {
  return body.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)/g, (match, code) => {
    if (code[0] === 'u') {
      return String.fromCodePoint(parseInt(code[1] === '{' ? code.slice(2, -1) : code.slice(1), 16));
    }
    if (code[0] === 'x') {
      return String.fromCharCode(parseInt(code.slice(1), 16));
    }
    return { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', v: '\v', 0: '\0' }[code] ?? code;
  });
}

/// String literals of a QML/JS source, with their position; comments skipped.
function literals(source) {
  const found = [];
  let index = 0;
  let line = 1;
  while (index < source.length) {
    const char = source[index];
    const next = source[index + 1];
    if (char === '\n') {
      line += 1;
      index += 1;
    } else if (char === '/' && next === '/') {
      while (index < source.length && source[index] !== '\n') index += 1;
    } else if (char === '/' && next === '*') {
      index += 2;
      while (index < source.length && !(source[index] === '*' && source[index + 1] === '/')) {
        if (source[index] === '\n') line += 1;
        index += 1;
      }
      index += 2;
    } else if (char === '"' || char === "'" || char === '`') {
      const start = index;
      const startLine = line;
      index += 1;
      let body = '';
      while (index < source.length && source[index] !== char) {
        if (source[index] === '\\') {
          body += source[index] + source[index + 1];
          index += 2;
          continue;
        }
        if (source[index] === '\n') line += 1;
        body += source[index];
        index += 1;
      }
      index += 1;
      found.push({ value: unescape(body), start, line: startLine, raw: body, quote: char });
    } else {
      index += 1;
    }
  }
  return found;
}

function translatedCall(source, start) {
  let cursor = start - 1;
  while (cursor >= 0 && /\s/.test(source[cursor])) cursor -= 1;
  if (source[cursor] !== '(') return null;
  cursor -= 1;
  while (cursor >= 0 && /\s/.test(source[cursor])) cursor -= 1;
  const end = cursor + 1;
  while (cursor >= 0 && /[A-Za-z0-9_]/.test(source[cursor])) cursor -= 1;
  const name = source.slice(cursor + 1, end);
  return name === 'qsTr' || name === 'QT_TR_NOOP' ? name : null;
}

const sources = new Map(); // context → Map(source → [locations])
for (const file of qmlFiles(shellDir)) {
  const text = readFileSync(file, 'utf8');
  const context = basename(file, '.qml');
  for (const literal of literals(text)) {
    const call = translatedCall(text, literal.start);
    if (call) {
      if (literal.quote === '`') {
        problems.push(`${relative(root, file)}:${literal.line}: ${call}() with a template literal is not extractable`);
        continue;
      }
      if (!sources.has(context)) sources.set(context, new Map());
      const messages = sources.get(context);
      if (!messages.has(literal.value)) messages.set(literal.value, []);
      messages.get(literal.value).push(`${relative(root, file)}:${literal.line}`);
    } else if (CJK.test(literal.value)) {
      problems.push(`${relative(root, file)}:${literal.line}: CJK text outside qsTr(): ${JSON.stringify(literal.value)}`);
    }
  }
}

// ---- preflight keys from the protocol crate --------------------------------------------
function preflightKeys() {
  const path = join(root, 'crates/ditto-protocol/src/change.rs');
  if (!existsSync(path)) return [];
  const text = readFileSync(path, 'utf8');
  const match = text.match(/pub enum PreflightCode\s*\{([\s\S]*?)\n\}/);
  if (!match) {
    problems.push('crates/ditto-protocol/src/change.rs: PreflightCode not found');
    return [];
  }
  return match[1]
    .split('\n')
    .map((row) => row.trim())
    .filter((row) => /^[A-Z][A-Za-z]*,?$/.test(row))
    .map((row) => row.replace(',', ''))
    .map((name) => `preflight.${name.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase()}`);
}
const requiredKeys = [...new Set([...preflightKeys(), ...REQUIRED_KEYS])].sort();

// ---- .ts catalogues ------------------------------------------------------------------------
function xmlEscape(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function xmlUnescape(text) {
  return text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
}

function readTs(path) {
  const catalogue = new Map(); // context → Map(source → { translation, finished })
  if (!existsSync(path)) return catalogue;
  const text = readFileSync(path, 'utf8');
  for (const context of text.matchAll(/<context>\s*<name>([\s\S]*?)<\/name>([\s\S]*?)<\/context>/g)) {
    const messages = new Map();
    for (const message of context[2].matchAll(/<message>([\s\S]*?)<\/message>/g)) {
      const source = message[1].match(/<source>([\s\S]*?)<\/source>/);
      const translation = message[1].match(/<translation( type="(unfinished|vanished|obsolete)")?>([\s\S]*?)<\/translation>|<translation type="unfinished"\/>/);
      if (!source) continue;
      messages.set(xmlUnescape(source[1]), {
        translation: translation && translation[3] !== undefined ? xmlUnescape(translation[3]) : '',
        finished: !!translation && translation[0] !== '<translation type="unfinished"/>' && !translation[1],
      });
    }
    catalogue.set(xmlUnescape(context[1]), messages);
  }
  return catalogue;
}

function writeTs(path, language, catalogue) {
  const lines = ['<?xml version="1.0" encoding="utf-8"?>', '<!DOCTYPE TS>', `<TS version="2.1" language="${language}" sourcelanguage="zh_TW">`];
  for (const context of [...catalogue.keys()].sort()) {
    lines.push('<context>', `    <name>${xmlEscape(context)}</name>`);
    for (const [source, entry] of [...catalogue.get(context).entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
      lines.push('    <message>', `        <source>${xmlEscape(source)}</source>`);
      lines.push(entry.finished
        ? `        <translation>${xmlEscape(entry.translation)}</translation>`
        : `        <translation type="unfinished">${xmlEscape(entry.translation)}</translation>`);
      lines.push('    </message>');
    }
    lines.push('</context>');
  }
  lines.push('</TS>', '');
  writeFileSync(path, lines.join('\n'));
}

function lookup(catalogue, source) {
  for (const messages of catalogue.values()) {
    const entry = messages.get(source);
    if (entry && entry.finished && entry.translation !== '') return entry;
  }
  return null;
}

if (args.has('--update')) {
  for (const language of LANGUAGES) {
    const path = join(i18nDir, `${language.file}.ts`);
    const old = readTs(path);
    const next = new Map();
    for (const [context, messages] of sources) {
      const out = new Map();
      for (const source of messages.keys()) {
        const previous = old.get(context)?.get(source) || lookup(old, source);
        if (previous) {
          out.set(source, previous);
        } else if (language.ts === 'zh_TW') {
          out.set(source, { translation: source, finished: true });
        } else {
          out.set(source, { translation: '', finished: false });
        }
      }
      next.set(context, out);
    }
    const keys = new Map(old.get(KEYS_CONTEXT) || []);
    for (const key of requiredKeys) {
      if (!keys.has(key)) keys.set(key, { translation: '', finished: false });
    }
    next.set(KEYS_CONTEXT, keys);
    writeTs(path, language.ts, next);
    console.log(`updated ${relative(root, path)}`);
  }
}

// ---- runtime JSON ------------------------------------------------------------------------------
function runtimeJson(language, catalogue) {
  const strings = {};
  const keys = {};
  for (const [context, messages] of catalogue) {
    for (const [source, entry] of messages) {
      if (!entry.finished || entry.translation === '') continue;
      if (context === KEYS_CONTEXT) {
        keys[source] = entry.translation;
      } else if (entry.translation !== source) {
        strings[source] = entry.translation;
      }
    }
  }
  const sorted = (object) => Object.fromEntries(Object.keys(object).sort().map((key) => [key, object[key]]));
  return `${JSON.stringify({ language: language.runtime, generated_from: `${language.file}.ts`, strings: sorted(strings), keys: sorted(keys) }, null, 1)}\n`;
}

for (const language of LANGUAGES) {
  const tsPath = join(i18nDir, `${language.file}.ts`);
  const jsonPath = join(i18nDir, `${language.file}.json`);
  const catalogue = readTs(tsPath);
  if (catalogue.size === 0) {
    problems.push(`${relative(root, tsPath)}: missing or empty`);
    continue;
  }
  const json = runtimeJson(language, catalogue);
  if (args.has('--write')) {
    writeFileSync(jsonPath, json);
    console.log(`wrote ${relative(root, jsonPath)}`);
  } else if (!existsSync(jsonPath) || readFileSync(jsonPath, 'utf8') !== json) {
    problems.push(`${relative(root, jsonPath)}: out of date with ${language.file}.ts (run with --write)`);
  }
  for (const [context, messages] of sources) {
    for (const [source, locations] of messages) {
      const entry = catalogue.get(context)?.get(source);
      if (!entry) {
        problems.push(`${locations[0]}: ${JSON.stringify(source)} is not in ${language.file}.ts (run with --update)`);
      } else if (!entry.finished || entry.translation === '') {
        problems.push(`${locations[0]}: ${JSON.stringify(source)} has no finished ${language.ts} translation`);
      }
    }
  }
  const keys = catalogue.get(KEYS_CONTEXT) || new Map();
  for (const key of requiredKeys) {
    const entry = keys.get(key);
    if (!entry || !entry.finished || entry.translation === '') {
      problems.push(`${language.file}.ts: translation key ${key} is not translated`);
    }
  }
}

// ---- .qm (lrelease) -------------------------------------------------------------------------
// Quickshell 0.3.1 loads no QTranslator, so the .qm files are not read at
// runtime; they are produced for Qt tooling and a later translator. When
// lrelease is available (LRELEASE, PATH, or $QT_PREFIX/bin) they are checked
// like the JSON; otherwise the check is skipped and says so.
function findLrelease() {
  const candidates = [process.env.LRELEASE, process.env.QT_PREFIX && join(process.env.QT_PREFIX, 'bin/lrelease'),
    ...(process.env.PATH || '').split(':').map((dir) => join(dir, 'lrelease')),
    process.env.HOME && join(process.env.HOME, 'Qt/6.10.2/gcc_64/bin/lrelease')].filter(Boolean);
  return candidates.find((path) => existsSync(path)) || null;
}
const lrelease = findLrelease();
if (lrelease) {
  const { execFileSync } = await import('node:child_process');
  const { mkdtempSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const scratch = mkdtempSync(join(tmpdir(), 'ditto-qm-'));
  for (const language of LANGUAGES) {
    const tsPath = join(i18nDir, `${language.file}.ts`);
    const qmPath = join(i18nDir, `${language.file}.qm`);
    const built = join(scratch, `${language.file}.qm`);
    execFileSync(lrelease, ['-silent', tsPath, '-qm', built]);
    if (args.has('--write')) {
      writeFileSync(qmPath, readFileSync(built));
      console.log(`wrote ${relative(root, qmPath)}`);
    } else if (!existsSync(qmPath) || Buffer.compare(readFileSync(qmPath), readFileSync(built)) !== 0) {
      problems.push(`${relative(root, qmPath)}: out of date with ${language.file}.ts (run with --write)`);
    }
  }
  rmSync(scratch, { recursive: true, force: true });
} else {
  console.log('lrelease not found: .qm files not checked');
}

if (args.has('--scan-core')) {
  const pattern = /"((?:preflight|diff|change|import|trust|diagnostics|layout|command|recovery|install|job|participant|shortcut)\.[a-z_.-]+)"/g;
  const found = new Set();
  const walk = (directory) => {
    for (const name of readdirSync(directory)) {
      const path = join(directory, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (name.endsWith('.rs')) for (const match of readFileSync(path, 'utf8').matchAll(pattern)) found.add(match[1]);
    }
  };
  for (const crate of ['crates/ditto-core/src', 'crates/ditto-protocol/src', 'crates/ditto-store/src']) {
    if (existsSync(join(root, crate))) walk(join(root, crate));
  }
  const known = new Set(requiredKeys);
  const unknown = [...found].filter((key) => !known.has(key) && !key.endsWith('.')).sort();
  console.log(`--scan-core: ${found.size} key-like literals in crates/, ${unknown.length} without a required translation`);
  for (const key of unknown) console.log(`  ${key}`);
}

const count = [...sources.values()].reduce((total, messages) => total + messages.size, 0);
if (problems.length > 0) {
  for (const problem of problems) console.error(problem);
  console.error(`shell i18n: ${problems.length} problem(s); ${count} translatable strings, ${requiredKeys.length} keys`);
  process.exit(1);
}
console.log(`shell i18n: ok (${count} translatable strings in ${sources.size} files, ${requiredKeys.length} Core keys, 2 languages)`);
