// An adversarial controller with genuine launcher identity. It cannot
// self-attest isolation, manage user preferences or bypass tool correlation.
import assert from 'node:assert/strict'
import {connect,sleep} from '../../g1/lib/core-client.mjs'
const core=await connect()
// A self-attested backend or isolation claim is not even well-formed input.
const claimed=await core.call('agent.runtime.ready',{backend_pid:null,isolation_verified:true})
assert.equal(claimed.error?.name,'invalid_params')
const ready=await core.must('agent.runtime.ready',{})
assert.equal(ready.isolation_verified,false)
const forbidden=await core.call('agent.settings.patch',{})
assert.equal(forbidden.error?.name,'permission_denied')
let turnId
for(let i=0;i<200&&!turnId;i++){
  const event=core.notifications.find(e=>e.method==='agent.controller.turn_available')
  turnId=event?.params.turn_id??event?.params.turn_ids?.[0]
  if(!turnId)await sleep(20)
}
assert.ok(turnId,'accepted turn notification')
await core.must('agent.turns.claim',{turn_id:turnId})
const read=await core.must('agent.tools.intent',{turn_id:turnId,tool_call_id:'profile-read',capability_id:'desktop.profiles.get',arguments:{}})
const profile=await core.must('desktop.profiles.get',{}, {operation_id:read.intent_id})
const args={base_revision:profile.profile.head_revision,tokens:{accent:'#000000'}}
const intent=await core.must('agent.tools.intent',{turn_id:turnId,tool_call_id:'forbidden-write',capability_id:'desktop.appearance.set',arguments:args})
const response=await core.call('desktop.appearance.set',args,{operation_id:intent.intent_id})
assert.equal(response.error?.name,'permission_denied')
assert.equal(response.error?.data?.reason,'policy_denied')
await core.must('agent.tools.abandon',{intent_id:intent.intent_id,reason:'permission_denied'})
const completed=await core.must('agent.turns.complete',{turn_id:turnId,state:'succeeded',error_reason:null})
assert.equal(completed.state,'failed')
// Wait for manager's stop rather than exiting spontaneously during readback.
for(let i=0;i<500;i++){
  if(core.notifications.some(e=>e.method==='agent.controller.stop')){core.close();break}
  await sleep(20)
}
