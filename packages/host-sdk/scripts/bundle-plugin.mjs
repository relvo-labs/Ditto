// Bundle one Cordis plugin package to the single ESM file its manifest names
// (`entry`, e.g. dist/index.mjs). No node_modules, no native addons, no bare
// imports at run time: hostd resolves nothing but the path Core pushes.
import { existsSync, readFileSync } from 'node:fs'
import { basename, dirname, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'tsdown'
import { vendorAliasFor } from '../../host-runtime/vendor-alias.mjs'
import { addVendorNotice } from '../../host-runtime/scripts/notice.mjs'

// scripts/ (source) and dist/ (bundled CLI) are both one level below the SDK root.
const sdkRoot = fileURLToPath(new URL('../', import.meta.url))
const runtimeRoot = join(sdkRoot, '..', 'host-runtime')
const buildTsconfig = join(runtimeRoot, 'tsconfig.build.json')
const vendorAlias = vendorAliasFor(join(runtimeRoot, 'vendor') + '/')

export function sourceEntry(dir) {
  const pkgPath = join(dir, 'package.json')
  const declared = existsSync(pkgPath) ? JSON.parse(readFileSync(pkgPath, 'utf8')).ditto?.source : undefined
  return resolve(dir, declared ?? 'src/index.ts')
}

/** Imports left in a bundle that hostd could not resolve: anything but node: builtins. */
export function bareImports(code) {
  const found = new Set()
  for (const match of code.matchAll(/(?:^|[;\s])(?:import|export)\s*(?:[^'"()]*?\sfrom\s*)?['"]([^'"]+)['"]|import\(\s*['"]([^'"]+)['"]\s*\)/gm)) {
    const specifier = match[1] ?? match[2]
    if (!specifier.startsWith('node:')) found.add(specifier)
  }
  return [...found]
}

export async function bundlePlugin(dir) {
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'))
  if (manifest.host_kind !== 'cordis') return undefined
  const out = join(dir, manifest.entry)
  const source = sourceEntry(dir)
  if (!existsSync(source)) throw new Error(`${dir}: no plugin source at ${source}`)
  await build({
    config: false,
    cwd: dir,
    entry: { [basename(out, extname(out))]: source },
    outDir: dirname(out),
    format: 'esm',
    platform: 'node',
    target: 'node22',
    fixedExtension: true,
    dts: false,
    clean: false,
    sourcemap: false,
    treeshake: true,
    tsconfig: buildTsconfig,
    alias: { ...vendorAlias, '@ditto/host-sdk': join(sdkRoot, 'src', 'index.ts') },
    // Everything is bundled: a plugin package carries no node_modules.
    deps: { alwaysBundle: [/.*/] },
    outputOptions: { codeSplitting: false },
    logLevel: 'warn',
  })
  addVendorNotice(out, join(runtimeRoot, 'vendor'))
  const code = readFileSync(out, 'utf8')
  const bare = bareImports(code)
  if (bare.length) throw new Error(`${out} still imports ${bare.join(', ')}; hostd cannot resolve bare specifiers`)
  if (/\.node['"]/.test(code) && /require\(/.test(code)) throw new Error(`${out} appears to load a native addon`)
  return out
}
