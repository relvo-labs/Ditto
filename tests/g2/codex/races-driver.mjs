// Launched by Core for tests/g2/codex/races.mjs: plays the person between
// the scripted model's steps, then reads back what Core holds.
import assert from 'node:assert/strict'
import {existsSync,writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[],facts={}
const verify=(name,value)=>{assert.ok(value,name);checks.push(name)}
const eventually=async(fn,tries=600)=>{for(let i=0;i<tries;i++){const value=await fn();if(value)return value;await sleep(50)}throw new Error('condition did not settle')}
const terminal=['succeeded','failed','cancelled','unknown','partial']
const sync=process.env.DITTO_G2_SYNC
const reached=name=>eventually(()=>existsSync(`${sync}/at-${name}`),1200)
const go=name=>writeFileSync(`${sync}/go-${name}`,'')
const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
}
try{
  const core=await connect()
  const session=await eventually(async()=>{const r=await core.call('agent.sessions.create',{title:'races',idempotency_key:'races'});if(r.error?.data?.reason==='recovering')return false;if(r.error)throw new Error(JSON.stringify(r.error));return r.result})
  const enable=async on=>{const s=await core.must('agent.settings.describe');const {_meta,...p}=s;return core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,enabled:on}})}
  await enable(true)
  const finish=async turn=>eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return terminal.includes(t.state)?t:false},1200)
  const tool=(trace,call)=>trace.tools.find(t=>t.call_id.endsWith(call)||t.call_id===call)
  const policy=async()=>findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')

  // A. The person commits on the same entry while the Agent holds an old base.
  const a=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'race-base',text:'race-base'})
  await reached('base')
  const entry=await policy()
  const profile=await core.must('desktop.profiles.get')
  const person={...(entry.config??{}),rules:{...(entry.config?.rules??{}),focus:{enabled:false,allow:['person']}}}
  const mine=await core.must('desktop.changes.propose',{base_revision:profile.profile.head_revision,ops:[{op:'set_entry_config',entry_id:entry.entry_id,after:person}]})
  verify('the person\'s change committed while the Agent waited',mine.state==='committed')
  go('base')
  const ta=await finish(a)
  const traceA=await core.must('agent.turns.trace',{turn_id:a.turn_id})
  const proposeA=traceA.tools.find(t=>t.capability_id==='desktop.changes.propose')
  facts.stale_base={turn:ta.state,outcome:proposeA?.outcome,change_state:proposeA?.change_state??null}
  verify('the Agent\'s change on the old base did not commit',proposeA&&proposeA.change_state!=='committed')
  const after=(await policy()).config?.rules?.focus
  verify('the person\'s value is still there',JSON.stringify(after?.allow)==='["person"]'&&after?.enabled===false)

  // B. A standing grant is revoked between two reads.
  const grant=await core.must('desktop.permissions.grant',{subject:'agent',scope:'desktop.windows.read',idempotency_key:'race-grant'})
  const b=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'race-grant',text:'race-grant'})
  await reached('grant')
  await core.must('desktop.permissions.revoke',{grant_id:grant.grant_id})
  go('grant')
  await finish(b)
  const traceB=await core.must('agent.turns.trace',{turn_id:b.turn_id})
  const lists=traceB.tools.filter(t=>t.capability_id==='desktop.windows.list')
  facts.revoked_grant=lists.map(t=>t.outcome)
  verify('the read under the grant ran',lists[0]?.outcome==='returned')
  verify('after the revoke the same read did not run on the old grant',lists.length===1||lists[1].outcome!=='returned')

  // C. AI is turned off between the Agent's read and its write.
  const before=(await core.must('desktop.changes.list',{})).changes.length
  const c=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'race-disable',text:'race-disable'})
  await reached('disable')
  await enable(false)
  go('disable')
  const tc=await finish(c)
  const traceC=await core.must('agent.turns.trace',{turn_id:c.turn_id})
  const proposeC=traceC.tools.find(t=>t.capability_id==='desktop.changes.propose')
  facts.disabled={turn:tc.state,propose:proposeC?.outcome??'never reserved'}
  verify('with AI off the Agent made no change',(await core.must('desktop.changes.list',{})).changes.length===before)
  verify('the turn did not succeed as if it had',tc.state!=='succeeded'||!proposeC||proposeC.outcome!=='returned')
  writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify({ok:true,checks,facts}))
  process.exit(0)
}catch(error){writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify({ok:false,checks,facts,error:String(error?.stack??error)}));process.exit(1)}
