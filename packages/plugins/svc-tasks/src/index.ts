import { watch } from 'node:fs'
import { basename, dirname } from 'node:path'
import { createHash } from 'node:crypto'
import { CapabilityError, defineCapability, defineDittoPlugin, type Context, type GrantedFile, type Json } from '@ditto/host-sdk'
import { appendTask, completeTask, lineIds, parseFile, today, type TodoLine } from './todotxt.ts'

/**
 * Tasks/todo data service (plan/03/03 §6). Two real sources: a todo.txt file
 * the user granted (`files:<grant>`) and the plugin's own list in its data
 * area. No UI or Agent is needed for it to run; the panel and `dittoctl tasks
 * list` are consumers. Sample items exist only when configured, and are marked.
 */

export interface TasksConfig {
  /** `path_grant` names a Core permission grant; the path itself lives in the grant, never in config. */
  source?: { kind: 'todo_txt'; path_grant: string }
  /** Show three sample items while no file is granted. They are always labelled as samples. */
  demo?: boolean
}

type FileState = 'not_configured' | 'active' | 'not_granted' | 'revoked' | 'unreadable'

/** ditto_protocol::services::Task. Core deserialises it strictly: no extra fields. */
export interface Task {
  task_id: string
  text: string
  done: boolean
  /** `own`, `file:<grant_id>`, or `demo` for labelled samples. */
  source: string
  priority?: string
}

/** ditto_protocol::services::TasksListOutput. */
export interface TasksList {
  tasks: Task[]
  sources: { source: string; status: 'ok' | 'revoked' | 'unavailable' }[]
  /** Sample content is labelled, never presented as the user's own. */
  demo: boolean
}

interface OwnItem { id: string; text: string; done: boolean; created: string; completed?: string }
interface OwnList { next: number; items: OwnItem[] }

type PendingOp = { kind: 'add'; source: 'file' | 'own'; text: string } | { kind: 'complete'; task_id: string }

const ownFile = 'own-tasks.json'
const demoItems: Task[] = [
  { task_id: 'demo-1', text: '整理桌面上的下載檔案', done: false, source: 'demo' },
  { task_id: 'demo-2', text: '回覆本週的會議邀請', done: false, source: 'demo' },
  { task_id: 'demo-3', text: '備份照片', done: true, source: 'demo' },
]

/** Wire status of the file source; the Shell turns it into copy (e.g. 「檔案存取已撤銷」). */
const sourceStatus: Record<FileState, 'ok' | 'revoked' | 'unavailable' | undefined> = {
  not_configured: undefined,
  active: 'ok',
  not_granted: 'unavailable',
  revoked: 'revoked',
  unreadable: 'unavailable',
}

function fromLine(line: TodoLine, id: string, source: string): Task {
  return { task_id: id, text: line.text, done: line.done, source, ...(line.priority ? { priority: line.priority } : {}) }
}

export default defineDittoPlugin<TasksConfig>({
  name: 'ditto-svc-tasks',
  events: [{ name: 'tasks/changed', coalesce: 'latest' }],
  async apply(ctx: Context, config: TasksConfig) {
    const grantId = config?.source?.kind === 'todo_txt' ? config.source.path_grant : undefined
    let fileState: FileState = grantId ? 'not_granted' : 'not_configured'
    let file: GrantedFile | undefined
    let fileItems: Task[] = []
    let fileHash = ''
    let own: OwnList = (await ctx.ditto.data.readJson<OwnList>(ownFile)) ?? { next: 1, items: [] }
    let revision = 0
    let accepting = true
    let stopWatching: (() => unknown) | undefined
    /** Ops accepted but not yet on disk; handed to the next instance on replacement. */
    const pending: PendingOp[] = []
    let queue: Promise<unknown> = Promise.resolve()

    const fileSource = `file:${grantId ?? ''}`
    const ownTask = (item: OwnItem): Task => ({ task_id: item.id, text: item.text, done: item.done, source: 'own' })

    /** `source` filter: `own`, `file` or `file:<grant>`; anything else lists everything. */
    const snapshot = (source?: string): TasksList => {
      const showDemo = config?.demo === true && fileState !== 'active'
      const wantFile = source === undefined || source === 'file' || source === fileSource
      const wantOwn = source === undefined || source === 'own'
      const status = sourceStatus[fileState]
      return {
        tasks: [
          ...(wantFile ? fileItems : []),
          ...(wantOwn ? own.items.map(ownTask) : []),
          // Sample items are never presented as the user's real progress (PRD 5.4): `demo` says so.
          ...(showDemo && source === undefined ? demoItems : []),
        ],
        sources: [...(status ? [{ source: fileSource, status }] : []), { source: 'own', status: 'ok' as const }],
        demo: showDemo,
      }
    }

    const changed = (why: string) => {
      revision += 1
      const real = snapshot().tasks.filter(task => task.source !== 'demo')
      ctx.ditto.events.emit('tasks/changed', {
        revision, why,
        open: real.filter(task => !task.done).length,
        done: real.filter(task => task.done).length,
        file_state: fileState,
      })
    }

    const readFile = async (): Promise<boolean> => {
      if (!file) return false
      try {
        const content = await file.readText()
        const hash = createHash('sha256').update(content).digest('hex')
        if (hash === fileHash && fileState === 'active') return false
        fileHash = hash
        const lines = parseFile(content)
        const ids = lineIds(lines)
        fileItems = lines.map((line, i) => fromLine(line, ids[i]!, fileSource))
        fileState = 'active'
        return true
      } catch (error) {
        const wasActive = fileState === 'active'
        fileState = (error as NodeJS.ErrnoException).code === 'ENOENT' ? 'active' : 'unreadable'
        fileItems = []
        fileHash = ''
        return wasActive || fileState === 'unreadable'
      }
    }

    // Serialised writes: file edits read-modify-write the current content, never a cached copy.
    const enqueue = <T>(op: PendingOp, work: () => Promise<T>): Promise<T> => {
      if (!accepting) return Promise.reject(new CapabilityError('unavailable', 'tasks service is handing over; retry shortly', { reason: 'recovering' }))
      pending.push(op)
      const run = queue.then(work).finally(() => { pending.splice(pending.indexOf(op), 1) })
      queue = run.catch(() => {})
      return run
    }

    const saveOwn = () => ctx.ditto.data.writeJson(ownFile, own as unknown as Json)

    const apply = async (op: PendingOp): Promise<Task> => {
      if (op.kind === 'add' && op.source === 'own') {
        const item: OwnItem = { id: `o-${own.next}`, text: op.text, done: false, created: today() }
        own = { next: own.next + 1, items: [...own.items, item] }
        await saveOwn()
        changed('own_added')
        return ownTask(item)
      }
      if (op.kind === 'add') {
        if (!file || fileState !== 'active') throw new CapabilityError('permission_denied', 'no usable todo.txt grant', { reason: 'not_granted' })
        const content = await file.readText().catch(() => '')
        await file.writeText(appendTask(content, op.text))
        await readFile()
        changed('file_added')
        return fileItems.at(-1)!
      }
      const ownItem = own.items.find(item => item.id === op.task_id)
      if (ownItem) {
        own = { ...own, items: own.items.map(item => item.id === op.task_id ? { ...item, done: true, completed: today() } : item) }
        await saveOwn()
        changed('own_completed')
        return ownTask(own.items.find(item => item.id === op.task_id)!)
      }
      if (!file || fileState !== 'active') throw new CapabilityError('not_found', `task ${op.task_id} not found`)
      await readFile()
      const updated = fileItems.some(item => item.task_id === op.task_id) ? completeTask(await file.readText(), op.task_id) : undefined
      if (updated === undefined) throw new CapabilityError('not_found', `task ${op.task_id} not found (the file changed?)`)
      await file.writeText(updated)
      await readFile()
      changed('file_completed')
      // The id depends on the text only, so the completed line keeps it.
      return fileItems.find(item => item.task_id === op.task_id)!
    }

    const startWatching = (path: string) => {
      // Editors replace files atomically, so watch the directory and filter by name.
      stopWatching = ctx.effect(() => {
        let timer: NodeJS.Timeout | undefined
        const watcher = watch(dirname(path), (_event, name) => {
          if (name !== null && name !== basename(path)) return
          clearTimeout(timer)
          timer = setTimeout(() => { void readFile().then(isNew => { if (isNew) changed('file_edited') }) }, 50)
        })
        watcher.on('error', () => { fileState = 'unreadable'; changed('watch_failed') })
        return () => { clearTimeout(timer); watcher.close() }
      }, 'svc-tasks: fs.watch(todo.txt)')
    }

    if (grantId) {
      try {
        file = await ctx.ditto.permissions.resolveFile(grantId)
        await readFile()
        startWatching(file.path)
      } catch {
        // Not granted (or Core said no): only the plugin's own list is served. Never guess a path.
        file = undefined
        fileState = 'not_granted'
      }
    }

    ctx.ditto.permissions.onRevoked(async grant => {
      if (grant.grant_id !== grantId) return
      await stopWatching?.()
      stopWatching = undefined
      file = undefined
      fileItems = []
      fileHash = ''
      fileState = 'revoked'
      changed('file_revoked')
    })

    // Shapes are ditto_protocol::services::{TasksListInput, TasksListOutput, TasksAddInput, TasksCompleteInput, Task}.
    ctx.ditto.capabilities.register(defineCapability<{ source?: string | null }, TasksList>({
      id: 'desktop.tasks.list',
      version: '1.0.0',
      handler: input => snapshot(input?.source ?? undefined),
    }))
    ctx.ditto.capabilities.register(defineCapability<{ text: string; source?: string | null }, Task>({
      id: 'desktop.tasks.add',
      version: '1.0.0',
      handler: async input => {
        const text = typeof input?.text === 'string' ? input.text.trim() : ''
        if (!text) throw new CapabilityError('invalid_params', 'text is required')
        const wanted = input.source ?? (fileState === 'active' ? 'file' : 'own')
        const op: PendingOp = { kind: 'add', source: wanted === 'own' ? 'own' : 'file', text }
        return enqueue(op, () => apply(op))
      },
    }))
    ctx.ditto.capabilities.register(defineCapability<{ task_id: string }, Task>({
      id: 'desktop.tasks.complete',
      version: '1.0.0',
      handler: async input => {
        if (typeof input?.task_id !== 'string') throw new CapabilityError('invalid_params', 'task_id is required')
        const op: PendingOp = { kind: 'complete', task_id: input.task_id }
        return enqueue(op, () => apply(op))
      },
    }))
    // Core runs the subscription itself (one broker, one seq) and takes the snapshot from
    // desktop.tasks.list; the registration makes the capability available while this entry serves.
    ctx.ditto.capabilities.register(defineCapability<Record<string, never>, { snapshot: TasksList }>({
      id: 'desktop.tasks.subscribe',
      version: '1.0.0',
      handler: () => ({ snapshot: snapshot() }),
    }))

    // Controlled handoff (hot_swap: controlled_handoff): stop taking writes, finish the queue,
    // hand over whatever did not reach disk. Data only.
    ctx.ditto.lifecycle.onDrain(async () => {
      accepting = false
      await queue
    })
    ctx.ditto.lifecycle.exportState(() => ({ pending: pending.map(op => ({ ...op })) }) as Json)
    ctx.ditto.lifecycle.importState(async state => {
      for (const op of ((state as { pending?: PendingOp[] })?.pending ?? [])) await enqueue(op, () => apply(op)).catch(() => {})
    })
    // No custom health check: a missing or unreadable file is a source state the panel shows,
    // not a reason to refuse the service (the plugin's own list still works).

    // A new instance (a changed source, a restart) may serve a different list from the one the
    // panel last read; say so once. The runtime holds it until this instance is the active one.
    changed('started')
  },
})
