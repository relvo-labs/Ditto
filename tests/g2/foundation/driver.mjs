import assert from 'node:assert/strict'
import {readFileSync,writeFileSync,existsSync,readdirSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[]
const verify=(name,value)=>{assert.ok(value,name);checks.push(name)}
const eventually=async(fn)=>{for(let i=0;i<600;i++){const value=await fn();if(value)return value;await sleep(50)}throw new Error('condition did not settle')}
const children=()=>[...new Set(readdirSync(`/proc/${process.ppid}/task`).flatMap(tid=>{try{return readFileSync(`/proc/${process.ppid}/task/${tid}/children`,'utf8').trim().split(' ').filter(Boolean).map(Number)}catch{return []}}))]
const hostPid=()=>children().find(pid=>{try{return readFileSync(`/proc/${pid}/cmdline`,'utf8').includes('ditto-hostd.mjs')}catch{return false}})
const report=result=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(result))
try{
  const core=await connect()
  const initial=await core.must('agent.runtime.get')
  verify('on-demand initial state',initial.installed&&initial.phase==='stopped'&&initial.controller_pid===null)
  const session=await eventually(async()=>{const response=await core.call('agent.sessions.create',{title:'foundation test',idempotency_key:'session-one'});if(response.error?.data?.reason==='recovering')return false;if(response.error)throw new Error(JSON.stringify(response.error));return response.result})
  verify('session creation is idempotent',(await core.must('agent.sessions.create',{title:'foundation test',idempotency_key:'session-one'})).session_id===session.session_id)
  const profile=await core.must('desktop.profiles.get')
  const settings=await core.must('agent.settings.describe')
  verify('AI defaults off',settings.enabled===false)
  const disabled=await core.call('agent.turns.submit',{session_id:session.session_id,client_message_id:'disabled',text:'ignored'})
  verify('disabled AI accepts no message',!!disabled.error&&(await core.must('agent.sessions.stat',{session_id:session.session_id})).next_seq===0)
  const {_meta,...preference}=settings
  await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...preference,enabled:true}})
  const turn=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'message-one',text:'move the dock left'})
  const repeat=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'message-one',text:'move the dock left'})
  verify('message acceptance is idempotent',repeat.turn_id===turn.turn_id)
  const finished=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return t.state==='failed'?t:false})
  verify(process.env.DITTO_G2_BOUNDARY_TEST?'unauthorized tools cannot be reported successful':'missing backend is reported honestly',finished.error_reason===(process.env.DITTO_G2_BOUNDARY_TEST?'tool_error':'backend_unsupported'))
  const runtime=await core.must('agent.runtime.get')
  verify('real controller uses production launcher identity',runtime.phase==='ready'&&runtime.controller_pid!==null&&runtime.isolation_verified===false)
  if(!process.env.DITTO_G2_BOUNDARY_TEST){
    const provider=await core.must('agent.providers.status',{provider:'codex-app-server'})
    verify('provider availability is explicit',provider.available===false&&provider.authenticated===false&&provider.models.length===0)
  }
  const login=await core.call('agent.providers.login',{provider:'codex-app-server'})
  verify('uninstalled backend cannot start login',login.error?.name==='unavailable')
  const catalog=await core.must('desktop.capabilities.list')
  verify('catalog reports unavailable login',catalog.capabilities.find(c=>c.capability_id==='agent.providers.login').availability.available===false)
  const events=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
  verify('no fabricated model answer',events.events.filter(e=>e.type==='user/message').length===1&&!events.events.some(e=>e.type==='assistant/message'))
  const host=await eventually(async()=>hostPid())
  await core.must('agent.runtime.stop')
  await eventually(async()=>(await core.must('agent.runtime.get')).phase==='stopped')
  verify('stopping Agent preserves desktop host',hostPid()===host&&existsSync(`/proc/${host}`))
  verify('desktop remains readable',(await core.must('desktop.profiles.get')).profile.head_revision===profile.profile.head_revision)
  await core.must('agent.sessions.delete',{session_id:session.session_id})
  verify('conversation deletion preserves configuration',(await core.must('desktop.profiles.get')).profile.head_revision===profile.profile.head_revision)
  report({ok:true,checks});core.close()
}catch(error){report({ok:false,checks,error:String(error)});process.exitCode=1}
