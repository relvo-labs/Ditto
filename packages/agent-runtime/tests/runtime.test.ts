import {it,expect} from 'vitest'
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
  await expect(runtime.request('agent.controller.provider.login',{provider:'codex-app-server'})).rejects.toThrow('backend_unsupported')
})
