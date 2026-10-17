// Exercise the production hostd exporter without a desktop or socket.
// Exit 1 means content leaked or useful diagnostic records disappeared.
import {writeFileSync} from 'node:fs'
import {HostLog, installCordisExporter} from '../../../packages/host-runtime/src/log.ts'

const records = []
let exporter
const root = {logger: {exporter: value => { exporter = value }}}
installCordisExporter(root, new HostLog(record => records.push(record)))
const markers = ['QA04_WINDOW_TITLE', 'QA04_DOCUMENT_CONTENT', 'QA04_CLIPBOARD_CONTENT', 'QA04_CONVERSATION_CONTENT']
exporter.export({level: 0, name: 'qa04-fixture-plugin', args: [new Error(markers.join(' '))]})
exporter.export({level: 0, name: markers[0], args: ['%s %o', markers[1], {body: markers[2]}]})
exporter.export({level: 0, name: 'qa04-fixture-plugin', args: [{content: markers.join(' ')}]})
const leaks = markers.filter(marker => JSON.stringify(records).includes(marker))
const diagnosticsPresent = records.length === 3 && records.every(record =>
  /^hmac-sha256:[a-f0-9]{64}$/.test(record.error?.fingerprint ?? ''))
const ok = leaks.length === 0 && diagnosticsPresent
const output = process.argv[2]
if (!output) throw new Error('usage: node --experimental-transform-types crash-audit.mjs <output.json>')
writeFileSync(output, JSON.stringify({ok, evidence_class: 'development-host',
  path: 'installCordisExporter → HostLog → stderrSink / journald',
  hits: leaks.length, records, diagnostics_present: diagnosticsPresent,
  scope: 'production exporter with injected Error, formatted message and payload; no actual hostd crash'}, null, 2))
console.log(JSON.stringify({ok, hits: leaks.length, output}))
process.exitCode = ok ? 0 : 1
