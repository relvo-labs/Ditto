import { mkdir, readdir, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import type { DataArea, GrantedFile, Json } from './api.ts'
import { DittoError } from './errors.ts'

let tmpSequence = 0

/** Write-then-rename in the target directory, so readers never see half a file. */
export async function atomicWrite(path: string, text: string): Promise<void> {
  const tmp = join(dirname(path), `.${process.pid}.${++tmpSequence}.ditto-tmp`)
  try {
    await writeFile(tmp, text, { mode: 0o600 })
    await rename(tmp, path)
  } catch (error) {
    await rm(tmp, { force: true })
    throw error
  }
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException)?.code === 'ENOENT'
}

/**
 * `ctx.ditto.data`: the plugin's area under the `data_dir` Core assigned
 * (`plugin-data/<plugin_id>/`). hostd creates nothing outside it.
 */
export class PluginDataArea implements DataArea {
  constructor(readonly dir: string) {}

  private async resolve(path: string): Promise<string> {
    if (isAbsolute(path)) throw new DittoError('invalid_params', `data paths are relative: ${path}`)
    const target = resolve(this.dir, path)
    const rel = relative(this.dir, target)
    if (!rel || rel.startsWith('..') || isAbsolute(rel)) throw new DittoError('invalid_params', `path escapes the data area: ${path}`)
    await mkdir(dirname(target), { recursive: true, mode: 0o700 })
    // A symlink inside the area must not lead out of it.
    const [realDir, realParent] = await Promise.all([realpath(this.dir), realpath(dirname(target))])
    if (realParent !== realDir && !realParent.startsWith(realDir + sep)) {
      throw new DittoError('invalid_params', `path escapes the data area: ${path}`)
    }
    return target
  }

  async readText(path: string): Promise<string | undefined> {
    try { return await readFile(await this.resolve(path), 'utf8') } catch (error) {
      if (isMissing(error)) return undefined
      throw error
    }
  }

  async writeText(path: string, text: string): Promise<void> {
    await atomicWrite(await this.resolve(path), text)
  }

  async readJson<T = Json>(path: string): Promise<T | undefined> {
    const text = await this.readText(path)
    return text === undefined ? undefined : JSON.parse(text) as T
  }

  async writeJson(path: string, value: Json): Promise<void> {
    await this.writeText(path, JSON.stringify(value, null, 2) + '\n')
  }

  async remove(path: string): Promise<void> {
    await rm(await this.resolve(path), { force: true, recursive: true })
  }

  async list(path = '.'): Promise<string[]> {
    const dir = path === '.' ? this.dir : await this.resolve(path)
    await mkdir(this.dir, { recursive: true, mode: 0o700 })
    try { return (await readdir(dir)).filter(name => !name.endsWith('.ditto-tmp')).sort() } catch (error) {
      if (isMissing(error)) return []
      throw error
    }
  }
}

export function grantedFile(grantId: string, path: string): GrantedFile {
  return {
    grantId,
    path,
    readText: () => readFile(path, 'utf8'),
    writeText: text => atomicWrite(path, text),
  }
}
