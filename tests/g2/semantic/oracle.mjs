// The semantic task oracle (G2-QA-01): judges a task only by what Core reads
// back — the Profile document, profiles, windows, workspaces, the Agent's
// ChangeSets — plus the answer text where the expected outcome is to ask or
// to say no. It never reads the model's own claims about success.
import {createHash} from 'node:crypto'

// 2: answer words match whatever apostrophe the model typed ("can’t" is
// "can't"); the profile tasks name the store's default profile.
// 3 (owner, 2026-10-09): an answer asks when it has a question mark or makes
// a request of the person ("please provide …", 「請提供…」); deleting a
// Profile is asked through Core's approval and done as the person decides.
export const ORACLE_VERSION = 3

/** Answer text as compared: lower case, typographic apostrophes as ASCII. */
export const plain=text=>String(text).replace(/[\u2018\u2019\u02bc]/g,"'").toLowerCase()

/** Phrases that make a request of the person without a question mark. A
 * closed list: what counts as asking is fixed with the oracle version. */
export const REQUEST_PHRASES=[
  'please provide','please confirm','please specify','please choose','please pick','please tell','please send','please give','please let me know','let me know which','tell me which',
  'do you want','would you like','did you mean','could you','can you',
  '請提供','請確認','請指定','請選','請告訴','請問','請給','告訴我','要不要','是否要','哪一個','嗎',
]
/** Whether an answer asks the person something. */
export const asks=answer=>/[?？]/.test(answer)||REQUEST_PHRASES.some(p=>plain(answer).includes(p))

/** The Profile document in a form that does not depend on entry ids:
 * entries keyed by package, slots naming packages. */
export function normalize(document){
  const byId=new Map((document.entries??[]).map(e=>[e.entry_id,e]))
  const entries={}
  for(const e of document.entries??[])entries[e.package]={host:e.host,config:e.config??{},disabled:e.disabled??false}
  const slots={}
  for(const [slot,id] of Object.entries(document.slots??{}))slots[slot]=byId.get(id)?.package??null
  return {appearance:document.appearance,avatar:document.avatar,layout:document.layout,shortcuts:document.shortcuts??[],entries,slots}
}

export function pointer(value,path){
  if(path===''||path==='/')return value
  let current=value
  for(const raw of path.split('/').slice(1)){
    const key=raw.replaceAll('~1','/').replaceAll('~0','~')
    if(current==null||typeof current!=='object'||!(key in current))return undefined
    current=current[key]
  }
  return current
}

function canonical(value){
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']'
  if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}'
  return JSON.stringify(value)
}
/** The hash of everything outside `allowed` (pointer prefixes). */
export function untouchedHash(doc,allowed){
  const copy=structuredClone(doc)
  for(const path of allowed){
    const parts=path.split('/').slice(1)
    let parent=copy
    for(const key of parts.slice(0,-1)){if(parent==null||typeof parent!=='object')break;parent=parent[key]}
    if(parent&&typeof parent==='object')delete parent[parts.at(-1)]
  }
  return createHash('sha256').update(canonical(copy)).digest('hex')
}

export function hsl(hex){
  const m=/^#?([0-9a-f]{6})$/i.exec(String(hex??''));if(!m)return null
  const n=parseInt(m[1],16),r=(n>>16&255)/255,g=(n>>8&255)/255,b=(n&255)/255
  const max=Math.max(r,g,b),min=Math.min(r,g,b),l=(max+min)/2,d=max-min
  if(d===0)return {h:0,s:0,l}
  const s=d/(1-Math.abs(2*l-1))
  let h=max===r?((g-b)/d)%6:max===g?(b-r)/d+2:(r-g)/d+4
  h*=60;if(h<0)h+=360
  return {h,s,l}
}
const inHue=(h,[lo,hi])=>lo<=hi?h>=lo&&h<=hi:h>=lo||h<=hi

function within(actual,want,tol){
  if(Array.isArray(want))return actual>=want[0]-1e-9&&actual<=want[1]+1e-9
  return Math.abs(actual-want)<=tol
}

/** `snapshots[0]` is before the first turn, `snapshots[i]` after turn i. */
export function evaluate(task,snapshots,answer,extra={}){
  const before=snapshots[0],after=snapshots.at(-1)
  const results=[]
  const check=(description,ok,detail)=>{results.push({check:description,ok:!!ok,...(detail!==undefined?{detail}:{})});return !!ok}
  const one=(c)=>{
    if(c.any)return c.any.map(inner=>{const saved=results.length;const ok=one(inner);results.length=saved;return ok}).some(Boolean)
    if(c.doc!==undefined){
      const source=c.profile?after.profile_docs?.[c.profile]:after.doc
      // Tokens are strings in the document ("1.2"); numeric checks read them.
      const numeric=v=>typeof v==='string'&&v.trim()!==''&&Number.isFinite(Number(v))?Number(v):v
      const value=('gte' in c||'lte' in c)?numeric(pointer(source,c.doc)):pointer(source,c.doc),old=pointer(before.doc,c.doc)
      if('eq' in c)return canonical(value)===canonical(c.eq)
      if('in' in c)return c.in.some(v=>canonical(v)===canonical(value))
      if(c.hue){const x=hsl(value);return !!x&&x.s>=0.2&&inHue(x.h,c.hue)}
      if(c.lightness){const x=hsl(value);return !!x&&within(x.l,c.lightness,0)}
      if(c.darker_than_turn!==undefined){const x=hsl(value),y=hsl(pointer(snapshots[c.darker_than_turn].doc,c.doc));return !!x&&!!y&&x.l<y.l-0.02}
      if(c.changed)return canonical(value)!==canonical(old)
      if(c.unchanged)return canonical(value)===canonical(old)
      if('gte' in c)return typeof value==='number'?value>=c.gte:typeof value==='undefined'&&c.default!==undefined&&c.default>=c.gte
      if('lte' in c)return typeof value==='number'&&value<=c.lte
      if(c.matches)return Array.isArray(value)&&value.some(v=>new RegExp(c.matches,'i').test(String(v)))
      if(c.absent)return value===undefined
      if(c.rule_for){const rules=Array.isArray(value)?value:[];return rules.some(r=>r.match?.app_id===c.rule_for)}
      throw new Error('unknown doc check '+JSON.stringify(c))
    }
    if(c.window){
      const w=after.windows.find(x=>x.app_id===c.window)
      if(c.alive)return !!w
      if(!w||w.x==null||!after.workarea)return false
      const [ax,ay,aw,ah]=after.workarea
      const got={x:(w.x-ax)/aw,y:(w.y-ay)/ah,width:w.width/aw,height:w.height/ah}
      const tol=c.tol??0.04
      return ['x','y','width','height'].every(k=>c.region[k]===undefined||within(got[k],c.region[k],tol))
    }
    if(c.workspace_active){const ws=after.workspaces?.find(x=>x.active);return !!ws&&ws.x===c.workspace_active.x&&ws.y===c.workspace_active.y}
    if(c.active_profile!==undefined)return after.active_profile===c.active_profile
    if(c.profile_exists!==undefined)return after.profile_names.includes(c.profile_exists)
    if(c.profile_missing!==undefined)return !after.profile_names.includes(c.profile_missing)
    if(c.profile_count==='unchanged')return after.profile_names.length===before.profile_names.length
    if(c.agent_changes){const n=extra.committed??0;return 'eq' in c?n===c.eq:n>=c.gte}
    if(c.answer_any)return c.answer_any.some(word=>plain(answer).includes(plain(word)))
    if(c.asks)return asks(answer)
    // Every Profile the actor deleted went through a person's decision: an
    // approval allowed once (a model run), or the CLI, which is the person
    // (a self-test).
    if(c.deletions_approved)return (extra.deleted??0)>0&&(extra.approved_deletions??0)>=(extra.deleted??0)
    throw new Error('unknown check '+JSON.stringify(c))
  }
  for(const c of task.expect.checks)check(JSON.stringify(c),one(c))
  const outcome=task.expect.outcome
  // `action`: a direct action outside the Profile (save a copy, rename, go
  // to a workspace); its checks say what must be true, ChangeSets aside.
  if(outcome==='change')check('at least one Agent ChangeSet committed',(extra.committed??0)>=1)
  else if(outcome!=='action')check('no Agent ChangeSet committed',(extra.committed??0)===0)
  if(outcome==='clarify')check('the answer asks',asks(answer))
  const allowed=outcome==='change'?task.expect.allowed:[]
  if(!task.expect.skip_untouched)check('nothing outside the allowed paths changed',untouchedHash(after.doc,allowed)===untouchedHash(before.doc,allowed),{allowed})
  check('no irreversible side effect',(extra.irreversible??0)<=(task.expect.irreversible_max??0))
  return {ok:results.every(r=>r.ok),results}
}
