// A read-back relay for verification runs whose Core is not in development
// mode (a real Shell is launched by Core, so the shared development token is
// not in use). Core starts this through its launcher as `dittoctl`; run.sh
// sends one JSON object per line, {"method", "params"}, to the unix socket
// given as the first argument and gets Core's response back on the same line
// discipline. It only relays: the GUI actions under test come from synthetic
// input to the Shell, never from here.
//
//   dittoctl 0.2.0 <node> tests/g1/lib/relay.mjs <socket path>
import { createServer } from 'node:net';
import { rmSync } from 'node:fs';
import { connect } from './core-client.mjs';

const path = process.argv[2];
if (!path) {
  console.error('usage: relay.mjs <socket path>');
  process.exit(2);
}

const core = await connect();
rmSync(path, { force: true });
const server = createServer(connection => {
  let buffer = '';
  connection.on('data', async chunk => {
    buffer += chunk.toString('utf8');
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      let answer;
      try {
        const { method, params } = JSON.parse(line);
        answer = await core.call(method, params ?? {});
      } catch (error) {
        answer = { error: { name: 'relay', message: String(error) } };
      }
      connection.write(JSON.stringify(answer) + '\n');
    }
  });
  connection.on('error', () => {});
});
server.listen(path, () => console.log(`ditto-relay ready ${path}`));
