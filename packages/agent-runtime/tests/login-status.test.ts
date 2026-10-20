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
