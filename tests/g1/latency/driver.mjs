#!/usr/bin/env node
// The observer side of tests/g1/latency (EX1-11), launched by Core as a CLI
// client. Times are Core's, never the driver's:
//   - a ChangeSet's state transitions are announced as change_updated events
//     whose `updated_at` Core stamped when it wrote that state, so
//     prepared→committed is read from those stamps;
//   - a ChangeSet's acceptance is its `created_at` and its readback the
//     `ended_at` Core wrote for its readback operations;
//   - a compositor write (workspace, focus) is one call that Core reads back
//     before answering; `_meta.handled_us` is Core's monotonic time from
//     reading the request to the verified result.
// The driver's own round trip is recorded beside each sample for reference
// and never judged.
//
//   node driver.mjs <work> service-toggle <count>
//   node driver.mjs <work> session <local-count> <dock-count>
//     waits for <work>/go (run.sh has the reference applications up), then
//     ① <local-count> simple local operations, ② <dock-count> Dock A↔B
//     switches. Writes <work>/samples.jsonl (one line per operation) and
//     <work>/done.json.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { connect, sleep } from '../lib/core-client.mjs';

const pillVersion = JSON.parse(readFileSync(new URL('../../../shell/providers/dock_pill/manifest.json', import.meta.url), 'utf8')).version;
const [work, kind, countText = '100', dockText = '100'] = process.argv.slice(2);
const count = Number(countText);
const { call, must, events, available } = await connect();
const record = sample => appendFileSync(join(work, 'samples.jsonl'), JSON.stringify(sample) + '\n');

const stamps = changeId => {
  const byState = {};
  for (const event of events) {
    const payload = event.params?.payload;
    if (payload?.type === 'change_updated' && payload.change?.change_id === changeId) {
      byState[payload.change.state] ??= payload.change.updated_at;
    }
  }
  return byState;
};

// A subscription Core ended with resync_required (a compositor reconnect,
// say) is taken out again before the next change, and the number of times is
// recorded: a change in flight meanwhile has no stamps and is not judged as
// measured.
let subscribedAt = 0;
let resubscribed = 0;
async function subscribeChanges() {
  await must('desktop.events.subscribe', { topics: ['changes'] });
  subscribedAt = events.length;
}
async function ensureSubscribed() {
  if (events.slice(subscribedAt).some(event => event.params?.payload?.type === 'resync_required')) {
    resubscribed += 1;
    await subscribeChanges();
  }
}

// Wait until the change's final state has been announced, then its stamps.
const settled = async (change, limitMs = 5_000) => {
  let byState = stamps(change.change_id);
  const until = Date.now() + limitMs;
  while (!byState[change.state] && Date.now() < until) { await sleep(10); byState = stamps(change.change_id); }
  return byState;
};
const between = (byState, from, to) => (byState[from] && byState[to]) ? Date.parse(byState[to]) - Date.parse(byState[from]) : null;

// ① A compositor write read back by Core before it answers.
async function compositorWrite(kind, method, params, warmup) {
  const started = performance.now();
  const response = await call(method, params);
  const roundTrip = performance.now() - started;
  const meta = response.result?._meta ?? {};
  const ok = !response.error && meta.readback_verified === true;
  record({
    kind, warmup, ok, method, params,
    error: response.error ? `${response.error.name}: ${response.error.message}` : undefined,
    readback_verified: meta.readback_verified ?? false,
    accepted_to_readback_ms: typeof meta.handled_us === 'number' ? meta.handled_us / 1000 : null,
    measure: 'core_handled_us',
    client_round_trip_ms: Math.round(roundTrip * 1000) / 1000,
  });
  return ok;
}

// ① One appearance token, a ChangeSet: accepted (created_at) → the end of its
// last readback operation, both written by Core.
async function appearanceToken(value, warmup) {
  await ensureSubscribed();
  const head = await must('desktop.profiles.get', {});
  const started = performance.now();
  const response = await call('desktop.appearance.set', { base_revision: head.profile.head_revision, tokens: { accent: value } });
  const roundTrip = performance.now() - started;
  const change = response.result;
  const readbacks = (change?.operations ?? []).filter(operation => operation.step === 'readback' && operation.ended_at);
  const lastReadback = readbacks.map(operation => Date.parse(operation.ended_at)).sort((a, b) => a - b).at(-1);
  const ok = !response.error && change?.state === 'committed' && lastReadback !== undefined;
  record({
    kind: 'appearance_token', warmup, ok, value,
    error: response.error ? `${response.error.name}: ${response.error.message}` : undefined,
    change_id: change?.change_id, state: change?.state,
    created_at: change?.created_at, readback_ended_at: lastReadback !== undefined ? new Date(lastReadback).toISOString() : null,
    accepted_to_readback_ms: ok ? lastReadback - Date.parse(change.created_at) : null,
    measure: 'change_created_at_to_readback_ended_at',
    core_handled_ms: typeof change?._meta?.handled_us === 'number' ? change._meta.handled_us / 1000 : null,
    client_round_trip_ms: Math.round(roundTrip * 1000) / 1000,
  });
  return ok;
}

// ② One Dock switch: prepared → committed from Core's change_updated stamps.
// Afterwards (outside the measured span) the Shell's report, as Core serves
// it, must show the new entry mounted and visible in ui.dock.
async function dockSwitch(ops, to, warmup) {
  await ensureSubscribed();
  const head = await must('desktop.profiles.get', {});
  const change = await must('desktop.changes.propose', { base_revision: head.profile.head_revision, ops });
  const byState = await settled(change);
  const bound = (await must('desktop.profiles.get', {})).document.slots['ui.dock'];
  const dock = (await must('desktop.panels.list', {})).panels.find(panel => panel.slot === 'ui.dock');
  const mounted = dock?.mounted_entry === bound && dock?.visible === true && dock?.package === `ditto.dock.${to}`;
  record({
    kind: 'dock_switch', warmup, ok: change.state === 'committed' && mounted, to, op: ops[0].op, change_id: change.change_id, state: change.state,
    failure_key: change.failure_key ?? undefined, shell_mounts: dock?.package ?? null, shell_visible: dock?.visible ?? false,
    prepared_to_committed_ms: between(byState, 'prepared', 'committed'), measure: 'change_updated_prepared_to_committed', stamps: byState,
  });
  return change.state === 'committed';
}

async function session(localCount, dockCount) {
  const goBy = Date.now() + 120_000;
  while (!existsSync(join(work, 'go'))) {
    if (Date.now() > goBy) throw new Error('run.sh never said go');
    await sleep(100);
  }
  await subscribeChanges();
  // ① Two workspaces, the reference windows, two accent values. The measure
  // is for the warm state: each kind starts with five warm-up operations,
  // kept in samples.jsonl with `warmup: true` and left out of the p95.
  const workspaces = (await must('desktop.workspaces.list', {})).workspaces;
  const home = workspaces.find(workspace => workspace.active);
  const other = workspaces.find(workspace => !workspace.active);
  if (!home || !other) throw new Error('need an active and one other workspace');
  const windows = (await must('desktop.windows.list', {})).windows
    .filter(window => ['ditto-ref-terminal', 'org.kde.kate', 'firefox_firefox'].includes(window.app_id));
  if (windows.length < 2) throw new Error(`need two reference windows, found ${windows.map(window => window.app_id)}`);
  const perKind = Math.floor(localCount / 3);
  const counts = { workspace: perKind % 2 === 0 ? perKind : perKind - 1 };
  counts.focus = Math.ceil((localCount - counts.workspace) / 2);
  counts.token = localCount - counts.workspace - counts.focus;
  const warm = 5;
  // Workspace switches come in pairs so focus runs on the home workspace.
  for (let i = 0; i < counts.workspace + warm * 2; i++) {
    const target = i % 2 === 0 ? other : home;
    await compositorWrite('workspace_switch', 'desktop.workspaces.activate', { workspace_id: target.id }, i < warm * 2);
  }
  for (let i = 0; i < counts.focus + warm; i++) {
    const target = windows[i % windows.length];
    await compositorWrite('window_focus', 'desktop.windows.focus', { window_id: target.id }, i < warm);
  }
  for (let i = 0; i < counts.token + warm; i++) {
    await appearanceToken(i % 2 === 0 ? '#a4c8ff' : '#b9a4ff', i < warm);
  }
  // ② The pill Dock enters the composition once (add_entry, not counted),
  // then the two installed entries are re-bound alternately, as the
  // composition center does for an entry already in the composition.
  let profile = await must('desktop.profiles.get', {});
  const bottom = profile.document.slots['ui.dock'];
  const pill = await dockSwitch([{ op: 'add_entry', slot: 'ui.dock', entry: { package: 'ditto.dock.pill', version: pillVersion, host: 'qml', config: {}, disabled: false } }], 'pill', true);
  if (!pill) throw new Error('adding the pill Dock did not commit');
  profile = await must('desktop.profiles.get', {});
  const pillEntry = profile.document.slots['ui.dock'];
  let current = pillEntry;
  for (let i = 0; i < dockCount; i++) {
    const to = current === pillEntry ? bottom : pillEntry;
    if (await dockSwitch([{ op: 'bind_slot', slot: 'ui.dock', from: current, to }], to === pillEntry ? 'pill' : 'bottom', false)) current = to;
  }
}

try {
  if (kind === 'session') {
    await session(count, Number(dockText));
    writeFileSync(join(work, 'done.json'), JSON.stringify({ ok: true, resubscribed }));
    process.exit(0);
  }
  if (kind !== 'service-toggle') throw new Error(`unknown kind ${kind}`);
  const deadline = Date.now() + 30_000;
  while (!(await available('desktop.tasks.list'))) {
    if (Date.now() > deadline) throw new Error('desktop.tasks.list never became available (is hostd running?)');
    await sleep(200);
  }
  await must('desktop.events.subscribe', { topics: ['changes'] });
  const profile = await must('desktop.profiles.get', {});
  const entry = profile.document.slots['svc.tasks'];
  for (let i = 0; i < count * 2; i++) {
    const disabled = i % 2 === 0;
    const head = await must('desktop.profiles.get', {});
    const change = await must('desktop.changes.propose', {
      base_revision: head.profile.head_revision,
      ops: [{ op: 'set_entry_disabled', entry_id: entry, disabled }],
    });
    let byState = stamps(change.change_id);
    const until = Date.now() + 2_000;
    while (!byState[change.state] && Date.now() < until) { await sleep(10); byState = stamps(change.change_id); }
    const ms = (from, to) => (byState[from] && byState[to]) ? Date.parse(byState[to]) - Date.parse(byState[from]) : null;
    appendFileSync(join(work, 'samples.jsonl'), JSON.stringify({
      kind: 'cordis_service', action: disabled ? 'disable' : 'enable', change_id: change.change_id, state: change.state,
      prepared_to_committed_ms: ms('prepared', 'committed'), accepted_to_committed_ms: ms('validated', 'committed'), stamps: byState,
    }) + '\n');
  }
  writeFileSync(join(work, 'done.json'), JSON.stringify({ ok: true }));
} catch (error) {
  writeFileSync(join(work, 'done.json'), JSON.stringify({ ok: false, error: String(error?.message ?? error) }));
}
process.exit(0);
