import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import type { JsonSchema } from './manifest/json-schema.ts'
import { findManifestSchema, packPackage, validatePackage } from './package.ts'

/**
 * ditto-plugin validate <dir> [--schema <manifest.json>] [--no-handlers]
 * ditto-plugin pack <dir> [--out <file.dittopkg | dir>] [--schema <manifest.json>] [--no-handlers]
 *
 * --no-handlers skips mounting the entry in the test host (fault fixtures are meant not to start).
 *
 * Without --schema, the nearest schema/manifest.json above <dir> is used when
 * it exists (it is generated from Rust); the TypeScript rules always run.
 */
const usage = 'usage: ditto-plugin validate <dir> [--schema <file>] [--no-handlers]\n       ditto-plugin pack <dir> [--out <file|dir>] [--schema <file>] [--no-handlers]'

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : undefined
}

async function main(argv: string[]): Promise<number> {
  const [command, dirArg, ...rest] = argv
  if (!command || !dirArg || !['validate', 'pack'].includes(command)) {
    console.error(usage)
    return 2
  }
  const dir = resolve(dirArg)
  const schemaPath = option(rest, '--schema') ?? findManifestSchema(dir)
  const schema = schemaPath ? JSON.parse(readFileSync(schemaPath, 'utf8')) as JsonSchema : undefined
  if (command === 'validate') {
    const result = await validatePackage(dir, { ...(schema ? { schema } : {}), checkHandlers: !rest.includes('--no-handlers') })
    for (const issue of result.errors) console.error(`error   ${issue.path} [${issue.code}] ${issue.message}`)
    for (const issue of result.warnings) console.error(`warning ${issue.path} [${issue.code}] ${issue.message}`)
    console.log(result.ok ? `ok ${dir}${schemaPath ? ` (schema ${schemaPath})` : ' (TypeScript rules only; schema/manifest.json not found)'}` : `invalid ${dir}`)
    return result.ok ? 0 : 1
  }
  const out = option(rest, '--out')
  const packed = await packPackage(dir, { ...(out ? { out } : {}), ...(schema ? { schema } : {}), checkHandlers: !rest.includes('--no-handlers') })
  console.log(`sha256:${packed.sha256}  ${packed.file}  (${packed.bytes} bytes)`)
  return 0
}

main(process.argv.slice(2)).then(code => process.exit(code), error => {
  console.error((error as Error).message)
  process.exit(1)
})
