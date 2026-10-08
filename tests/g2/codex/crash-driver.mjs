// Launched by Core in each life of tests/g2/codex/crash.mjs. First life:
// start an Agent turn whose ChangeSet kills Core at the fault point. Second
// life: the same Core store, read back what Core can prove about that call.
import assert from 'node:assert/strict'
import {writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[]
const verify=(name,value)=>{assert.ok(value,name);checks.push(name)}
const eventually=async(fn,tries=600)=>{for(let i=0;i<tries;i++){const value=await fn();if(value)return value;await sleep(50)}throw new Error('condition did not settle')}
const terminal=['succeeded','failed','cancelled','unknown','partial']
const report=result=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(result))
const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
}
try{
  const core=await connect()
  const session=await eventually(async()=>{const r=await core.call('agent.sessions.create',{title:'crash',idempotency_key:'crash'});if(r.error?.data?.reason==='recovering')return false;if(r.error)throw new Error(JSON.stringify(r.error));return r.result})
  const message={session_id:session.session_id,client_message_id:'crash-message',text:'crash: turn on focus'}
  if(process.env.DITTO_G2_PHASE==='first'){
    const settings=await core.must('agent.settings.describe')
    const {_meta,...preference}=settings
    await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...preference,enabled:true}})
    await core.must('agent.turns.submit',message)
    // Core ends at the fault point; this process goes with it.
    await sleep(120000)
    report({ok:false,error:'Core did not stop at the fault point'})
    process.exit(1)
  }
  // Second life. The same message key names the same turn: nothing new.
  const turn=await core.must('agent.turns.submit',message)
  verify('the interrupted turn is unknown, not resumed',turn.state==='unknown')
  const trace=await eventually(async()=>{const t=await core.must('agent.turns.trace',{turn_id:turn.turn_id});return t.tools.some(x=>x.capability_id==='desktop.changes.propose'&&x.outcome!=='pending')?t:false},400)
  const tool=trace.tools.find(x=>x.capability_id==='desktop.changes.propose')
  verify('boot recovery settled the lost call',tool.recovered===true)
  const change=await core.must('desktop.changes.get',{operation_id:tool.intent_id})
  verify('the trace names the ChangeSet its operation id produced',tool.change_id===change.change_id&&tool.change_state===change.state)
  const expected=change.state==='committed'?'returned':['unknown','partially_applied'].includes(change.state)?'unknown':'failed'
  verify(`outcome ${tool.outcome} follows the change (${change.state})`,tool.outcome===expected)
  verify('a committed change carries its revision',change.state!=='committed'||tool.committed_revision===change.committed_revision)
  const focus=findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
  verify('the desktop matches what the trace says',focus===(change.state==='committed'))
  const before=(await core.must('desktop.changes.list',{})).changes.length
  const follow=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'crash-follow',text:'follow-up after the crash'})
  const done=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:follow.turn_id});return terminal.includes(t.state)?t:false},1200)
  verify('a new Agent generation answers the next message',done.state==='succeeded')
  const after=(await core.must('desktop.changes.list',{})).changes.length
  verify('no ChangeSet was made again',after===before)
  report({ok:true,checks,change_state:change.state,outcome:tool.outcome,intent_id:tool.intent_id})
  process.exit(0)
}catch(error){report({ok:false,checks,error:String(error?.stack??error)});process.exit(1)}
