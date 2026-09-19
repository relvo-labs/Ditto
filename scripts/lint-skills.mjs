#!/usr/bin/env node
// Ditto skill 集合的守門腳本。規則與理由見 plan/01/06-acceptance-and-validation.md。
//
//   node scripts/lint-skills.mjs               檢查全部規則
//   node scripts/lint-skills.mjs --check       另驗證索引新鮮度（CI 用）
//   node scripts/lint-skills.mjs --write-index 重新產生 README.md 與 RELATIONSHIPS.md
//   node scripts/lint-skills.mjs --json        機器可讀輸出

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, readlinkSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SKILLS_DIR = join(ROOT, '.agents/skills')
const PRD = join(ROOT, 'docs/product/Ditto-PRD-v0.4.0.md')
const DECISIONS = join(ROOT, 'milestones/01/05-risks-decisions.md')
const TAXONOMY = join(ROOT, 'plan/01/02-skill-taxonomy.md')

const CATEGORIES = ['architecture', 'runtime', 'agent', 'shell', 'quality', 'process']
const CATEGORY_LABEL = {
  architecture: '所有權、契約、程序與資源邊界',
  runtime: 'Core／Cordis 宿主的執行期行為',
  agent: '意圖理解、規劃與生成',
  shell: 'QML／Quickshell 桌面呈現',
  quality: '驗收、量測與測試',
  process: '文件、決策、移植與發行',
}
const TOP_FIELDS = new Set(['name', 'description', 'license', 'metadata', 'tools', 'model'])
const META_FIELDS = new Set(['type', 'category', 'status', 'language', 'related', 'version'])
const REQUIRED_SECTIONS = ['Overview', 'Authority', 'When to Use', 'Workflow', 'Related Skills']
const SUB_DIRS = new Set(['references', 'scripts', 'templates', 'examples', 'data', 'assets'])
const CRUFT = /^(\.DS_Store|__pycache__|.*\.pyc|.*\.swp|.*~)$/
const REL_TYPES = ['generalizes', 'specializes', 'complements', 'consumes', 'reviews']
const GENERATED_BEGIN = '<!-- BEGIN GENERATED lint-skills.mjs — do not edit between markers -->'
const GENERATED_END = '<!-- END GENERATED lint-skills.mjs -->'

const findings = []
const report = (severity, rule, where, message) => findings.push({ severity, rule, where, message })
const error = (...a) => report('error', ...a)
const warn = (...a) => report('warn', ...a)

// ---------------------------------------------------------------- frontmatter

// 受控 schema 的小型解析器：純量、一層巢狀、字串陣列、`>-` 折疊字串。
// 不支援的結構明確報錯，優於引入相依後仍要驗 schema。
function parseFrontmatter(text, where) {
  const lines = text.split('\n')
  if (lines[0] !== '---') { error('frontmatter-present', where, '缺少起始的 `---`'); return null }
  const end = lines.indexOf('---', 1)
  if (end === -1) { error('frontmatter-present', where, '缺少結束的 `---`'); return null }
  const body = lines.slice(1, end)
  const out = {}
  let i = 0
  const indentOf = (l) => l.length - l.trimStart().length
  while (i < body.length) {
    const line = body[i]
    if (!line.trim()) { i++; continue }
    if (indentOf(line) !== 0) { error('frontmatter-present', where, `非預期縮排：${line}`); return null }
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line)
    if (!m) { error('frontmatter-present', where, `無法解析：${line}`); return null }
    const [, key, rawValue] = m
    i++
    if (rawValue === '>-' || rawValue === '>') {
      const parts = []
      while (i < body.length && (indentOf(body[i]) >= 2 || !body[i].trim())) { parts.push(body[i].trim()); i++ }
      out[key] = parts.filter(Boolean).join(' ')
    } else if (rawValue === '') {
      const nested = {}
      const list = []
      while (i < body.length && (indentOf(body[i]) >= 2 || !body[i].trim())) {
        const l = body[i]
        if (!l.trim()) { i++; continue }
        const item = /^\s+-\s+(.*)$/.exec(l)
        const pair = /^\s+([A-Za-z_][\w-]*):\s*(.*)$/.exec(l)
        if (item) { list.push(unquote(item[1])); i++ ; continue }
        if (pair) {
          const [, k, v] = pair
          i++
          if (v === '') {
            const sub = []
            while (i < body.length && /^\s+-\s+/.test(body[i])) { sub.push(unquote(/^\s+-\s+(.*)$/.exec(body[i])[1])); i++ }
            nested[k] = sub
          } else nested[k] = unquote(v)
          continue
        }
        error('frontmatter-present', where, `無法解析巢狀行：${l}`); return null
      }
      out[key] = list.length ? list : nested
    } else out[key] = unquote(rawValue)
  }
  return { data: out, bodyText: lines.slice(end + 1).join('\n') }
}
const unquote = (s) => s.replace(/^["'](.*)["']$/, '$1').trim()

// ---------------------------------------------------------------- 權威 ID

function expandRanges(text) {
  // `CHG-01～09` / `CHG-01~09` / `CHG-01-09` 展開為個別 ID
  const ids = new Set()
  for (const m of text.matchAll(/\b(CON|GEN|DES|AVA|MOD|CFG|CHG|RUN|SEC|REC|NFR|AT|D)-(\d{2})\s*[～~]\s*(\d{2})\b/g)) {
    const [, prefix, from, to] = m
    for (let n = Number(from); n <= Number(to); n++) ids.add(`${prefix}-${String(n).padStart(2, '0')}`)
  }
  for (const m of text.matchAll(/\b(CON|GEN|DES|AVA|MOD|CFG|CHG|RUN|SEC|REC|NFR|AT|D)-(\d{2})\b/g)) ids.add(`${m[1]}-${m[2]}`)
  return ids
}

const readOrEmpty = (p) => (existsSync(p) ? readFileSync(p, 'utf8') : '')
const prdText = readOrEmpty(PRD)
const knownIds = expandRanges(prdText)
for (const id of expandRanges(readOrEmpty(DECISIONS))) if (id.startsWith('D-')) knownIds.add(id)
if (!prdText) error('requirement-ids-resolve', 'docs/product', 'PRD 不存在，無法驗證需求 ID')

// PRD 行集合，用於偵測原文搬運
const prdLines = new Set(prdText.split('\n').map((l) => l.trim()).filter((l) => l.length >= 20))

// 名冊：plan/01/02 是 15 個 skill 的權威清單
const taxonomyText = readOrEmpty(TAXONOMY)
const ROSTER = new Set([...taxonomyText.matchAll(/\bditto-[a-z][a-z-]+\b/g)].map((m) => m[0]))
if (!ROSTER.size) error('schema-fields', 'plan/01', '無法從 plan/01/02 取得 skill 名冊')

// 計畫 §3 的關係表是關係的權威來源
const planRelations = []
{
  const section = /##\s*3\.\s*關係摘要([\s\S]*?)(?=\n##\s)/.exec(taxonomyText)
  if (section) {
    for (const line of section[1].split('\n')) {
      const cells = line.split('|').map((c) => c.trim())
      if (cells.length < 6) continue
      const [, from, to, type, note] = cells
      if (!from.startsWith('ditto-') || !REL_TYPES.includes(type)) continue
      planRelations.push({ from, to, type, note })
    }
  }
}

// ---------------------------------------------------------------- 載入 skill

function listSkillDirs() {
  if (!existsSync(SKILLS_DIR)) { error('schema-fields', '.agents/skills', '目錄不存在'); return [] }
  return readdirSync(SKILLS_DIR)
    .filter((n) => statSync(join(SKILLS_DIR, n)).isDirectory())
    .sort()
}

const skills = []
for (const dir of listSkillDirs()) {
  const where = `.agents/skills/${dir}`
  const file = join(SKILLS_DIR, dir, 'SKILL.md')
  if (!existsSync(file)) { error('frontmatter-present', where, '缺少 SKILL.md'); continue }
  const raw = readFileSync(file, 'utf8')
  const parsed = parseFrontmatter(raw, where)
  if (!parsed) continue
  skills.push({ dir, where, file, raw, ...parsed })
}
const delivered = new Set(skills.map((s) => s.dir))

// ---------------------------------------------------------------- 逐 skill 規則

function sectionsOf(body) {
  const out = []
  for (const m of body.matchAll(/^##\s+(.+?)\s*$/gm)) out.push({ title: m[1], index: m.index })
  return out
}
function sectionBody(body, title) {
  const all = sectionsOf(body)
  const i = all.findIndex((s) => s.title === title)
  if (i === -1) return null
  const start = all[i].index
  const end = i + 1 < all.length ? all[i + 1].index : body.length
  return body.slice(start, end)
}

for (const s of skills) {
  const { dir, where, data, bodyText, raw } = s
  const meta = typeof data.metadata === 'object' && !Array.isArray(data.metadata) ? data.metadata : {}

  if (data.name !== dir) error('name-matches-dir', where, `name "${data.name}" 與目錄名不符`)
  if (!dir.startsWith('ditto-')) error('name-prefix', where, '名稱必須以 ditto- 開頭')
  if (!/^ditto-[a-z0-9]+(-[a-z0-9]+)*$/.test(dir)) error('name-prefix', where, '名稱必須為 kebab-case')

  for (const k of Object.keys(data)) if (!TOP_FIELDS.has(k)) error('schema-fields', where, `不允許的頂層欄位 "${k}"`)
  for (const k of Object.keys(meta)) if (!META_FIELDS.has(k)) error('schema-fields', where, `不允許的 metadata 欄位 "${k}"`)
  for (const k of ['name', 'description']) if (!data[k]) error('schema-fields', where, `缺少必填欄位 "${k}"`)
  for (const k of ['category', 'status', 'language']) if (!meta[k]) error('schema-fields', where, `缺少 metadata.${k}`)

  const desc = data.description || ''
  if (!/^[A-Z]/.test(desc)) warn('description-english', where, 'description 必須以英文大寫字母開頭')
  if (/[一-鿿]/.test(desc)) warn('description-english', where, 'description 必須為英文')
  if (!desc.includes('Use when ')) error('description-use-when', where, 'description 必須包含 "Use when ..." 觸發語')
  if (desc.length > 500) warn('description-length', where, `description ${desc.length} 字元，超過 500`)

  if (meta.category && !CATEGORIES.includes(meta.category)) error('category-enum', where, `category "${meta.category}" 不在允許清單`)
  if (meta.license || data.license) {
    if (!existsSync(join(SKILLS_DIR, dir, 'LICENSE')) && !existsSync(join(SKILLS_DIR, dir, 'LICENSE.txt')))
      error('license-file-sync', where, '宣告 license 但目錄沒有 LICENSE 檔')
  }

  const titles = sectionsOf(bodyText).map((x) => x.title)
  let cursor = -1
  for (const req of REQUIRED_SECTIONS) {
    const at = titles.indexOf(req)
    if (at === -1) { error('required-sections', where, `缺少必要段落 "## ${req}"`); continue }
    if (at < cursor) error('required-sections', where, `段落 "## ${req}" 順序錯誤`)
    cursor = at
  }
  for (const t of titles) {
    const letters = t.replace(/[^A-Za-z]/g, '')
    if (letters.length >= 3 && letters === letters.toUpperCase()) warn('heading-no-allcaps', where, `全大寫標題 "## ${t}"`)
  }

  const authority = sectionBody(bodyText, 'Authority')
  if (authority) {
    if (!/\]\([^)]+\)/.test(authority)) error('authority-section', where, '## Authority 必須至少有一條權威連結')
    const ids = [...expandRanges(authority)]
    if (!ids.length) error('authority-section', where, '## Authority 必須至少列出一個需求 ID')
    for (const id of ids) if (!knownIds.has(id)) error('requirement-ids-resolve', where, `需求 ID ${id} 在 PRD／決策清單中不存在`)
  }

  const whenToUse = sectionBody(bodyText, 'When to Use')
  if (whenToUse) {
    const others = [...ROSTER].filter((n) => n !== dir && whenToUse.includes(n))
    if (!others.length) warn('boundary-sentence', where, '## When to Use 應含「不適用 → 導向其他 skill」的邊界句')
  }

  // 原文搬運：連續 3 行以上（每行 ≥20 字元）與 PRD 完全相同
  const bodyLines = bodyText.split('\n').map((l) => l.trim())
  let run = 0
  for (const l of bodyLines) {
    if (l.length >= 20 && prdLines.has(l)) { run++; if (run >= 3) { warn('no-duplicated-authority', where, `疑似搬運 PRD 原文：${l.slice(0, 40)}…`); run = 0 } }
    else run = 0
  }

  const related = Array.isArray(meta.related) ? meta.related : []
  const relatedSection = sectionBody(bodyText, 'Related Skills') || ''
  for (const r of related) {
    if (!delivered.has(r)) error('related-exists', where, `related "${r}" 尚未交付或不存在`)
    if (!relatedSection.includes(r)) warn('related-declared-in-body', where, `related "${r}" 未出現在 ## Related Skills`)
  }

  const refsDir = join(SKILLS_DIR, dir, 'references')
  if (existsSync(refsDir)) {
    const refFiles = readdirSync(refsDir).filter((f) => f.endsWith('.md'))
    const refSection = sectionBody(bodyText, 'References')
    if (!refSection) error('references-listed', where, '存在 references/ 但主檔缺少 ## References')
    else for (const f of refFiles) if (!refSection.includes(f)) error('references-listed', where, `## References 未列出 ${f}`)
    for (const f of refFiles) {
      const first = readFileSync(join(refsDir, f), 'utf8').split('\n').find((l) => l.trim())
      if (!first || !first.startsWith('> 用途：')) warn('reference-purpose-header', `${where}/references/${f}`, '參考檔需以 "> 用途：" 開頭')
    }
  }

  const lineCount = raw.split('\n').length
  if (lineCount > 250) warn('mainfile-length', where, `SKILL.md ${lineCount} 行，超過 250`)

  const walk = (d, rel = '') => {
    for (const entry of readdirSync(d)) {
      if (CRUFT.test(entry)) { error('no-cruft', `${where}/${rel}${entry}`, '禁止納入版控的檔案'); continue }
      const p = join(d, entry)
      if (statSync(p).isDirectory()) {
        if (!rel && !SUB_DIRS.has(entry)) error('schema-fields', where, `不允許的附屬目錄 "${entry}"`)
        walk(p, `${rel}${entry}/`)
      }
    }
  }
  walk(join(SKILLS_DIR, dir))
}

// ---------------------------------------------------------------- 全域規則

const relatedPairs = new Set()
for (const s of skills) {
  const meta = s.data.metadata || {}
  for (const r of (Array.isArray(meta.related) ? meta.related : [])) {
    const other = skills.find((x) => x.dir === r)
    if (other) {
      const back = Array.isArray(other.data.metadata?.related) ? other.data.metadata.related : []
      if (!back.includes(s.dir)) warn('related-bidirectional', s.where, `${s.dir} 列了 ${r}，但 ${r} 沒有回列`)
    }
    relatedPairs.add([s.dir, r].sort().join('|'))
  }
}
const planPairs = new Set(
  planRelations.filter((r) => delivered.has(r.from) && delivered.has(r.to)).map((r) => [r.from, r.to].sort().join('|')),
)
for (const p of planPairs) if (!relatedPairs.has(p)) error('related-matches-plan', 'plan/01/02 §3', `計畫宣告的關係 ${p.replace('|', ' ↔ ')} 未出現在 metadata.related`)
for (const p of relatedPairs) if (!planPairs.has(p)) error('related-matches-plan', '.agents/skills', `metadata.related 的 ${p.replace('|', ' ↔ ')} 未出現在 plan/01/02 §3`)

for (const s of skills) if (!ROSTER.has(s.dir)) error('schema-fields', s.where, '不在 plan/01/02 的 skill 名冊中')

// 觸發矩陣
const triggers = []
{
  const section = /##\s*4\.\s*觸發矩陣([\s\S]*?)(?=\n##\s|$)/.exec(taxonomyText)
  if (section) {
    for (const line of section[1].split('\n')) {
      const cells = line.split('|').map((c) => c.trim())
      if (cells.length < 5) continue
      const [, scenario, primary, also] = cells
      const names = [...`${primary} ${also}`.matchAll(/\bditto-[a-z-]+\b/g)].map((m) => m[0])
      if (!names.length) continue
      triggers.push({ scenario, primary: names[0], names })
    }
  }
}
if (!triggers.length) warn('trigger-coverage', 'plan/01/02 §4', '無法解析觸發矩陣')
for (const t of triggers) for (const n of t.names) if (!ROSTER.has(n)) error('trigger-coverage', 'plan/01/02 §4', `觸發矩陣提到不在名冊的 "${n}"`)
for (const s of skills) {
  if (!triggers.some((t) => t.primary === s.dir)) warn('trigger-coverage', s.where, '未在觸發矩陣中作為任一情境的首要 skill')
}

// 符號連結
const link = join(ROOT, '.claude/skills')
if (!existsSync(link)) error('symlink-present', '.claude/skills', '符號連結不存在')
else { try { if (readlinkSync(link) !== '../.agents/skills') error('symlink-present', '.claude/skills', '符號連結目標錯誤') } catch { error('symlink-present', '.claude/skills', '不是符號連結') } }

for (const f of ['AUTHORING.md', 'README.md', 'RELATIONSHIPS.md', '.gitignore'])
  if (!existsSync(join(SKILLS_DIR, f))) error('schema-fields', `.agents/skills/${f}`, '缺少集合治理檔案')

const agentsMd = join(ROOT, 'AGENTS.md')
if (!existsSync(agentsMd)) error('schema-fields', 'AGENTS.md', '缺少導覽入口')
else if (readFileSync(agentsMd, 'utf8').split('\n').length > 60) warn('mainfile-length', 'AGENTS.md', 'AGENTS.md 超過 60 行')

// ---------------------------------------------------------------- 索引產生

const oneLine = (s) => {
  const m = /^>\s*(.+)$/m.exec(s.bodyText)
  return m ? m[1].replace(/。$/, '。') : ''
}
const phaseOf = (s) => {
  const m = new RegExp(`\\|\\s*W(\\d)-\\d\\d\\s*\\|\\s*\`${s.dir}\``).exec(readOrEmpty(join(ROOT, 'plan/01/05-authoring-roadmap.md')))
  return m ? `Wave ${m[1]}` : '—'
}

function buildReadmeBlock() {
  const out = []
  const planned = [...ROSTER].filter((n) => !delivered.has(n)).sort()
  out.push(`已交付 ${skills.length} 個，計畫共 ${ROSTER.size} 個。`, '')
  for (const cat of CATEGORIES) {
    const group = skills.filter((s) => s.data.metadata?.category === cat)
    if (!group.length) continue
    out.push(`## Category: ${cat}`, '', `> ${CATEGORY_LABEL[cat]}`, '', '| Skill | Status | 交付 | 職責 |', '|---|---|---|---|')
    for (const s of group) out.push(`| [${s.dir}](${s.dir}/SKILL.md) | ${s.data.metadata.status} | ${phaseOf(s)} | ${oneLine(s)} |`)
    out.push('')
  }
  out.push('## 觸發速查', '', '| 我正在… | 首要 | 併發 |', '|---|---|---|')
  for (const t of triggers) {
    const mark = (n) => (delivered.has(n) ? `\`${n}\`` : `\`${n}\`（未交付）`)
    const also = t.names.slice(1).map(mark).join('、') || '—'
    out.push(`| ${t.scenario} | ${mark(t.primary)} | ${also} |`)
  }
  out.push('')
  if (planned.length) {
    out.push('## 尚未交付', '', '依 [plan/01/05](../../plan/01/05-authoring-roadmap.md) 的波次安排，下列 skill 等對應子系統成形後再寫：', '')
    for (const n of planned) out.push(`- \`${n}\``)
    out.push('')
  }
  return out.join('\n').trimEnd()
}

function buildRelationshipsBlock() {
  const rows = planRelations.filter((r) => delivered.has(r.from) && delivered.has(r.to))
  const id = (n) => n.replace(/^ditto-/, '').replace(/-/g, '_')
  const out = ['```mermaid', 'graph TD']
  for (const s of skills) out.push(`    ${id(s.dir)}["${s.dir}"]`)
  for (const r of rows) out.push(`    ${id(r.from)} -- ${r.type} --> ${id(r.to)}`)
  out.push('```', '', '| From | To | 類型 | 說明 |', '|---|---|---|---|')
  for (const r of rows) out.push(`| \`${r.from}\` | \`${r.to}\` | ${r.type} | ${r.note} |`)
  const pending = planRelations.filter((r) => !delivered.has(r.from) || !delivered.has(r.to))
  if (pending.length) {
    out.push('', '## 待交付的關係', '', '下列關係已在計畫中宣告，待對應 skill 交付後生效：', '', '| From | To | 類型 |', '|---|---|---|')
    for (const r of pending) out.push(`| \`${r.from}\` | \`${r.to}\` | ${r.type} |`)
  }
  return out.join('\n')
}

function applyBlock(path, block) {
  const text = readOrEmpty(path)
  const begin = text.indexOf(GENERATED_BEGIN)
  const end = text.indexOf(GENERATED_END)
  if (begin === -1 || end === -1) return { ok: false, next: null }
  const next = `${text.slice(0, begin + GENERATED_BEGIN.length)}\n\n${block}\n\n${text.slice(end)}`
  return { ok: true, next, same: next === text }
}

const args = new Set(process.argv.slice(2))
const targets = [
  [join(SKILLS_DIR, 'README.md'), buildReadmeBlock()],
  [join(SKILLS_DIR, 'RELATIONSHIPS.md'), buildRelationshipsBlock()],
]
if (args.has('--write-index')) {
  for (const [path, block] of targets) {
    const r = applyBlock(path, block)
    if (!r.ok) { error('index-fresh', path.replace(`${ROOT}/`, ''), '找不到 GENERATED 標記'); continue }
    if (!r.same) { writeFileSync(path, r.next); console.log(`updated ${path.replace(`${ROOT}/`, '')}`) }
  }
} else if (args.has('--check')) {
  for (const [path, block] of targets) {
    const r = applyBlock(path, block)
    if (!r.ok) error('index-fresh', path.replace(`${ROOT}/`, ''), '找不到 GENERATED 標記')
    else if (!r.same) error('index-fresh', path.replace(`${ROOT}/`, ''), '索引過期，請執行 --write-index')
  }
}

// ---------------------------------------------------------------- 輸出

const errors = findings.filter((f) => f.severity === 'error')
const warns = findings.filter((f) => f.severity === 'warn')
if (args.has('--json')) {
  console.log(JSON.stringify({ skills: skills.length, errors, warns }, null, 2))
} else {
  for (const f of findings) console.log(`${f.severity === 'error' ? 'ERROR' : ' warn'}  [${f.rule}] ${f.where}: ${f.message}`)
  console.log(`\n${skills.length} skills · ${errors.length} error · ${warns.length} warn`)
}
process.exit(errors.length ? 1 : 0)
