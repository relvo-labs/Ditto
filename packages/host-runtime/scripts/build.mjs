// Bundles ditto-hostd into one ESM file (plan/03/03 §2.3: module count drives
// Node start-up time and resident memory under the 100 MiB hostd budget).
//
//   pnpm --filter @ditto/host-runtime build                 → dist/ditto-hostd.mjs
//   DITTO_HOST_FAULT_ENABLE=1 pnpm --filter … build         → also dist/ditto-hostd-fault.mjs
//
// The production bundle is built with __DITTO_FAULT__=false and must not
// contain the fault-point code; this script fails the build if it does.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { build } from 'tsdown'
import { vendorAlias } from '../vendor-alias.mjs'
import { vendorFingerprint } from './fingerprint.mjs'
import { addVendorNotice } from './notice.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const pkg = JSON.parse(readFileSync(`${root}package.json`, 'utf8'))
const cordis = JSON.parse(readFileSync(`${root}vendor/cordis/package.json`, 'utf8'))
const fingerprint = vendorFingerprint(`${root}vendor`)

async function bundle(name, faults) {
  await build({
    config: false,
    cwd: root,
    entry: { [name]: 'src/main.ts' },
    format: 'esm',
    platform: 'node',
    target: 'node22',
    outDir: 'dist',
    fixedExtension: true,
    dts: false,
    clean: false,
    sourcemap: false,
    treeshake: true,
    // tsconfig paths point at declaration files for typechecking; bundling uses the source aliases.
    tsconfig: 'tsconfig.build.json',
    alias: vendorAlias,
    outputOptions: { codeSplitting: false },
    logLevel: 'warn',
    define: {
      __DITTO_FAULT__: faults ? 'true' : 'false',
      __DITTO_HOSTD_VERSION__: JSON.stringify(pkg.version),
      __DITTO_CORDIS_VERSION__: JSON.stringify(cordis.version),
      __DITTO_VENDOR_FINGERPRINT__: JSON.stringify(fingerprint),
    },
  })
  const file = `${root}dist/${name}.mjs`
  addVendorNotice(file, `${root}vendor`, true)
  return file
}

const production = await bundle('ditto-hostd', false)
const text = readFileSync(production, 'utf8')
for (const marker of ['DITTO_HOST_FAULT', 'DITTO_HOST_STRATEGY', 'fault injected']) {
  if (text.includes(marker)) {
    console.error(`production bundle contains fault-injection code (${marker}); refusing to ship it`)
    process.exit(1)
  }
}
console.log(`${production}  ${(text.length / 1024).toFixed(1)} KiB  vendor ${fingerprint}`)
if (process.env.DITTO_HOST_FAULT_ENABLE === '1') {
  console.log(`${await bundle('ditto-hostd-fault', true)}  (test build: DITTO_HOST_FAULT is honoured)`)
}
