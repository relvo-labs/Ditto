// Runs inside Core as a launched CLI client and drives one Agent turn the
// way the Shell would: settings, a message, Core's verified result, undo.
import assert from 'node:assert/strict'
import {readFileSync,writeFileSync,existsSync,readdirSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[]
const verify=(name,value)=>{assert.ok(value,name);checks.push(name)}
const eventually=async(fn,tries=600)=>{for(let i=0;i<tries;i++){const value=await fn();if(value)return value;await sleep(50)}throw new Error('condition did not settle')}
const status=pid=>{try{return readFileSync(`/proc/${pid}/status`,'utf8')}catch{return ''}}
const field=(text,name)=>text.split('\n').find(l=>l.startsWith(name+':'))?.split(':')[1].trim()
const hostPid=()=>{
  for(const tid of readdirSync(`/proc/${process.ppid}/task`)){
    let kids=[];try{kids=readFileSync(`/proc/${process.ppid}/task/${tid}/children`,'utf8').trim().split(' ').filter(Boolean)}catch{}
    for(const pid of kids){try{if(readFileSync(`/proc/${pid}/cmdline`,'utf8').includes('ditto-hostd.mjs'))return Number(pid)}catch{}}
  }
}
const report=result=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(result))
try{
  const core=await connect()
  const canary=process.env.DITTO_G2_CANARY
  const session=await eventually(async()=>{const r=await core.call('agent.sessions.create',{title:'M1 plumbing',idempotency_key:'m1'});if(r.error?.data?.reason==='recovering')return false;if(r.error)throw new Error(JSON.stringify(r.error));return r.result})
  const findEntry=(value,pkg)=>{
    if(!value||typeof value!=='object')return
    if(value.package===pkg&&typeof value.entry_id==='string')return value
    for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
  }
  const focus=async()=>findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
  verify('focus rule starts off',!(await focus()))
  const settings=await core.must('agent.settings.describe')
  const {_meta,...preference}=settings
  await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...preference,enabled:true}})
  await core.must('agent.runtime.ensure')
  await eventually(async()=>{const r=await core.must('agent.runtime.get');if(r.phase==='failed')throw new Error('Agent failed: '+r.failure_reason);return r.phase==='ready'},400)
  const provider=await core.must('agent.providers.status',{provider:'codex-app-server'})
  verify('backend reachable through Core',provider.available===true&&provider.authenticated===true)
  const runtime=await core.must('agent.runtime.get')
  verify('Core verified isolation from its own launch',runtime.isolation_verified===true&&Number.isInteger(runtime.backend_pid))
  const backend=status(runtime.backend_pid)
  verify('backend is confined (seccomp filter, no_new_privs)',field(backend,'Seccomp')==='2'&&field(backend,'NoNewPrivs')==='1')
  verify('backend is the pinned app-server',readFileSync(`/proc/${runtime.backend_pid}/cmdline`,'utf8').split('\0').includes('app-server'))
  await core.must('desktop.events.subscribe',{topics:['conversations']})
  const turn=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'m1-message',text:`開啟通知專注模式 (${canary})`})
  const finished=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return ['succeeded','failed','cancelled','unknown','partial'].includes(t.state)?t:false},1200)
  if(finished.state!=='succeeded'){
    // Diagnostics for a failed run: Core's own records, not model claims.
    const events=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
    const changes=await core.must('desktop.changes.list',{})
    throw new Error('turn '+finished.state+'/'+finished.error_reason+' events='+JSON.stringify(events.events.map(e=>({type:e.type,data:e.data}))).slice(0,6000)+' changes='+JSON.stringify(changes.changes.slice(0,3).map(c=>({state:c.state,origin:c.origin}))))
  }
  verify('turn succeeded',true)
  verify('readback shows the change',await focus())
  const updates=core.events.map(e=>e.params.payload).filter(p=>p.type==='conversation_updated'&&p.session_id===session.session_id)
  verify('conversation events announce progress and the verified end',updates.some(p=>p.turn_state==='running')&&updates.some(p=>p.turn_state==='succeeded'))
  verify('conversation events carry no message text',!JSON.stringify(updates).includes(canary))
  const changes=await core.must('desktop.changes.list',{})
  const change=changes.changes.find(c=>c.origin?.kind==='agent'||c.origin?.agent||JSON.stringify(c.origin).includes(turn.turn_id))
  verify('change attributed to this Agent turn',!!change&&JSON.stringify(change.origin).includes(session.session_id))
  const events=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
  const types=events.events.map(e=>e.type)
  verify('conversation holds message, tool records and answer: '+JSON.stringify(types),types.includes('user/message')&&types.includes('assistant/message')&&types.some(t=>t.startsWith('tool/')))
  const answer=events.events.find(e=>e.type==='assistant/message')
  verify('answer stored by Core',answer?.data.text.includes('專注模式'))
  // A second turn in the same conversation: Core hands the Agent the
  // first change as a recent target (the runner checks the model saw it).
  const second=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'m1-follow',text:'follow-up: a little more'})
  await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:second.turn_id});return ['succeeded','failed','cancelled','unknown','partial'].includes(t.state)},1200)
  const undo=await core.must('desktop.changes.undo',{change_id:change.change_id,idempotency_key:'m1-undo'})
  verify('undo committed',['committed','succeeded'].includes(undo.state)||!!undo.committed_revision)
  verify('undo restores readback',!(await focus()))
  // Development PSS sample of the warm Agent group (D-44 input only; the
  // acceptance numbers come from the reference machine's cold logins).
  const pss=pid=>{try{return Number(readFileSync(`/proc/${pid}/smaps_rollup`,'utf8').match(/^Pss:\s+(\d+)/m)[1])}catch{return null}}
  const ppid=pid=>Number(field(status(pid),'PPid'))
  const supervisor=ppid(runtime.backend_pid)
  const kids=pid=>{try{return readFileSync(`/proc/${pid}/task/${pid}/children`,'utf8').trim().split(' ').filter(Boolean).map(Number)}catch{return []}}
  const group={controller:runtime.controller_pid,supervisor,app_server:runtime.backend_pid,...Object.fromEntries(kids(supervisor).filter(p=>p!==runtime.backend_pid).map((p,i)=>['proxy'+(i||''),p]))}
  const sample=Object.fromEntries(Object.entries(group).map(([k,p])=>[k,pss(p)]))
  sample.total_kib=Object.values(sample).reduce((a,b)=>a+(b??0),0)
  writeFileSync(process.env.DITTO_G2_TEST_OUT+'.pss',JSON.stringify(sample))
  const host=hostPid()
  await core.must('agent.runtime.stop')
  await eventually(async()=>(await core.must('agent.runtime.get')).phase==='stopped',300)
  await eventually(async()=>!existsSync(`/proc/${runtime.backend_pid}`)||field(status(runtime.backend_pid),'State')?.startsWith('Z'),200)
  verify('backend group gone after stop',!existsSync(`/proc/${runtime.backend_pid}`)||field(status(runtime.backend_pid),'State')?.startsWith('Z'))
  verify('desktop host survives Agent stop',!!host&&existsSync(`/proc/${host}`))
  report({ok:true,checks,change_id:change.change_id});core.close()
}catch(error){report({ok:false,checks,error:String(error)});process.exitCode=1}
