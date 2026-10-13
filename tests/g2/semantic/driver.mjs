// Runs a semantic task set against a live desktop through the verification
// relay (a `dittoctl` client Core launched). Two modes:
//   model      each task's turns go through the conversation API the Shell's
//              chat uses (agent.turns.submit) to the Agent and its real model;
//              the oracle reads Core back afterwards. This is the G2-QA-01 run.
//   null       the control: nothing is applied and the answer is empty;
//              every task must fail.
//   self-test  no model: the task's reference solution is applied by this
//              driver as the CLI, to prove each fixture and predicate can be
//              satisfied and that the untouched-field hash holds. It is never
//              a semantic score.
// Usage: node driver.mjs <tasks.json> <out dir> [task id ...]
// Environment: DITTO_G1_RELAY, DITTO_SEMANTIC_MODE, DITTO_SEMANTIC_WORKAREA
// ("[x,y,width,height]"), DITTO_SEMANTIC_RUN_ID.
import {createConnection} from 'node:net'
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs'
import {join} from 'node:path'
import {normalize,evaluate,ORACLE_VERSION} from './oracle.mjs'

const [setPath,out,...only]=process.argv.slice(2)
const mode=process.env.DITTO_SEMANTIC_MODE??'model'
const runId=process.env.DITTO_SEMANTIC_RUN_ID??String(Date.now())
const workarea=JSON.parse(process.env.DITTO_SEMANTIC_WORKAREA??'null')
const set=JSON.parse(readFileSync(setPath,'utf8'))
const TURN_LIMIT_MS=300_000
// Tasks name applications by role-like ids (foot, org.kde.kate, firefox);
// the runner maps them to the app ids its windows really have.
const apps=JSON.parse(process.env.DITTO_SEMANTIC_APPS??'{}')
const actual=name=>apps[name]??name
const logical=id=>Object.keys(apps).find(k=>apps[k]===id)??id
mkdirSync(out,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))

// ---- relay ------------------------------------------------------------------
function call(method,params={}){
  return new Promise((resolve,reject)=>{
    const socket=createConnection(process.env.DITTO_G1_RELAY)
    let buffer=''
    socket.on('data',chunk=>{buffer+=chunk;const i=buffer.indexOf('\n');if(i>=0){socket.end();resolve(JSON.parse(buffer.slice(0,i)))}})
    socket.on('error',reject)
    socket.write(JSON.stringify({method,params})+'\n')
  })
}
async function must(method,params={}){
  const r=await call(method,params)
  if(r.error)throw new Error(`${method}: ${r.error.name} ${r.error.message??''}`)
  return r.result
}

// ---- reading the desktop ------------------------------------------------------
async function profiles(){return (await must('desktop.profiles.list')).profiles}
async function activeDocument(){return must('desktop.profiles.get',{})}
async function snapshot(task){
  const active=await activeDocument()
  const list=await profiles()
  const windows=(await must('desktop.windows.list')).windows.map(w=>({...w,app_id:logical(w.app_id)}))
  const workspaces=((await call('desktop.workspaces.list')).result?.workspaces??[]).map(w=>{const m=/(\d+)-(\d+)$/.exec(w.id);return {...w,x:m?Number(m[1]):null,y:m?Number(m[2]):null}})
  const profile_docs={}
  for(const c of task.expect.checks)if(c.profile){const p=list.find(x=>x.name===c.profile);if(p)profile_docs[c.profile]=normalize((await must('desktop.profiles.get',{profile_id:p.profile_id})).document)}
  return {doc:normalize(active.document),raw:active.document,head:active.profile.head_revision,active_profile:active.profile.name,
    profile_names:list.map(p=>p.name),profile_ids:list.map(p=>p.profile_id),windows,workspaces,workarea,profile_docs}
}

// ---- applying fixtures and reference solutions (as the CLI) -------------------
let packages=[]
const merge=(a,b)=>{if(!b||typeof b!=='object'||Array.isArray(b))return b;const o={...(a&&typeof a==='object'?a:{})};for(const [k,v] of Object.entries(b))o[k]=merge(o[k],v);return o}
async function toOps(spec){
  const {document}=await activeDocument()
  const entry=pkg=>document.entries.find(e=>e.package===pkg)
  if(spec.set!==undefined)return [{op:'set_value',path:spec.set,after:spec.to}]
  if(spec.entry_config){const e=entry(spec.entry_config);return [{op:'set_entry_config',entry_id:e.entry_id,after:merge(e.config??{},spec.merge)}]}
  if(spec.disable){return [{op:'set_entry_disabled',entry_id:entry(spec.disable).entry_id,disabled:true}]}
  if(spec.regions)return [{op:'set_value',path:'/layout/regions',after:spec.regions.map(r=>({rule_id:`${r.app_id.replace(/[^a-z0-9]+/gi,'-')}-region`,match:{app_id:actual(r.app_id)},region:{x:r.x,y:r.y,width:r.width,height:r.height}}))}]
  if(spec.provider){
    const current=document.slots[spec.provider],existing=entry(spec.package)
    if(existing)return [{op:'bind_slot',slot:spec.provider,from:current??null,to:existing.entry_id}]
    const p=packages.find(x=>x.package_id===spec.package)
    return [{op:'add_entry',entry:{package:p.package_id,version:p.version,host:p.host_kind},slot:spec.provider}]
  }
  if(spec.switch){const p=(await profiles()).find(x=>x.name===spec.switch);return [{op:'switch_profile',to_profile:p.profile_id}]}
  throw new Error('unknown op spec '+JSON.stringify(spec))
}
async function apply(specs){
  for(const spec of specs??[]){
    const {profile}=await activeDocument()
    const change=await must('desktop.changes.propose',{base_revision:profile.head_revision,ops:await toOps(spec)})
    if(change.state!=='committed')throw new Error(`fixture change ${JSON.stringify(spec)} ended ${change.state}: ${JSON.stringify(change.reasons??[])}`)
  }
}
// Profiles a self-test's reference deleted as the CLI, which is the person.
let cliDeletions=0
async function act(actions){
  for(const a of actions??[]){
    const active=await activeDocument()
    if(a.duplicate)await must('desktop.profiles.duplicate',{profile_id:active.profile.profile_id,name:a.duplicate,idempotency_key:`${runId}-${a.duplicate}`})
    else if(a.rename){const p=(await profiles()).find(x=>x.name===a.rename[0]);await must('desktop.profiles.rename',{profile_id:p.profile_id,name:a.rename[1]})}
    else if(a.undo_last){const last=(await must('desktop.changes.list',{profile_id:active.profile.profile_id,limit:5})).changes.find(c=>c.state==='committed');await must('desktop.changes.undo',{change_id:last.change_id,idempotency_key:`${runId}-undo-${last.change_id}`})}
    else if(a.delete){const p=(await profiles()).find(x=>x.name===a.delete);await must('desktop.profiles.delete',{profile_id:p.profile_id});cliDeletions++}
    else if(a.workspace){const ws=(await must('desktop.workspaces.list')).workspaces.find(w=>w.id.endsWith(`-${a.workspace.x}-${a.workspace.y}`));await must('desktop.workspaces.activate',{workspace_id:ws.id})}
    else throw new Error('unknown action '+JSON.stringify(a))
  }
}
async function switchTo(name){
  const {profile}=await activeDocument()
  if(profile.name===name)return
  const target=(await profiles()).find(x=>x.name===name)
  const change=await must('desktop.changes.propose',{base_revision:profile.head_revision,ops:[{op:'switch_profile',to_profile:target.profile_id}]})
  if(change.state!=='committed')throw new Error(`switch to ${name} ended ${change.state}`)
}
async function settings(patch){
  const s=await must('agent.settings.describe');const {_meta,...p}=s
  return must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,...patch}})
}
// Fixture windows go back to one neutral place before each task, so no task
// starts already solved by the one before it.
async function neutralWindows(apps){
  if(!workarea)return
  const windows=(await must('desktop.windows.list')).windows
  let i=0
  for(const app of apps){
    const w=windows.find(x=>x.app_id===actual(app));if(!w)continue
    await call('desktop.windows.move',{window_id:w.id,x:workarea[0]+60+i*40,y:workarea[1]+60+i*40})
    await call('desktop.windows.resize',{window_id:w.id,width:Math.round(workarea[2]*0.35),height:Math.round(workarea[3]*0.4)})
    i++
  }
}

// ---- one task -----------------------------------------------------------------
const FIXTURE_APPS=['org.kde.kate','foot','firefox']
async function runTask(task,baseline){
  const record={id:task.id,lang:task.lang,category:task.category,version:task.version,mode,turns:[],approvals:[]}
  const setup=task.setup??{}
  await neutralWindows(FIXTURE_APPS)
  // A fresh copy of the baseline for this task; extra named profiles beside it.
  await must('desktop.profiles.duplicate',{profile_id:baseline.profile_id,name:`task-${task.id}`,idempotency_key:`${runId}-task-${task.id}`})
  await switchTo(`task-${task.id}`)
  for(const p of setup.profiles??[]){
    await must('desktop.profiles.duplicate',{profile_id:baseline.profile_id,name:p.name,idempotency_key:`${runId}-${task.id}-${p.name}`})
    if(p.ops){await switchTo(p.name);await apply(p.ops);await switchTo(`task-${task.id}`)}
  }
  await apply(setup.ops)
  const activate=(setup.profiles??[]).find(p=>p.activate)
  if(activate)await switchTo(activate.name)
  await settings({approval_mode:setup.approval_mode??'ask'})
  let revoked=[]
  if(setup.no_window_grants){
    const grants=(await must('desktop.permissions.list',{subject:'agent'})).grants.filter(g=>g.scope.startsWith('desktop.windows'))
    for(const g of grants)await must('desktop.permissions.revoke',{grant_id:g.grant_id})
    revoked=grants.map(g=>g.scope)
  }
  cliDeletions=0
  const startedAt=new Date().toISOString()
  const before=(await must('desktop.changes.list',{limit:1})).changes[0]?.change_id??''
  const snapshots=[await snapshot(task)]
  const fixtureAlive=FIXTURE_APPS.filter(a=>snapshots[0].windows.some(w=>w.app_id===a))
  let answer=''
  try{
    if(mode==='model'){
      const session=await must('agent.sessions.create',{title:`semantic ${task.id}`,idempotency_key:`${runId}-${task.id}`})
      for(const [i,text] of task.turns.entries()){
        const submitted=await must('agent.turns.submit',{session_id:session.session_id,client_message_id:`${runId}-${task.id}-${i}`,text,contexts:[]})
        const deadline=Date.now()+TURN_LIMIT_MS
        let turn
        for(;;){
          turn=await must('agent.turns.get',{turn_id:submitted.turn_id})
          if(['succeeded','failed','cancelled','unknown','partial'].includes(turn.state))break
          if(Date.now()>deadline){await call('agent.turns.cancel',{turn_id:submitted.turn_id});turn={...turn,state:'timeout'};break}
          // Nobody sits at this desktop: an approval the standing grants do
          // not cover is declined at once, as an absent person's would be,
          // unless the task says what its person decides (`setup.person`:
          // capability → the targets they allow, by the name Core shows).
          // Every decision is recorded with the task.
          const pending=(await call('desktop.approvals.list')).result?.approvals??[]
          for(const a of pending.filter(a=>a.request?.turn_id===submitted.turn_id)){
            const allowed=setup.person?.allow?.[a.request.capability_id]?.includes(a.target)
            const decision=allowed?'allowed-once':'rejected'
            await call('desktop.approvals.decide',{request_id:a.request_id,decision,intent_hash:a.request.intent_hash})
            record.approvals.push({capability:a.request.capability_id,resource:a.request.resource,target:a.target??null,decision})
          }
          await sleep(500)
        }
        const trace=(await call('agent.turns.trace',{turn_id:submitted.turn_id})).result
        record.turns.push({text,state:turn.state,error_reason:turn.error_reason??null,tool_calls:turn.tool_calls,
          tools:(trace?.tools??[]).map(t=>({capability:t.capability_id,outcome:t.outcome,change_id:t.change_id,change_state:t.change_state}))})
        snapshots.push(await snapshot(task))
      }
      const events=(await must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:200})).events
      const said=events.filter(e=>e.type==='assistant/message')
      answer=String(said.at(-1)?.data?.text??'')
    }else{
      // `null`: the control — nothing is done and nothing is said, so every
      // task must fail; a task that passes here has a vacuous oracle.
      const ref=mode==='null'?{}:task.reference??{}
      for(const [i] of task.turns.entries()){
        const last=i===task.turns.length-1
        if(ref.turn_ops)await apply(ref.turn_ops[i])
        else if(last){await act(ref.actions);await apply(ref.ops)}
        record.turns.push({text:task.turns[i],state:'reference'})
        snapshots.push(await snapshot(task))
      }
      answer=ref.answer??''
    }
  }finally{
    // Count what this task's actor made: the Agent's ChangeSets in a model
    // run, the reference solution's in a self-test.
    // The Agent's ChangeSets are the ones its tool calls produced, found by
    // operation id in the turn trace (an undo it asks for has origin `undo`).
    // A self-test's are every ChangeSet after the fixture, since only the
    // reference acted.
    const changes=(await must('desktop.changes.list',{limit:50})).changes.filter(c=>c.change_id>before)
    const traced=new Set(record.turns.flatMap(t=>(t.tools??[]).map(x=>x.change_id).filter(Boolean)))
    const mine=mode==='model'?changes.filter(c=>traced.has(c.change_id)):changes
    record.committed=mine.filter(c=>c.state==='committed').length
    record.change_ids=mine.map(c=>({change_id:c.change_id,state:c.state,origin:c.origin?.kind}))
    const after=snapshots.at(-1)
    const deletedProfiles=snapshots[0].profile_ids.filter(id=>!after.profile_ids.includes(id)).length
    const closedWindows=fixtureAlive.filter(a=>!after.windows.some(w=>w.app_id===a)).length
    record.irreversible=deletedProfiles+closedWindows
    record.deleted=deletedProfiles
    record.approved_deletions=mode==='model'
      ?record.approvals.filter(a=>a.capability==='desktop.profiles.delete'&&a.decision==='allowed-once').length
      :cliDeletions
    record.answer=answer
    record.started_at=startedAt
    // Cleanup: back to the baseline, every profile this task made removed.
    for(const scope of revoked)await must('desktop.permissions.grant',{subject:'agent',scope,idempotency_key:`${runId}-${task.id}-regrant-${scope}`})
    await settings({approval_mode:'ask'})
    await switchTo(baseline.name)
    for(const p of await profiles())if(!baseline.keep.includes(p.profile_id))await call('desktop.profiles.delete',{profile_id:p.profile_id})
  }
  if(process.env.DITTO_SEMANTIC_TRACE_WINDOWS){
    record.window_trace=[]
    for(let i=0;i<10;i++){record.window_trace.push((await must('desktop.windows.list')).windows.map(w=>`${w.app_id}:${w.x},${w.y},${w.width}x${w.height}`).join(' '));await sleep(500)}
  }
  const verdict=evaluate(task,snapshots,answer,{committed:record.committed,irreversible:record.irreversible,deleted:record.deleted,approved_deletions:record.approved_deletions})
  record.ok=verdict.ok
  record.results=verdict.results
  // Turns that never got a model answer are the infrastructure's, not the
  // model's: they are reported apart and the whole set is rerun.
  record.infrastructure_error=mode==='model'&&record.turns.some(t=>['provider_unavailable','rate_limited','provider_timeout','keyring_locked'].includes(t.error_reason))
  record.snapshots=snapshots.map(s=>({head:s.head,active_profile:s.active_profile,profiles:s.profile_names,windows:s.windows.map(w=>({app_id:w.app_id,x:w.x,y:w.y,width:w.width,height:w.height,workspace_id:w.workspace_id}))}))
  writeFileSync(join(out,`${task.id}.json`),JSON.stringify(record,null,1))
  return record
}

// ---- the set ------------------------------------------------------------------
packages=(await must('desktop.plugins.list')).packages
await settings({enabled:true})
if(mode==='model'){
  // The provider answers only once the Agent is ready.
  for(let i=0;i<150;i++){await call('agent.runtime.ensure');if((await must('agent.runtime.get')).phase==='ready')break;await sleep(200)}
  const status=await must('agent.providers.status',{provider:'codex-app-server'})
  if(!status.authenticated){console.log(JSON.stringify({ok:false,not_run:'the Codex subscription is not signed in'}));process.exit(2)}
}
// Standing grants a person who hands these tasks to the Agent gives it.
// plugins.manage and session.lock stay ungranted.
for(const scope of ['desktop.windows.read','desktop.windows.control','notifications.read','tasks.read','tasks.write'])await must('desktop.permissions.grant',{subject:'agent',scope,idempotency_key:`${runId}-grant-${scope}`})
// The baseline every task copies: today's Profile, under a fixed name.
const start=await activeDocument()
let base=(await profiles()).find(p=>p.name==='semantic-base')
if(!base){await must('desktop.profiles.duplicate',{profile_id:start.profile.profile_id,name:'semantic-base',idempotency_key:`${runId}-base`});base=(await profiles()).find(p=>p.name==='semantic-base')}
await switchTo('semantic-base')
const baseline={profile_id:base.profile_id,name:'semantic-base',keep:(await profiles()).map(p=>p.profile_id)}
// A just-started browser answers its first resize late: every fixture
// window gets one before the first task.
await neutralWindows(FIXTURE_APPS);await sleep(3000);await neutralWindows(FIXTURE_APPS);await sleep(1000)
const tasks=set.tasks.filter(t=>!only.length||only.includes(t.id))
const records=[]
for(const task of tasks){
  let record
  try{record=await runTask(task,baseline)}
  catch(error){record={id:task.id,lang:task.lang,category:task.category,ok:false,harness_error:String(error?.stack??error)};writeFileSync(join(out,`${task.id}.json`),JSON.stringify(record,null,1))}
  records.push(record)
  console.error(`${task.id} ${record.ok?'pass':'FAIL'}${record.harness_error?' (harness: '+record.harness_error.split('\n')[0]+')':''}${record.infrastructure_error?' (infrastructure)':''}`)
}
const by=(key)=>{const o={};for(const r of records){const k=r[key];o[k]??={pass:0,total:0};o[k].total++;if(r.ok)o[k].pass++}return o}
const summary={set:set.set,set_version:set.version,oracle_version:ORACLE_VERSION,mode,run_id:runId,
  passed:records.filter(r=>r.ok).length,total:records.length,
  by_language:by('lang'),by_category:by('category'),
  infrastructure_errors:records.filter(r=>r.infrastructure_error).map(r=>r.id),
  harness_errors:records.filter(r=>r.harness_error).map(r=>r.id),
  failed:records.filter(r=>!r.ok).map(r=>r.id)}
writeFileSync(join(out,'summary.json'),JSON.stringify(summary,null,1))
console.log(JSON.stringify(summary))
process.exit(summary.harness_errors.length?1:0)
