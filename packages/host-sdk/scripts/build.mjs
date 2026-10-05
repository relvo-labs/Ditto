// Bundles the ditto-plugin CLI (validate, pack). tsdown stays an external
// dependency because `pack` calls it at run time.
import { fileURLToPath } from 'node:url'
import { build } from 'tsdown'
import { readFileSync } from 'node:fs'
import { vendorAlias } from '../../host-runtime/vendor-alias.mjs'
import { vendorFingerprint } from '../../host-runtime/scripts/fingerprint.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const runtime = fileURLToPath(new URL('../../host-runtime/', import.meta.url))
const hostd = JSON.parse(readFileSync(`${runtime}package.json`, 'utf8'))
const cordis = JSON.parse(readFileSync(`${runtime}vendor/cordis/package.json`, 'utf8'))
await build({
  config: false,
  cwd: root,
  entry: { 'ditto-plugin': 'src/cli.ts' },
  outDir: 'dist',
  format: 'esm',
  platform: 'node',
  target: 'node22',
  fixedExtension: true,
  dts: false,
  clean: false,
  tsconfig: fileURLToPath(new URL('../../host-runtime/tsconfig.build.json', import.meta.url)),
  alias: { ...vendorAlias, '@ditto/host-runtime/testing': fileURLToPath(new URL('../../host-runtime/src/testing/index.ts', import.meta.url)) },
  define: {
    __DITTO_FAULT__: 'false',
    __DITTO_HOSTD_VERSION__: JSON.stringify(hostd.version),
    __DITTO_CORDIS_VERSION__: JSON.stringify(cordis.version),
    __DITTO_VENDOR_FINGERPRINT__: JSON.stringify(vendorFingerprint(`${runtime}vendor`)),
  },
  deps: { alwaysBundle: [/^@ditto\//, /^@deepseek-ai\//], neverBundle: ['tsdown'] },
  outputOptions: { codeSplitting: false },
  logLevel: 'warn',
})
console.log(`${root}dist/ditto-plugin.mjs`)
