/** Just enough semver for manifest checks: versions, and ranges built from ^ ~ >= > <= < = x-ranges and ||. */
export interface Version { major: number; minor: number; patch: number; pre: string }

const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/

export function parseVersion(text: string): Version | undefined {
  const match = versionPattern.exec(text)
  if (!match) return undefined
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]), pre: match[4] ?? '' }
}

function compare(a: Version, b: Version): number {
  return a.major - b.major || a.minor - b.minor || a.patch - b.patch || (a.pre === b.pre ? 0 : a.pre === '' ? 1 : b.pre === '' ? -1 : a.pre < b.pre ? -1 : 1)
}

type Comparator = (v: Version) => boolean

function partial(text: string): { major?: number; minor?: number; patch?: number } | undefined {
  if (text === '*' || text === 'x' || text === '') return {}
  const parts = text.split('.')
  if (parts.length > 3) return undefined
  const numbers = parts.map(part => (part === 'x' || part === '*' ? undefined : /^\d+$/.test(part) ? Number(part) : NaN))
  if (numbers.some(n => Number.isNaN(n))) return undefined
  const [major, minor, patch] = numbers
  return { ...(major !== undefined ? { major } : {}), ...(minor !== undefined ? { minor } : {}), ...(patch !== undefined ? { patch } : {}) }
}

function lower(p: { major?: number; minor?: number; patch?: number }): Version {
  return { major: p.major ?? 0, minor: p.minor ?? 0, patch: p.patch ?? 0, pre: '' }
}

function comparator(token: string): Comparator | undefined {
  const match = /^(\^|~|>=|<=|>|<|=)?v?(.*)$/.exec(token)!
  const op = match[1] ?? ''
  const p = partial(match[2]!)
  if (!p) return undefined
  const low = lower(p)
  const ge = (v: Version) => compare(v, low) >= 0
  if (op === '^') {
    const upper = p.major ? { major: p.major + 1, minor: 0, patch: 0, pre: '' }
      : p.minor ? { major: 0, minor: p.minor + 1, patch: 0, pre: '' }
      : p.minor === undefined ? { major: 1, minor: 0, patch: 0, pre: '' } : { major: 0, minor: 0, patch: (p.patch ?? 0) + 1, pre: '' }
    return v => ge(v) && compare(v, upper) < 0
  }
  if (op === '~') {
    const upper = p.minor === undefined ? { major: low.major + 1, minor: 0, patch: 0, pre: '' } : { major: low.major, minor: low.minor + 1, patch: 0, pre: '' }
    return v => ge(v) && compare(v, upper) < 0
  }
  if (op === '>=') return ge
  if (op === '>') return v => compare(v, low) > 0
  if (op === '<') return v => compare(v, low) < 0
  if (op === '<=') return v => compare(v, low) <= 0
  // Bare or `=`: an x-range when parts are missing.
  if (p.major === undefined) return () => true
  if (p.minor === undefined) return v => v.major === p.major
  if (p.patch === undefined) return v => v.major === p.major && v.minor === p.minor
  return v => compare(v, low) === 0
}

/** Returns undefined when the range does not parse. */
export function parseRange(text: string): ((version: string) => boolean) | undefined {
  const alternatives = text.trim().split('||').map(part => part.trim().split(/\s+/).filter(Boolean))
  const compiled: Comparator[][] = []
  for (const tokens of alternatives) {
    if (!tokens.length) return undefined
    const set: Comparator[] = []
    for (const token of tokens) {
      const c = comparator(token)
      if (!c) return undefined
      set.push(c)
    }
    compiled.push(set)
  }
  return version => {
    const v = parseVersion(version)
    return !!v && compiled.some(set => set.every(c => c(v)))
  }
}
