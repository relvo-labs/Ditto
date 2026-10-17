// Reproduce the current hostd error exporter gap without a desktop or socket.
// Exit 1 means the production exporter emitted private synthetic content.
import {writeFileSync} from 'node:fs'
import {HostLog, installCordisExporter} from '../../../packages/host-runtime/src/log.ts'

const records = []
let exporter
const root = {logger: {exporter: value => { exporter = value }}}
installCordisExporter(root, new HostLog(record => records.push(record)))
const markers = ['QA04_WINDOW_TITLE', 'QA04_DOCUMENT_CONTENT', 'QA04_CLIPBOARD_CONTENT', 'QA04_CONVERSATION_CONTENT']
exporter.export({level: 0, name: 'qa04-fixture-plugin', args: [new Error(markers.join(' '))]})
const leaks = markers.filter(marker => JSON.stringify(records).includes(marker))
const output = process.argv[2]
if (!output) throw new Error('usage: node --experimental-transform-types crash-audit.mjs <output.json>')
writeFileSync(output, JSON.stringify({ok: leaks.length === 0, evidence_class: 'development-host',
  path: 'installCordisExporter → HostLog → stderrSink / journald',
  hits: leaks.length, records, scope: 'production exporter with injected plugin Error; no actual hostd crash',
  fix: 'BLOCKED: packages/host-runtime/src/log.ts is outside QA-04 write set'}, null, 2))
console.log(JSON.stringify({ok: leaks.length === 0, hits: leaks.length, output}))
process.exitCode = leaks.length ? 1 : 0
