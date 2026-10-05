import { createHash } from 'node:crypto'

/** One todo.txt line (http://todotxt.org format), parsed only as far as the panel needs. */
export interface TodoLine {
  raw: string
  done: boolean
  completed?: string
  priority?: string
  created?: string
  text: string
  projects: string[]
  contexts: string[]
}

const date = /^\d{4}-\d{2}-\d{2}$/

export function parseLine(raw: string): TodoLine | undefined {
  const line = raw.trim()
  if (!line) return undefined
  const words = line.split(/\s+/)
  let done = false
  let completed: string | undefined
  let priority: string | undefined
  let created: string | undefined
  if (words[0] === 'x') {
    done = true
    words.shift()
    if (words[0] && date.test(words[0])) completed = words.shift()
    if (words[0] && date.test(words[0])) created = words.shift()
  } else {
    if (words[0] && /^\([A-Z]\)$/.test(words[0])) priority = words.shift()!.slice(1, 2)
    if (words[0] && date.test(words[0])) created = words.shift()
  }
  const text = words.join(' ')
  return {
    raw: line, done, text,
    projects: words.filter(word => /^\+\S+$/.test(word)).map(word => word.slice(1)),
    contexts: words.filter(word => /^@\S+$/.test(word)).map(word => word.slice(1)),
    ...(completed ? { completed } : {}), ...(priority ? { priority } : {}), ...(created ? { created } : {}),
  }
}

export function parseFile(content: string): TodoLine[] {
  return content.split(/\r?\n/).map(parseLine).filter((line): line is TodoLine => !!line)
}

/**
 * Ids depend on the task text only (not on priority, dates or the done mark),
 * plus which occurrence of that text it is: completing a task keeps its id, so
 * Core's readback of `desktop.tasks.complete` finds the same `task_id` done.
 * Editing the text itself gives a new id.
 */
export function lineIds(lines: TodoLine[]): string[] {
  const seen = new Map<string, number>()
  return lines.map(line => {
    const hash = createHash('sha256').update(line.text).digest('hex').slice(0, 12)
    const n = (seen.get(hash) ?? 0) + 1
    seen.set(hash, n)
    return `f-${hash}-${n}`
  })
}

export function today(now = new Date()): string {
  return now.toISOString().slice(0, 10)
}

/** Append a new open task line; the file keeps whatever else it had. */
export function appendTask(content: string, text: string, now = new Date()): string {
  const body = content.length && !content.endsWith('\n') ? content + '\n' : content
  return `${body}${today(now)} ${text.replace(/\s*\n\s*/g, ' ').trim()}\n`
}

/** Mark the line with `id` done; returns undefined when the id no longer matches a line. */
export function completeTask(content: string, id: string, now = new Date()): string | undefined {
  const rawLines = content.split(/\r?\n/)
  const parsed = rawLines.map(parseLine)
  const present = parsed.filter((line): line is TodoLine => !!line)
  const ids = lineIds(present)
  const target = present[ids.indexOf(id)]
  if (!target) return undefined
  let index = -1
  let occurrence = 0
  const wanted = Number(id.split('-').at(-1))
  for (let i = 0; i < parsed.length; i++) {
    if (parsed[i]?.text === target.text && ++occurrence === wanted) { index = i; break }
  }
  if (index < 0 || target.done) return target.done ? content : undefined
  const rest = target.priority ? target.raw.replace(/^\([A-Z]\)\s+/, '') : target.raw
  rawLines[index] = `x ${today(now)} ${rest}`
  return rawLines.join('\n')
}
