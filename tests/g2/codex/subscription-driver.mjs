// Inside Core: enable AI, sign in if needed (the person does it in a
// browser), run one real-model turn, verify through Core, undo.
import {writeFileSync,readFileSync,existsSync,readdirSync} from 'node:fs'
import {join} from 'node:path'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[],facts={}
const verify=(name,value)=>{if(!value)throw new Error('check failed: '+name);checks.push(name)}
const eventually=async(fn,tries,ms=200)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const f=findEntry(child,pkg);if(f)return f}
}
try{
  const core=await connect()
  // Boot recovery refuses writes until it settles; wait for a write to pass.
  await eventually(async()=>(await core.call('agent.sessions.list',{})).error?.data?.reason!=='recovering'&&(await core.call('desktop.changes.list',{})).error?.data?.reason!=='recovering'&&(await core.call('agent.sessions.create',{title:'probe',idempotency_key:'boot-probe'})).error?.data?.reason!=='recovering',300)
  let settings=await core.must('agent.settings.describe')
  if(!settings.enabled){const {_meta,...s}=settings;settings=await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...s,enabled:true}})}
  await core.must('agent.runtime.ensure')
  verify('Agent ready',await eventually(async()=>(await core.must('agent.runtime.get')).phase==='ready',150))
  const runtime=await core.must('agent.runtime.get')
  verify('backend confined by Core',runtime.isolation_verified===true)
  let status=await core.must('agent.providers.status',{provider:'codex-app-server'})
  if(!status.authenticated){
    const login=await core.must('agent.providers.login',{provider:'codex-app-server'})
    writeFileSync(process.env.DITTO_G2_LOGIN_FILE,JSON.stringify({auth_url:login.auth_url}))
    status=await eventually(async()=>{const s=await core.must('agent.providers.status',{provider:'codex-app-server'});return s.authenticated?s:false},Math.ceil(Number(process.env.DITTO_G2_LOGIN_WAIT_MIN??15)*20),3000)
    verify('signed in through the browser',!!status)
    checks.push('sign-in performed this run')
  }else checks.push('sign-in reused from the keyring')
  facts.models=status.models.map(m=>m.id)
  facts.quota=status.rate_limits
  // No credential file: the token went to the Secret Service, not to disk.
  const codexHome=join(process.env.DITTO_DATA_DIR,'state/agent/backend/codex')
  verify('no plaintext credential file',!existsSync(join(codexHome,'auth.json')))
  const preferred=['gpt-6.1-sol','gpt-6-sol','gpt-5.6-sol'].find(id=>facts.models.includes(id))??facts.models[0]
  const model=status.models.find(m=>m.id===preferred)
  if(settings.model!==preferred){
    const {_meta,...s}=settings
    settings=await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...s,model:preferred,reasoning_effort:model.reasoning_efforts.includes('low')?'low':model.default_effort}})
  }
  facts.model=preferred;facts.effort=settings.reasoning_effort
  const profile=await core.must('desktop.profiles.get')
  const before=findEntry(profile,'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
  const session=await core.must('agent.sessions.create',{title:'M1 real subscription',idempotency_key:'m1-real-'+Date.now()})
  const text=before?'請關閉通知的專注模式，其他設定不要改。':'請幫我開啟通知的專注模式，其他設定不要改。'
  const started=Date.now()
  const turn=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'m1-real-'+Date.now(),text})
  const done=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return ['succeeded','failed','cancelled','unknown','partial'].includes(t.state)?t:false},600,500)
  facts.turn_seconds=Math.round((Date.now()-started)/100)/10
  const events=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
  facts.events=events.events.map(e=>e.type==='tool/call'?'tool/call '+e.data.capability_id:e.type)
  facts.answer=events.events.find(e=>e.type==='assistant/message')?.data.text
  facts.usage=events.events.find(e=>e.type==='assistant/message')?.data.usage
  facts.turn={state:done&&done.state,reason:done&&done.error_reason}
  verify('real model turn succeeded',done&&done.state==='succeeded')
  const after=findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
  verify('Core reads the requested setting back',after===!before)
  const changes=(await core.must('desktop.changes.list',{})).changes.filter(c=>JSON.stringify(c.origin).includes(turn.turn_id))
  verify('one Agent-attributed committed change',changes.length>=1&&changes.every(c=>c.state==='committed'))
  facts.change_ids=changes.map(c=>c.change_id)
  for(const c of changes.reverse())await core.must('desktop.changes.undo',{change_id:c.change_id,idempotency_key:'undo-'+c.change_id})
  const restored=findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
  verify('undo restores the setting',restored===before)
  await core.must('agent.runtime.stop')
  report({ok:true,checks,facts});core.close()
}catch(error){report({ok:false,checks,facts,error:String(error)});process.exitCode=1}
