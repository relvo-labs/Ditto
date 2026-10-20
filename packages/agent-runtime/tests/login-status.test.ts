import {afterEach,describe,expect,it,vi} from 'vitest'
import {CodexBackend,type BackendTransport} from '../src/codex.ts'
import {AgentRuntime} from '../src/runtime.ts'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import type {AgentPreferences} from '../../protocol/src/generated/agent-preferences.ts'

// Synthetic seam fixtures, shaped from openai/codex rust-v0.160.0's
// account_processor.rs and generated protocol. No live auth or credentials.
class LoginPeer implements BackendTransport {
  onNotification=(_method:string,_params:unknown)=>{}
  onRequest=async(_method:string,_params:unknown):Promise<unknown>=>undefined
  onClosed=(_error:Error)=>{}
  calls:string[]=[]
  account:unknown=null
  failure?:string
  malformed?:string
  logins=0
  async request<T>(method:string,_params:unknown):Promise<T>{
    this.calls.push(method)
    if(method===this.failure)throw new Error('synthetic provider failure')
    if(method===this.malformed)return {} as T
    let result:unknown={}
    if(method==='account/read')result={account:this.account,requiresOpenaiAuth:true}
    if(method==='model/list')result={data:[{id:'fixture-model',model:'fixture-model',displayName:'Fixture',supportedReasoningEfforts:[]}],nextCursor:null}
    if(method==='account/rateLimits/read')result={rateLimits:{primary:{usedPercent:20},secondary:null}}
    if(method==='account/login/start')result={type:'chatgptDeviceCode',loginId:`fixture-login-${++this.logins}`,verificationUrl:'https://auth.openai.com/codex/device',userCode:'TEST-ONLY'}
    if(method==='account/login/cancel')result={status:'canceled'}
    return result as T
  }
  notify():void{}
  close():void{this.onClosed(new Error('synthetic disconnect'))}
  complete(loginId:string,success:boolean):void{
    this.onNotification('account/login/completed',{loginId,success,error:success?null:'synthetic failure'})
  }
}
const core:CoreChannel={async request<T>():Promise<T>{throw new Error('unexpected Core write')}}
const settings:AgentPreferences={revision:1,enabled:true,provider:'codex-app-server',model:'fixture-model',reasoning_effort:null,max_tool_calls:24,turn_timeout_ms:1000,retain_conversations:true}
const subscription={type:'chatgpt',email:'fixture@example.invalid',planType:'plus'}
const status=(runtime:AgentRuntime)=>runtime.request('agent.controller.provider.status',{provider:'codex-app-server'})

afterEach(()=>vi.useRealTimers())
describe('device login account readback through the controller seam',()=>{
  it.each(['model/list','account/rateLimits/read'])('keeps confirmed login when %s fails, then refreshes missing details',async method=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),runtime=new AgentRuntime(core,backend)
    const login=await backend.startLogin()
    expect(await status(runtime)).toMatchObject({authenticated:false})
    peer.account=subscription;peer.complete(login.login_id,true);peer.failure=method
    await expect(status(runtime)).resolves.toMatchObject({available:true,authenticated:true,
      ...(method==='model/list'?{models:[]}:{rate_limits:null})})
    peer.failure=undefined
    await expect(status(runtime)).resolves.toMatchObject({authenticated:true,models:[{id:'fixture-model'}],rate_limits:{primary:{used_percent:20}}})
    expect(peer.calls.filter(m=>m==='account/login/start')).toHaveLength(1)
    expect(peer.calls).not.toContain('account/logout')
    await runtime.stop()
  })
  it.each(['model/list','account/rateLimits/read'])('treats malformed %s as unknown details without losing identity',async method=>{
    const peer=new LoginPeer();peer.account=subscription;peer.malformed=method
    const runtime=new AgentRuntime(core,new CodexBackend(peer))
    await expect(status(runtime)).resolves.toMatchObject({authenticated:true,
      ...(method==='model/list'?{models:[]}:{rate_limits:null})})
    await runtime.stop()
  })
  it.each([true,false])('does not infer identity from completion success=%s',async success=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),runtime=new AgentRuntime(core,backend)
    const login=await backend.startLogin();peer.complete(login.login_id,success)
    await expect(status(runtime)).resolves.toMatchObject({authenticated:false,account_label:null})
    peer.account=subscription;peer.failure='account/read'
    await expect(status(runtime)).rejects.toThrow('synthetic provider failure') // unknown, not logged out or authenticated
    peer.failure=undefined
    await expect(status(runtime)).resolves.toMatchObject({authenticated:true})
    await runtime.stop()
  })
  it('preserves an existing session after a failed replacement login',async()=>{
    const peer=new LoginPeer();peer.account=subscription
    const backend=new CodexBackend(peer),login=await backend.startLogin();peer.complete(login.login_id,false)
    expect((await backend.status()).authenticated).toBe(true)
    expect(peer.calls).not.toContain('account/logout')
  })
  it('keeps a malformed account read unknown instead of confirming sign-out',async()=>{
    const peer=new LoginPeer();peer.malformed='account/read'
    await expect(new CodexBackend(peer).status()).rejects.toThrow('invalid provider value')
  })
  it('rejects account readback from a connection lost during auxiliary reads',async()=>{
    const peer=new LoginPeer();peer.account=subscription
    const original=peer.request.bind(peer)
    peer.request=async<T>(method:string,params:unknown)=>{
      if(method==='model/list'){peer.close();throw new Error('synthetic disconnect')}
      return original<T>(method,params)
    }
    await expect(new CodexBackend(peer).status()).rejects.toThrow('provider_unavailable')
  })
  it('cancels only the matching attempt and ignores a stale completion for the next one',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),login=await backend.startLogin()
    expect(await backend.cancelLogin('stale')).toEqual({completed:false})
    expect(await backend.cancelLogin(login.login_id)).toEqual({completed:true})
    const next=await backend.startLogin();peer.complete(login.login_id,true)
    expect(await backend.startLogin()).toBe(next)
    expect((await backend.status()).authenticated).toBe(false)
  })
  it('does not let a late cancellation acknowledgement clear a newer attempt',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),first=await backend.startLogin()
    const original=peer.request.bind(peer)
    let acknowledge!:(value:unknown)=>void
    peer.request=<T>(method:string,params:unknown)=>method==='account/login/cancel'
      ?new Promise<T>(resolve=>{acknowledge=value=>resolve(value as T)}):original<T>(method,params)
    const cancellation=backend.cancelLogin(first.login_id)
    peer.complete(first.login_id,false)
    const next=await backend.startLogin()
    acknowledge({status:'canceled'});await cancellation
    expect(await backend.startLogin()).toBe(next)
  })
  it('does not report upstream notFound as a confirmed cancellation',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),login=await backend.startLogin(),original=peer.request.bind(peer)
    peer.request=async<T>(method:string,params:unknown)=>method==='account/login/cancel'?{status:'notFound'} as T:original<T>(method,params)
    expect(await backend.cancelLogin(login.login_id)).toEqual({completed:false})
    expect((await backend.status()).authenticated).toBe(false)
  })
  it('keeps a malformed cancellation acknowledgement unknown',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),login=await backend.startLogin(),original=peer.request.bind(peer)
    peer.request=async<T>(method:string,params:unknown)=>method==='account/login/cancel'?{} as T:original<T>(method,params)
    await expect(backend.cancelLogin(login.login_id)).rejects.toThrow('invalid login cancellation')
  })
  it('rejects a login response after the backend connection was lost',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),original=peer.request.bind(peer)
    let reply!:(value:unknown)=>void
    peer.request=<T>(method:string,params:unknown)=>method==='account/login/start'
      ?new Promise<T>(resolve=>{reply=value=>resolve(value as T)}):original<T>(method,params)
    const pending=backend.startLogin()
    peer.close()
    reply({type:'chatgptDeviceCode',loginId:'fixture-late',verificationUrl:'https://auth.openai.com/codex/device',userCode:'TEST-ONLY'})
    await expect(pending).rejects.toThrow('provider_unavailable')
  })
  it.each(['model/list','account/rateLimits/read'])('keeps turn admission closed when cancelled during %s',async method=>{
    const peer=new LoginPeer();peer.account=subscription
    const backend=new CodexBackend(peer),original=peer.request.bind(peer),abort=new AbortController()
    let entered!:()=>void,release!:(value:unknown)=>void
    const waiting=new Promise<void>(resolve=>{entered=resolve})
    peer.request=<T>(name:string,params:unknown)=>{
      if(name!==method)return original<T>(name,params)
      entered();return new Promise<T>(resolve=>{release=value=>resolve(value as T)})
    }
    const pending=backend.run('fixture','',settings,[],async()=>({contentItems:[],success:true}),abort.signal)
    const rejected=expect(pending).rejects.toThrow('cancelled')
    await waiting;abort.abort();release({});await rejected
    expect(peer.calls).not.toContain('thread/start')
  })
  it.each(['model/list','account/rateLimits/read'])('keeps auxiliary readback unknown when disconnected during %s',async method=>{
    const peer=new LoginPeer();peer.account=subscription
    const original=peer.request.bind(peer)
    peer.request=async<T>(name:string,params:unknown)=>{
      if(name===method){peer.close();throw new Error('synthetic disconnect')}
      return original<T>(name,params)
    }
    await expect(new CodexBackend(peer).status()).rejects.toThrow('provider_unavailable')
  })
  it('characterizes the contract gap: failed completion and pending authorization have identical status',async()=>{
    const peer=new LoginPeer(),backend=new CodexBackend(peer),runtime=new AgentRuntime(core,backend)
    const login=await backend.startLogin(),before=await status(runtime)
    peer.complete(login.login_id,false)
    expect(await status(runtime)).toEqual(before) // no public login-result field; not evidence of sign-out
    await runtime.stop()
  })
  it('expires the local attempt without asserting account failure or restarting auth on reconnect',async()=>{
    vi.useFakeTimers()
    const peer=new LoginPeer(),backend=new CodexBackend(peer),login=await backend.startLogin()
    vi.setSystemTime(login.expires_at_ms+1)
    expect((await backend.startLogin()).login_id).not.toBe(login.login_id)
    peer.close()
    const reconnected=new LoginPeer();reconnected.account=subscription
    const runtime=new AgentRuntime(core,new CodexBackend(reconnected))
    await expect(status(runtime)).resolves.toMatchObject({authenticated:true})
    expect(reconnected.calls).not.toContain('account/login/start')
    await runtime.stop()
  })
  it.each(['model/list','account/rateLimits/read'])('still refuses a turn when %s cannot be checked',async method=>{
    const peer=new LoginPeer();peer.account=subscription;peer.failure=method
    const backend=new CodexBackend(peer)
    await expect(backend.run('fixture','',settings,[],async()=>({contentItems:[],success:true}),new AbortController().signal)).rejects.toThrow('synthetic provider failure')
    expect(peer.calls).not.toContain('thread/start')
    expect(peer.calls).not.toContain('turn/start')
  })
})
