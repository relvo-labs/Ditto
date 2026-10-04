#!/usr/bin/env node
// The observer side of tests/g1/cleanup-stress (EX1-04), launched by Core as a
// CLI client. It repeats one of the cycles, snapshotting
// desktop.plugins.diagnostics (Core's bindings, leases and subscriptions;
// hostd's fibers, effects, timers and registrations; the Shell's mounted
// providers; hostd's PSS) before the run and after every tenth cycle, and
// writes everything to <work>/result.json. run.sh judges it.
//
//   node driver.mjs <work> tasks-toggle|realm-cycle <cycles> <warmup>
//
// tasks-toggle (②): disable, then enable, the profile's svc.tasks entry.
// realm-cycle (③): propose adding the realm_cycle fixture with
// refuse_as_candidate. hostd mounts it as a candidate in an isolate realm
// (it provides a Cordis service, registers a capability, holds two timers),
// its candidate health check fails, and the change aborts: the realm is
// mounted and taken down again without the main realm being touched. hostd
// names each prepare's realm itself (ditto-candidate-<n>); the entry, package
// and config are the same every time.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { connect, sleep } from '../lib/core-client.mjs';

const [work, group, cyclesText = '100', warmupText = '10'] = process.argv.slice(2);
const cycles = Number(cyclesText);
const warmup = Number(warmupText);
const { must, available } = await connect();

function flatten(diagnostics) {
  const counts = { ...diagnostics.core };
  counts.hostd_fibers = diagnostics.entries.filter(entry => entry.fiber_state).length;
  for (const key of ['capabilities', 'leases', 'subscriptions', 'effects', 'timers']) {
    counts[`hostd_${key}`] = diagnostics.entries.reduce((sum, entry) => sum + (entry.registrations?.[key] ?? 0), 0);
  }
  return counts;
}

async function snapshot(cycle) {
  // Let deferred cleanup finish before counting, as a person looking would.
  await sleep(300);
  const diagnostics = await must('desktop.plugins.diagnostics', {});
  const hostdPid = diagnostics.host?.process?.pid ?? null;
  let hostdRollup = null;
  if (hostdPid) {
    try {
      hostdRollup = Object.fromEntries(readFileSync(`/proc/${hostdPid}/smaps_rollup`, 'utf8')
        .split('\n').flatMap(line => {
          const match = /^([A-Za-z_]+):\s+(\d+) kB$/.exec(line);
          return match ? [[match[1], Number(match[2])]] : [];
        }));
    } catch { /* the process may have exited; diagnostics keeps the PID */ }
  }
  return { cycle, at: new Date().toISOString(), counts: flatten(diagnostics), hostd_pss_kib: diagnostics.host?.process?.pss_kib ?? null, hostd_rollup_kib: hostdRollup, hostd_heap: diagnostics.host?.heap ?? null, hostd_pid: hostdPid };
}

async function setDisabled(entry, disabled) {
  const head = await must('desktop.profiles.get', {});
  const change = await must('desktop.changes.propose', {
    base_revision: head.profile.head_revision,
    ops: [{ op: 'set_entry_disabled', entry_id: entry, disabled }],
  });
  if (change.state !== 'committed') throw new Error(`set_entry_disabled ${disabled} ended ${change.state} (${change.failure_key})`);
}

async function tasksToggle() {
  const deadline = Date.now() + 30_000;
  while (!(await available('desktop.tasks.list'))) {
    if (Date.now() > deadline) throw new Error('desktop.tasks.list never became available (is hostd running?)');
    await sleep(200);
  }
  const profile = await must('desktop.profiles.get', {});
  const entry = profile.document.slots['svc.tasks'];
  if (!entry) throw new Error('the active profile binds no svc.tasks entry');
  const cycle = async () => {
    await setDisabled(entry, true);
    await setDisabled(entry, false);
    const until = Date.now() + 10_000;
    while (!(await available('desktop.tasks.list'))) {
      if (Date.now() > until) throw new Error('tasks did not come back after enabling');
      await sleep(50);
    }
  };
  return { entry, cycle };
}

const realmPackage = 'ditto.fixture.realm_cycle';
const realmCapability = 'plugin.ditto.fixture.realm_cycle.get';

async function realmCycle() {
  // hostd serves the profile's tasks entry; wait for it so the first cycle does not race its start.
  const deadline = Date.now() + 30_000;
  while (!(await available('desktop.tasks.list'))) {
    if (Date.now() > deadline) throw new Error('hostd never served desktop.tasks.list (is hostd running?)');
    await sleep(200);
  }
  const installed = await must('desktop.plugins.list', {});
  if (!JSON.stringify(installed).includes(realmPackage)) throw new Error(`${realmPackage} is not installed (pack the fixtures with DITTO_PACK_FIXTURES=1)`);
  let refusals = 0;
  const cycle = async () => {
    const head = await must('desktop.profiles.get', {});
    const change = await must('desktop.changes.propose', {
      base_revision: head.profile.head_revision,
      ops: [{ op: 'add_entry', entry: { package: realmPackage, version: '1.0.0', host: 'cordis', config: { refuse_as_candidate: true, timers: 2 } } }],
    });
    if (change.state === 'committed') throw new Error('the realm_cycle candidate was committed; it should have refused as a candidate');
    // The refusal must be the fixture's own health check: proof that the candidate mounted and ran in its realm.
    if (!JSON.stringify(change).includes('realm-cycle fixture refuses')) {
      throw new Error(`realm_cycle change ended ${change.state} (${change.failure_key}) without the candidate's refusal: ${JSON.stringify(change).slice(0, 600)}`);
    }
    refusals += 1;
    if (await available(realmCapability)) throw new Error(`${realmCapability} is bound after the change aborted`);
  };
  return { entry: realmPackage, cycle, refusals: () => refusals };
}

try {
  const groups = { 'tasks-toggle': tasksToggle, 'realm-cycle': realmCycle };
  if (!groups[group]) throw new Error(`unknown group ${group}`);
  const { entry, cycle, refusals } = await groups[group]();
  for (let i = 0; i < warmup; i++) await cycle();
  const snapshots = [await snapshot(0)];
  const started = performance.now();
  for (let i = 1; i <= cycles; i++) {
    await cycle();
    if (i % 10 === 0) snapshots.push(await snapshot(i));
  }
  writeFileSync(join(work, 'result.json'), JSON.stringify({ ok: true, group, cycles, warmup, entry_id: entry, ...(refusals ? { candidate_refusals: refusals() } : {}), seconds: Math.round((performance.now() - started) / 100) / 10, snapshots }));
} catch (error) {
  writeFileSync(join(work, 'result.json'), JSON.stringify({ ok: false, group, error: String(error?.message ?? error) }));
}
process.exit(0);
