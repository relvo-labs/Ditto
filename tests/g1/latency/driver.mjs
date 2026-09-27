#!/usr/bin/env node
// The observer side of tests/g1/latency (EX1-11), launched by Core as a CLI
// client. Times are Core's, never the driver's: every state transition is
// announced as a change_updated event whose `updated_at` Core stamped when it
// wrote that state, so prepared→committed is read from those stamps.
//
//   node driver.mjs <work> service-toggle <count>
// Writes <work>/samples.jsonl (one line per change) and <work>/done.json.
import { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { connect, sleep } from '../lib/core-client.mjs';

const [work, kind, countText = '100'] = process.argv.slice(2);
const count = Number(countText);
const { must, events, available } = await connect();

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

try {
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
