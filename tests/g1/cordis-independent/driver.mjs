#!/usr/bin/env node
// The observer side of tests/g1/cordis-independent (EX1-07). Core launches it
// as a CLI client (kind `dittoctl`, subject `cli`) because with launched
// clients Core runs without the shared development token, so nothing outside
// the launcher can connect. It never kills anything: run.sh does the SIGKILLs
// and the two talk through files in the work directory:
//
//   driver → ready.json   setup done: tasks served, todo.txt granted and
//                         configured, subscribed; carries the hostd entry id
//   run.sh → killed       the Agent stand-in has been SIGKILLed
//   driver → result.json  what happened after the kill
import { appendFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { connect, sleep } from '../lib/core-client.mjs';

const work = process.argv[2];
const todo = join(work, 'todo.txt');
const log = message => process.stderr.write(`[cordis-independent driver] ${message}\n`);
const { must, events, available } = await connect();

try {
  const deadline = Date.now() + 30_000;
  while (!(await available('desktop.tasks.list'))) {
    if (Date.now() > deadline) throw new Error('desktop.tasks.list never became available (is hostd running?)');
    await sleep(200);
  }
  const profile = await must('desktop.profiles.get', {});
  const entry = profile.document.slots['svc.tasks'];
  if (!entry) throw new Error('the active profile binds no svc.tasks entry');
  writeFileSync(todo, '(A) 既有的一項\n');
  const grant = await must('desktop.permissions.grant', {
    subject: `host:${entry}`, scope: 'files:todo', resource: todo, idempotency_key: `g1-todo-${process.pid}`,
  });
  const current = profile.document.entries.find(item => item.entry_id === entry);
  const change = await must('desktop.changes.propose', {
    base_revision: profile.profile.head_revision,
    ops: [{ op: 'set_entry_config', entry_id: entry, before: current?.config ?? null, after: { ...(current?.config ?? {}), source: { kind: 'todo_txt', path_grant: grant.grant_id } } }],
  });
  if (change.state !== 'committed') throw new Error(`configuring the todo.txt source ended ${change.state} (${change.failure_key})`);
  await must('desktop.events.subscribe', { topics: ['tasks'] });
  // The service reads the file once it is configured; wait for that to show.
  const seen = Date.now() + 10_000;
  while (!JSON.stringify((await must('desktop.tasks.list', {}))).includes('既有的一項')) {
    if (Date.now() > seen) throw new Error('the tasks service never listed the granted todo.txt');
    await sleep(100);
  }
  writeFileSync(join(work, 'ready.json'), JSON.stringify({ entry_id: entry, grant_id: grant.grant_id, change_id: change.change_id }));
  log('ready');

  const killedBy = Date.now() + 60_000;
  while (!existsSync(join(work, 'killed'))) {
    if (Date.now() > killedBy) throw new Error('run.sh never reported the kill');
    await sleep(50);
  }
  // The file changes from outside, as an editor would change it.
  const marker = `g1 外部新增 ${process.pid}`;
  const from = events.length;
  const written = performance.now();
  appendFileSync(todo, `${marker}\n`);
  let latency = null;
  const until = written + 5_000;
  while (performance.now() < until && latency === null) {
    for (const event of events.slice(from)) {
      if (JSON.stringify(event.params).includes('tasks')) {
        // The event says "changed"; the list is what shows the new item.
        if (JSON.stringify(await must('desktop.tasks.list', {})).includes(marker)) {
          latency = Math.round(event.at - written);
          break;
        }
      }
    }
    if (latency === null) await sleep(20);
  }
  writeFileSync(join(work, 'result.json'), JSON.stringify({
    ok: true,
    event_latency_ms: latency,
    tasks_available_after_kill: await available('desktop.tasks.list'),
    listed_after_kill: JSON.stringify(await must('desktop.tasks.list', {})).includes(marker),
    events_after_kill: events.length - from,
  }));
} catch (error) {
  writeFileSync(join(work, 'result.json'), JSON.stringify({ ok: false, error: String(error?.message ?? error) }));
  log(String(error?.stack ?? error));
}
process.exit(0);
