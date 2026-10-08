import {it,expect} from 'vitest'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import {CoreSessionHandle} from '../src/session.ts'

it('serializes writes, follows the Core cursor and makes close one-shot',async()=>{
  let next=4;const calls:string[]=[]
  const session=()=>({session_id:'ses-test',title:'chat',format_version:1,created_at:'2026-10-08T00:00:00Z',next_seq:next,durable_seq:next})
  const core:CoreChannel={async request<T>(method:string,params:Record<string,unknown>):Promise<T>{
    calls.push(method)
    if(method==='agent.sessions.open')return {session:session(),writer_lease:'lease'} as T
    if(method==='agent.sessions.stat')return session() as T
    if(method==='agent.sessions.append'){
      expect(params.expected_next_seq).toBe(next);expect(params.writer_lease).toBe('lease');next++;return session() as T
    }
    return session() as T
  }}
  const handle=await CoreSessionHandle.open(core,'ses-test')
  next++ // another accepted Core-owned user message
  await Promise.all([handle.append('assistant/message',{text:'a'}),handle.append('assistant/message',{text:'b'})])
  await handle.flush();const one=handle.close(),two=handle.close();expect(one).toBe(two);await two
  expect(calls.filter(c=>c==='agent.sessions.close')).toHaveLength(1)
  expect(next).toBe(7);await expect(handle.read()).rejects.toThrow('closed')
})

it('never retries an unknown append and still releases the writer on close',async()=>{
  const calls:string[]=[]
  const core:CoreChannel={async request<T>(method:string):Promise<T>{
    calls.push(method)
    if(method==='agent.sessions.open')return {session:{session_id:'ses-test',next_seq:0},writer_lease:'lease'} as T
    if(method==='agent.sessions.stat')return {next_seq:0} as T
    if(method==='agent.sessions.append')throw new Error('lost acknowledgement')
    return {} as T
  }}
  const handle=await CoreSessionHandle.open(core,'ses-test')
  await expect(handle.append('assistant/message',{text:'a'})).rejects.toThrow('lost acknowledgement')
  await expect(handle.append('assistant/message',{text:'b'})).rejects.toThrow('lost acknowledgement')
  await expect(handle.close()).rejects.toThrow('lost acknowledgement')
  expect(calls.filter(c=>c==='agent.sessions.append')).toHaveLength(1)
  expect(calls.filter(c=>c==='agent.sessions.close')).toHaveLength(1)
})
