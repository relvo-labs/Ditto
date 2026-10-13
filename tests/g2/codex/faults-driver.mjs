import {readFileSync,existsSync,writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[],facts={}
const verify=(name,value)=>{if(!value)throw new Error('check failed: '+name);checks.push(name)}
const eventually=async(fn,tries=300,ms=100)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const provider=()=>{try{return JSON.parse(readFileSync(process.env.DITTO_G2_PROVIDER_STATE,'utf8'))}catch{return {requests:0,hanging:0,closed:0}}}
const terminal=['succeeded','failed','cancelled','unknown','partial']
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
try{
  const core=await connect()
  await eventually(async()=>(await core.call('agent.sessions.create',{title:'probe',idempotency_key:'boot'})).error?.data?.reason!=='recovering')
  const s=await core.must('agent.settings.describe');const {_meta,...p}=s
  await core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,enabled:true}})
  await core.must('agent.runtime.ensure')
  verify('Agent ready',await eventually(async()=>(await core.must('agent.runtime.get')).phase==='ready'))
  const head=(await core.must('desktop.profiles.get')).profile.head_revision
  const session=await core.must('agent.sessions.create',{title:'faults',idempotency_key:'faults'})

  // ① stop while the model is still answering
  const first=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'stop-1',text:'take your time'})
  verify('model call in flight',await eventually(async()=>provider().hanging>0))
  const stopAt=Date.now()
  await core.must('agent.turns.cancel',{turn_id:first.turn_id})
  const stopped=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:first.turn_id});return terminal.includes(t.state)?t:false})
  facts.stop_ms=Date.now()-stopAt
  verify('stop ends the turn as cancelled: '+JSON.stringify(stopped),stopped&&stopped.state==='cancelled')
  verify('the model stream was closed by the backend',await eventually(async()=>provider().closed>=1&&provider().hanging===0,100))
  verify('a stop changes nothing on the desktop',(await core.must('desktop.profiles.get')).profile.head_revision===head)

  // ② the app-server dies mid-turn
  const before=await core.must('agent.runtime.get')
  const second=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'crash-1',text:'another slow one'})
  verify('second model call in flight',await eventually(async()=>provider().hanging>0))
  process.kill(before.backend_pid,'SIGKILL')
  const ended=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:second.turn_id});return terminal.includes(t.state)?t:false},300)
  facts.crash_turn=ended&&{state:ended.state,reason:ended.error_reason}
  verify('a backend crash ends the turn without success',ended&&ended.state!=='succeeded')
  const drained=await eventually(async()=>{const r=await core.must('agent.runtime.get');return r.phase==='stopped'?r:false},300)
  facts.after_crash=drained&&{failure:drained.failure_reason,isolation:drained.isolation_verified}
  verify('the whole Agent generation is gone after the crash',!!drained&&!existsSync(`/proc/${before.controller_pid}`)&&!drained.isolation_verified)
  verify('nothing changed on the desktop',(await core.must('desktop.profiles.get')).profile.head_revision===head)
  const events=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
  verify('no tool was dispatched in either turn',!events.events.some(e=>e.type==='tool/call'))
  // ③ the next request starts a fresh, again confined generation
  await core.must('agent.runtime.ensure')
  const again=await eventually(async()=>{const r=await core.must('agent.runtime.get');return r.phase==='ready'?r:false})
  verify('a new generation starts confined with a new backend',again&&again.generation>before.generation&&again.isolation_verified&&again.backend_pid!==before.backend_pid)
  // ④⑤⑥ the model service fails: an HTTP error, a cut connection, and a
  // model that outlives the turn's model-time budget. Each ends the turn
  // without success, dispatches nothing, and leaves the desktop alone.
  const mode=m=>writeFileSync(process.env.DITTO_G2_MODEL_MODE,m)
  const outage=async(name,key,setup)=>{
    await setup?.()
    const started=Date.now()
    const turn=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:key,text:name})
    const ended=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return terminal.includes(t.state)?t:false},1800)
    facts[name]=ended&&{state:ended.state,reason:ended.error_reason,ms:Date.now()-started,tools:ended.tool_calls}
    verify(`${name}: the turn ends without success and no tool ran`,ended&&ended.state!=='succeeded'&&ended.tool_calls===0)
    verify(`${name}: nothing changed on the desktop`,(await core.must('desktop.profiles.get')).profile.head_revision===head)
  }
  await outage('model_http_error','outage-500',()=>mode('error'))
  await outage('model_connection_cut','outage-drop',()=>mode('drop'))
  await outage('model_timeout','outage-slow',async()=>{
    mode('hang')
    const s=await core.must('agent.settings.describe');const {_meta,...p}=s
    await core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,turn_timeout_ms:3000}})
  })
  verify('an unavailable model service is reported as one, not as an interruption',facts.model_http_error?.reason==='provider_unavailable'&&facts.model_connection_cut?.reason==='provider_unavailable')
  verify('the model timeout is reported as one, within its budget',facts.model_timeout?.reason==='provider_timeout'&&facts.model_timeout.ms<15000)
  const events2=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:100})
  verify('no tool call was recorded in any failed turn',!events2.events.some(e=>e.type==='tool/call'))
  await core.must('agent.runtime.stop')
  report({ok:true,checks,facts});core.close()
}catch(error){report({ok:false,checks,facts,error:String(error)});process.exitCode=1}
