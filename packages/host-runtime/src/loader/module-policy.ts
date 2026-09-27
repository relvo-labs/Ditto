import { realpathSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, join, normalize, sep } from 'node:path'
import { pathToFileURL } from 'node:url'
import { DittoError } from '../errors.ts'

/**
 * Where plugin modules may come from (plan/03/03 §3.2). This makes "which
 * version is loaded" checkable; it is not a security boundary, because code in
 * the same Node process can still `import()` anything.
 */
export class ModulePolicy {
  private readonly roots: string[]
  /** module_path values Core pushed; the loader may import nothing else. */
  private readonly pushed = new Set<string>()

  constructor(roots: string[]) {
    this.roots = roots.map(root => {
      const real = safeRealpath(root) ?? normalize(root)
      return real.endsWith(sep) ? real : real + sep
    })
  }

  /** Same data directory Core uses (ditto_store::Paths::from_environment), so both agree on the store. */
  static fromEnvironment(env: NodeJS.ProcessEnv): ModulePolicy {
    const xdg = env['XDG_DATA_HOME']
    const data = env['DITTO_DATA_DIR'] ? join(env['DITTO_DATA_DIR'], 'data')
      : join(xdg && isAbsolute(xdg) ? xdg : join(env['HOME'] || homedir(), '.local', 'share'), 'ditto')
    const roots = [join(data, 'packages', 'sha256')]
    // Development builds may point at source trees; never set by the systemd unit.
    for (const dev of (env['DITTO_DEV_PACKAGES'] ?? '').split(':').filter(Boolean)) roots.push(dev)
    return new ModulePolicy(roots)
  }

  get allowedRoots(): readonly string[] { return this.roots }

  /** Called by the transaction layer for each entry Core pushes; throws `invalid_params` outside the roots. */
  admit(modulePath: string): string {
    const real = this.check(modulePath)
    this.pushed.add(modulePath)
    return real
  }

  /** Called from the loader's import hook. Only admitted paths resolve. */
  resolve(specifier: string): string {
    if (!this.pushed.has(specifier)) {
      throw new DittoError('invalid_params', `module ${specifier} was not pushed by Core`)
    }
    return pathToFileURL(this.check(specifier)).href
  }

  private check(modulePath: string): string {
    if (!isAbsolute(modulePath) || normalize(modulePath) !== modulePath) {
      throw new DittoError('invalid_params', `module_path must be an absolute normalised path: ${modulePath}`)
    }
    const real = safeRealpath(modulePath)
    if (!real) throw new DittoError('invalid_params', `module_path does not exist: ${modulePath}`)
    if (!this.roots.some(root => real.startsWith(root))) {
      throw new DittoError('invalid_params', `module_path is outside the package store: ${modulePath}`)
    }
    if (real.split(sep).includes('node_modules')) {
      throw new DittoError('invalid_params', `module_path must not resolve into node_modules: ${modulePath}`)
    }
    return real
  }
}

function safeRealpath(path: string): string | undefined {
  try { return realpathSync(path) } catch { return undefined }
}
