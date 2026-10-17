import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {test} from 'node:test'

test('the real third drain fault matches L-06 message, point and hit without sockets', async () => {
  const source = readFileSync(new URL('../../../crates/ditto-core/tests/lifecycle.rs', import.meta.url), 'utf8')
  const matcher = source.slice(source.indexOf('let drains = |hit: u64|'), source.indexOf('// Only the hit that fires'))
  const label = matcher.match(/line\["msg"\] == "([^"]+)"/)[1]
  const point = matcher.match(/line\["point"\] == "([^"]+)"/)[1]
  assert.match(matcher, /line\["hit"\] == hit/)
  const producer = new URL('../../../packages/host-runtime/src/fault-enabled.ts', import.meta.url).href
  const {faultPoint, resetFaultHits} = await import(producer)
  const originalWrite = process.stderr.write
  const originalFault = process.env.DITTO_HOST_FAULT
  let output = ''
  try {
    process.stderr.write = chunk => { output += String(chunk); return true }
    process.env.DITTO_HOST_FAULT = 'commit.after_drain:delay=0:3'
    resetFaultHits()
    for (let i = 0; i < 3; i++) await faultPoint('commit.after_drain')
  } finally {
    process.stderr.write = originalWrite
    if (originalFault === undefined) delete process.env.DITTO_HOST_FAULT
    else process.env.DITTO_HOST_FAULT = originalFault
    resetFaultHits()
  }
  const records = output.split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line))
  assert.equal(records.length, 1)
  assert.equal(records[0].msg, label)
  assert.equal(records[0].point, point)
  assert.equal(records[0].hit, 3)
})
