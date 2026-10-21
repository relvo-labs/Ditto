import {it,expect} from 'vitest'
import {toWireError} from '../../host-runtime/src/errors.ts'
import type {CodexBackend} from '../src/codex.ts'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import {AgentRuntime} from '../src/runtime.ts'

it('reports an unsupported backend without fabricated assistant output, drains handles and deduplicates hints',async()=>{
  const calls:string[]=[]
  let finished!:()=>void
  const completed=new Promise<void>(resolve=>{finished=resolve})
  const core:CoreChannel={async request<T>(method:string):Promise<T>{
    calls.push(method)
    if(method==='agent.turns.claim')return {turn:{session_id:'ses-one'},settings:{},message_seq:0,text:'user request'} as T
    if(method==='agent.sessions.open')return {session:{session_id:'ses-one',next_seq:1},writer_lease:'lease-one'} as T
    if(method==='agent.sessions.close')finished()
    return {} as T
  }}
  const runtime=new AgentRuntime(core);await runtime.start()
  runtime.notification('agent.controller.turn_available',{turn_ids:['turn-one','turn-one']})
  await completed;await runtime.stop()
  expect(calls.filter(c=>c==='agent.turns.claim')).toHaveLength(1)
  expect(calls).toContain('agent.turns.complete');expect(calls).not.toContain('agent.sessions.append')
  expect(await runtime.request('agent.controller.provider.status',{provider:'codex-app-server'})).toMatchObject({available:false,authenticated:false,models:[]})
  await expect(runtime.request('agent.controller.provider.login',{provider:'codex-app-server'})).rejects.toMatchObject({errorName:'unavailable',data:{reason:'system_unavailable',reason_code:'backend_unsupported'}})
})

it.each(['login','cancel_login','logout'])('no backend reports a wire reason for %s',async action=>{
  const runtime=new AgentRuntime({async request<T>(){return {} as T}})
  try{
    await runtime.request('agent.controller.provider.'+action,{provider:'codex-app-server',login_id:'fixture'})
    throw new Error('expected unavailable')
  }catch(error){
    expect(toWireError(error)).toMatchObject({name:'unavailable',code:-32007,data:{reason:'system_unavailable',reason_code:'backend_unsupported'}})
  }finally{await runtime.stop()}
})

it.each(['backend_unsupported','provider_unavailable','provider_timeout','rate_limited'])('provider errors carry a closed %s reason',async reason=>{
  const backend={startLogin:async()=>{throw new Error(reason)},interrupt:async()=>{},close:()=>{}} as unknown as CodexBackend
  const runtime=new AgentRuntime({async request<T>(){return {} as T}},backend)
  await expect(runtime.request('agent.controller.provider.login',{provider:'codex-app-server'})).rejects.toMatchObject({errorName:'unavailable',data:{reason:'system_unavailable',reason_code:reason}})
  await runtime.stop()
})
