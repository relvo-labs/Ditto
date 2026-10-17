import {execFileSync as sourceExec} from 'node:child_process'
import {createConnection} from 'node:net'
import {writeFileSync} from 'node:fs'
const checks=[],facts={source:JSON.parse(sourceExec("python3",["tests/g3/source.py"]))},sleep=ms=>new Promise(r=>setTimeout(r,ms))
const call=(method,params={})=>new Promise((resolve,reject)=>{const socket=createConnection(process.env.DITTO_G1_RELAY),timer=setTimeout(()=>{socket.destroy();reject(new Error('relay timeout'))},60000);let buffer='';socket.on('connect',()=>socket.write(JSON.stringify({method,params})+'\n'));socket.on('error',reject);socket.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timer);socket.destroy();resolve(JSON.parse(buffer.split('\n')[0]))}})})
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw new Error(method+': '+JSON.stringify(r.error));return r.result}
const verify=(name,yes)=>{if(!yes)throw new Error(name);checks.push(name);console.log('PASS '+name)}
const eventually=async(fn)=>{for(let i=0;i<600;i++){const v=await fn();if(v)return v;await sleep(200)}throw new Error('condition timed out')}
try{
 const s=await must('agent.settings.describe');const {_meta,...settings}=s
 await must('agent.settings.patch',{expected_revision:s.revision,settings:{...settings,enabled:true,max_tool_calls:24,approval_mode:'never'}})
 await must('agent.runtime.ensure');await eventually(async()=>(await must('agent.runtime.get')).phase==='ready')
 const session=await must('agent.sessions.create',{title:'G3 scripted generation',idempotency_key:'g3-agent-test'})
 async function turn(text){
  const t=await must('agent.turns.submit',{session_id:session.session_id,client_message_id:text,text})
  const approvals=[]
  const done=await eventually(async()=>{
   const d=await must('agent.turns.get',{turn_id:t.turn_id})
   if(['succeeded','failed','partial','cancelled','unknown'].includes(d.state))return d
   const pending=(await must('desktop.approvals.list')).approvals
   for(const approval of pending.filter(a=>a.request?.turn_id===t.turn_id&&!a.decision)){
    // This fixture person approves only this first activation. Core binds
    // the receipt to this turn, capability and exact intent hash.
    if(text!=='g3-tasks'||approval.request.capability_id!=='desktop.plugins.development.activate')throw new Error('unexpected approval: '+JSON.stringify(approval))
    await must('desktop.approvals.decide',{request_id:approval.request_id,decision:'allowed-once',intent_hash:approval.request.intent_hash})
    approvals.push({request_id:approval.request_id,capability:approval.request.capability_id,decision:'allowed-once'})
   }
   return false
  })
  const trace=await must('agent.turns.trace',{turn_id:t.turn_id});facts[text]={turn:done,tools:trace.tools}
  facts[text].approvals=approvals
  verify(text+' turn outcome follows Core',text==='g3-denied'?done.state==='failed':done.state==='succeeded');return t
 }
 await turn('g3-denied')
 verify('denied generation reaches the shared Core authorization path',facts['g3-denied'].tools.some(t=>t.capability_id==='desktop.plugins.development.create'))
 verify('ungranted generation is refused before artifact creation',(await must('desktop.plugins.development.list')).artifacts.length===0)
 for(const scope of ['plugins.develop','desktop.windows.read'])await must('desktop.permissions.grant',{subject:'agent',scope,idempotency_key:'g3-'+scope})
 const beforeAsk=await must('agent.settings.describe');const {_meta:askMeta,...askSettings}=beforeAsk
 await must('agent.settings.patch',{expected_revision:beforeAsk.revision,settings:{...askSettings,approval_mode:'ask'}})
 const tasksTurn=await turn('g3-tasks')
 verify('activation consumes a genuine one-shot approval',facts['g3-tasks'].approvals.length===1)
 verify('one-shot approval does not create a permanent data grant',!(await must('desktop.permissions.list',{subject:'agent'})).grants.some(g=>g.scope==='plugins.data'&&!g.revoked_at))
 await must('desktop.permissions.grant',{subject:'agent',scope:'plugins.data',idempotency_key:'g3-plugins.data'})
 let artifacts=(await must('desktop.plugins.development.list')).artifacts
 const original=artifacts.find(a=>a.description.plugin_id==='local.generated.scripted_tasks')
 verify('Agent source is bound to actual turn',original?.origin.turn_id===tasksTurn.turn_id)
 verify('Agent-generated tasks passed real native validation and activation',original.state==='active'&&original.validation.boundary.enforcement==='full')
 await turn('g3-workspaces')
 const originalWorkspace=(await must('desktop.plugins.development.list')).artifacts.find(a=>a.description.plugin_id==='local.generated.scripted_workspaces')
 await turn('g3-modify')
 await turn('g3-workspaces-modify')
 artifacts=(await must('desktop.plugins.development.list')).artifacts
 const updated=artifacts.find(a=>a.parent_id===original.artifact_id)
 verify('follow-up creates validated new version',updated?.state==='active'&&updated.description.width===380&&updated.description.content.max_items===2)
 const workspaceUpdate=artifacts.find(a=>a.parent_id===originalWorkspace.artifact_id);verify('workspace follow-up creates a new validated version',workspaceUpdate?.state==='active'&&workspaceUpdate.description.width===340);
 verify('original version remains immutable',(await must('desktop.plugins.development.get',{artifact_id:original.artifact_id})).description.width===320)
 const profile=(await must('desktop.profiles.get')).document
 verify('both generated kinds are enabled in actual Profile',profile.entries.some(e=>e.package==='local.generated.scripted_tasks'&&e.version==='1.1.0'&&!e.disabled)&&profile.entries.some(e=>e.package==='local.generated.scripted_workspaces'&&e.version==='1.1.0'&&!e.disabled))
 await must('agent.sessions.delete',{session_id:session.session_id})
 verify('conversation deletion redacts durable generation source',(await must('desktop.plugins.development.get',{artifact_id:original.artifact_id})).origin.request_summary==='來源對話已刪除')
 await must('agent.runtime.stop');verify('desktop remains after Agent exits',(await must('desktop.plugins.list')).entries.filter(e=>e.package.startsWith('local.generated.')&&e.state.kind==='active').length===2)
 writeFileSync(process.env.DITTO_G3_AGENT_OUT,JSON.stringify({ok:true,evidence_class:'development-headless-scripted-model',checks,facts},null,2))
}catch(error){writeFileSync(process.env.DITTO_G3_AGENT_OUT,JSON.stringify({ok:false,checks,facts,error:String(error)},null,2));console.error(error);process.exitCode=1}
