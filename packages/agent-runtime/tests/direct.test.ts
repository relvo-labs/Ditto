import {describe,it,expect,vi} from 'vitest'
import {DirectModelBackend,MAX_MODEL_CALLS} from '../src/direct.ts'
import type {AgentPreferences} from '../../protocol/src/generated/agent-preferences.ts'

const settings:AgentPreferences={revision:1,enabled:true,provider:'direct-model',model:'m',reasoning_effort:null,max_tool_calls:24,turn_timeout_ms:5000,retain_conversations:true,approval_mode:'ask',endpoint:'https://api.example/v1'}
const core={request:vi.fn(async(method:string)=>{if(method==='agent.credentials.resolve')return {secret:'sk-canary',endpoint:'https://api.example/v1'};throw new Error('unexpected')})} as never
const sse=(items:unknown[])=>new Response([...items.map(item=>`event: x\ndata: ${JSON.stringify({type:'response.output_item.done',item})}\n\n`),`data: ${JSON.stringify({type:'response.completed',response:{usage:{input_tokens:3,output_tokens:2}}})}\n\n`].join(''),{status:200,headers:{'content-type':'text/event-stream'}})
const tool={type:'function' as const,name:'desktop__profiles__get',description:'read',inputSchema:{type:'object'}}

describe('direct-model backend',()=>{
  it('runs tools through Ditto and sends the key only to the configured endpoint',async()=>{
    const calls:Array<{url:string;init:RequestInit}>=[]
    const fetcher=vi.fn(async(url:string,init:RequestInit)=>{
      calls.push({url,init})
      return calls.length===1?sse([{type:'function_call',name:'desktop__profiles__get',arguments:'{}',call_id:'c1'}]):sse([{type:'message',role:'assistant',content:[{type:'output_text',text:'完成'}]}])
    })
    const execute=vi.fn(async()=>({contentItems:[{type:'inputText' as const,text:'{"profile":{}}'}],success:true}))
    const result=await new DirectModelBackend(core,fetcher as never).run('turn-1','hi','',settings,[tool],execute,new AbortController().signal)
    expect(result.text).toBe('完成');expect(result.usage).toEqual({inputTokens:6,outputTokens:4})
    expect(execute).toHaveBeenCalledWith('c1','desktop__profiles__get',{})
    expect(calls.every(c=>c.url==='https://api.example/v1/responses'&&c.init.redirect==='manual')).toBe(true)
    expect((calls[0]!.init.headers as Record<string,string>).authorization).toBe('Bearer sk-canary')
    const second=JSON.parse(String(calls[1]!.init.body))
    expect(second.input.some((i:{type:string;call_id?:string})=>i.type==='function_call_output'&&i.call_id==='c1')).toBe(true)
  })
  it('treats a redirect, a refusal or exhausted quota as a failed provider, never as success',async()=>{
    for(const [status,reason] of [[302,'provider_unavailable'],[401,'provider_unavailable'],[429,'rate_limited']] as const){
      const fetcher=vi.fn(async()=>new Response('',{status,headers:status===302?{location:'https://evil.example/'}:{}}))
      await expect(new DirectModelBackend(core,fetcher as never).run('t','hi','',settings,[tool],vi.fn(),new AbortController().signal)).rejects.toThrow(reason)
      expect(fetcher).toHaveBeenCalledTimes(1)
    }
  })
  it('stops after a bounded number of model calls',async()=>{
    let n=0
    const fetcher=vi.fn(async()=>sse([{type:'function_call',name:'desktop__profiles__get',arguments:'{}',call_id:'c'+(++n)}]))
    const execute=vi.fn(async()=>({contentItems:[{type:'inputText' as const,text:'{}'}],success:true}))
    await new DirectModelBackend(core,fetcher as never).run('t','loop','',settings,[tool],execute,new AbortController().signal)
    expect(fetcher).toHaveBeenCalledTimes(MAX_MODEL_CALLS)
  })
})
