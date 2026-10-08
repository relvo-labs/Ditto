import {writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'
const checks=[]
const verify=(n,v)=>{if(!v)throw new Error('check failed: '+n);checks.push(n)}
const eventually=async(fn,tries=600,ms=100)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
const terminal=['succeeded','failed','cancelled','unknown','partial']
const findEntry=(value,pkg)=>{if(!value||typeof value!=='object')return;if(value.package===pkg&&typeof value.entry_id==='string')return value;for(const c of Object.values(value)){const f=findEntry(c,pkg);if(f)return f}}
const focus=async core=>findEntry(await core.must('desktop.profiles.get'),'ditto.svc.notification-policy')?.config?.rules?.focus?.enabled===true
let reference
try{
  const core=await connect()
  await eventually(async()=>(await core.call('agent.sessions.create',{title:'probe',idempotency_key:'boot'})).error?.data?.reason!=='recovering')
  const created=await core.must('agent.credentials.create',{provider:'direct-model',secret:process.env.DITTO_G2_KEY,idempotency_key:'direct-test-'+process.pid})
  reference=created.credential_ref
  verify('the key went to the keyring; Core answers with a reference only',created.available&&reference.startsWith('cred-')&&!JSON.stringify(created).includes(process.env.DITTO_G2_KEY))
  const s=await core.must('agent.settings.describe');const {_meta,...p}=s
  const plaintext=await core.call('agent.settings.patch',{expected_revision:s.revision,settings:{...p,provider:'direct-model',endpoint:'http://example.com/v1',auth:{kind:'api_key',credential_ref:reference},enabled:true}})
  verify('a plain-HTTP remote endpoint is refused',plaintext.error?.name==='invalid_params')
  const settings=await core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,provider:'direct-model',endpoint:process.env.DITTO_G2_ENDPOINT,auth:{kind:'api_key',credential_ref:reference},enabled:true}})
  verify('settings hold the reference, not the key',!JSON.stringify(settings).includes(process.env.DITTO_G2_KEY))
  const resolveByCli=await core.call('agent.credentials.resolve',{turn_id:'turn-x'})
  verify('no one but the Agent may resolve a key',resolveByCli.error?.name==='permission_denied'||resolveByCli.error?.name==='identity_rejected')
  const session=await core.must('agent.sessions.create',{title:'direct',idempotency_key:'direct'})
  const turn=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'d1',text:'開啟通知專注模式'})
  const done=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn.turn_id});return terminal.includes(t.state)?t:false},1200)
  verify('the direct-model turn succeeded: '+JSON.stringify(done&&{s:done.state,r:done.error_reason}),done&&done.state==='succeeded')
  verify('Core reads the change back',await focus(core))
  const page=await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:50})
  verify('model selection names the direct backend',page.events.some(e=>e.type==='model/selection'&&e.data.provider==='direct-model'))
  const exported=await core.call('desktop.profiles.export',{})
  verify('a Profile export carries no key',!JSON.stringify(exported).includes(process.env.DITTO_G2_KEY))
  // Delete the key: the next turn fails honestly; nothing falls back.
  const gone=await core.must('agent.credentials.delete',{credential_ref:reference})
  verify('deleting the key leaves it missing',gone.available===false&&gone.reason==='missing')
  const turn2=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'d2',text:'再一次'})
  const failed=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:turn2.turn_id});return terminal.includes(t.state)?t:false},600)
  verify('without its key the turn fails, nothing falls back: '+JSON.stringify(failed&&{s:failed.state,r:failed.error_reason}),failed&&failed.state==='failed'&&failed.error_reason==='provider_unavailable')
  await core.must('agent.runtime.stop')
  report({ok:true,checks});core.close()
}catch(error){
  report({ok:false,checks,error:String(error)});process.exitCode=1
}
