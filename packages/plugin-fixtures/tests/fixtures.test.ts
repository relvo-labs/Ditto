import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'
import { validateManifest } from '@ditto/host-sdk/manifest'
import { createTestHost, type TestHost } from '@ditto/host-sdk/testing'

const root = fileURLToPath(new URL('../', import.meta.url))
const group = (name: string) => readdirSync(join(root, name)).map(dir => join(root, name, dir))
const manifest = (dir: string) => JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'))
let h: TestHost | undefined
afterEach(async () => { await h?.close(); h = undefined })

describe('D-34 simple plugins and fault fixtures', () => {
  it('has five QML status providers and five Cordis settings plugins, all with valid manifests', () => {
    expect(group('qml')).toHaveLength(5)
    expect(group('cordis')).toHaveLength(5)
    for (const dir of [...group('qml'), ...group('cordis'), ...group('faults'), ...group('stress')]) {
      const m = manifest(dir)
      expect({ dir, errors: validateManifest(m).errors }).toEqual({ dir, errors: [] })
      if (m.host_kind === 'qml') expect(existsSync(join(dir, m.qml_entry))).toBe(true)
    }
  })

  it('mounts all five settings plugins together; each serves its one plugin.<id>.* capability with its config', async () => {
    h = await createTestHost({ packageRoots: [root], pendingWaitMs: 1_000 })
    const entries = group('cordis').map((dir, i) => {
      const m = manifest(dir)
      return h!.entry({ entry_id: `ent-s${i}`, package: m.id, module_path: join(dir, 'src', 'index.ts'), provides: m.provides.map((p: { capability: string }) => p.capability) })
    })
    const { committed } = await h.core.apply('chg-d34', entries)
    expect(committed!.items.every(item => item.status === 'applied')).toBe(true)
    expect(await h.core.invoke('plugin.ditto.fixture.greeting.get')).toEqual({ text: '早安' })
    expect(await h.core.invoke('plugin.ditto.fixture.focus_minutes.get')).toEqual({ minutes: 25 })
    expect(h.core.bindings.size).toBe(5)
  })

  it('realm_cycle: mounted in an isolate realm and taken down again, leaving nothing behind (EX1-04 ③)', async () => {
    h = await createTestHost({ packageRoots: [root], pendingWaitMs: 1_000 })
    const dir = join(root, 'stress', 'realm_cycle')
    const entry = h.entry({
      entry_id: 'ent-realm', package: manifest(dir).id, module_path: join(dir, 'src', 'index.ts'),
      config: { refuse_as_candidate: true, timers: 2 }, provides: ['plugin.ditto.fixture.realm_cycle.get'],
    })
    for (let i = 0; i < 20; i++) {
      const { prepared, committed } = await h.core.apply(`chg-realm-${i}`, [entry])
      expect(prepared.items[0]).toMatchObject({ status: 'failed', reason: expect.stringContaining('unhealthy') })
      expect(committed).toBeUndefined()
      expect(h.runtime.tx.instances.size).toBe(0)
      expect(h.runtime.tx.liveMounts('ent-realm', 'candidate')).toBe(0)
    }
    expect(h.core.bindings.size).toBe(0)
    expect(h.runtime.leases.size).toBe(0)
  })
})
