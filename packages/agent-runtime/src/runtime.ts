import {Context,Service} from '@deepseek-ai/cordis'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import type {TurnClaimOutput} from '../../protocol/src/generated/turn-claim-output.ts'
import type {Turn} from '../../protocol/src/generated/turn.ts'
import type {ProviderStatus} from '../../protocol/src/generated/provider-status.ts'
import {CoreSessionHandle} from './session.ts'
import {DesktopTools} from './tools.ts'
import type {CodexBackend} from './codex.ts'
import {DirectModelBackend} from './direct.ts'

declare module '@deepseek-ai/cordis' {
  interface Context {agentSessions:AgentSessions;agentTools:AgentTools;agentModels:AgentModels}
  interface Events {'agent/text'(turnId:string,delta:string):void}
}
class AgentSessions extends Service {
  constructor(ctx:Context,private core:CoreChannel){super(ctx,'agentSessions')}
  open(id:string):Promise<CoreSessionHandle>{return CoreSessionHandle.open(this.core,id)}
}
class AgentTools extends Service {
  readonly desktop:DesktopTools
  constructor(ctx:Context,core:CoreChannel){super(ctx,'agentTools');this.desktop=new DesktopTools(core)}
}
class AgentModels extends Service {
  constructor(ctx:Context,readonly backend?:CodexBackend){super(ctx,'agentModels')}
}
const controllerPlugin={name:'ditto-agent-controller',inject:['agentSessions','agentTools','agentModels'],apply(ctx:Context){
  // Consumers use actual Cordis injection. Every registration is attached to
  // this fiber, and disposing the root unregisters all listeners/services.
  ctx.on('agent/text',()=>{})
}}

/** Batches answer text for the Shell: about every 50 ms, at most 4 KiB a
 * call (split on a character boundary). Display only; lost batches are made
 * good by the stored answer at the end of the turn. */
export class StreamBatcher {
  private buffer=''
  private timer?:NodeJS.Timeout
  constructor(private send:(text:string)=>void,private interval=50){}
  push(delta:string):void{
    this.buffer+=delta
    if(Buffer.byteLength(this.buffer)>=4096)this.flush()
    else if(!this.timer){this.timer=setTimeout(()=>this.flush(),this.interval);this.timer.unref()}
  }
  flush():void{
    if(this.timer){clearTimeout(this.timer);this.timer=undefined}
    while(this.buffer){
      let cut=this.buffer.length
      while(Buffer.byteLength(this.buffer.slice(0,cut))>4096)cut=Math.floor(cut*0.9)
      // Do not split a surrogate pair.
      if(cut<this.buffer.length&&/[\uD800-\uDBFF]/.test(this.buffer[cut-1]!))cut--
      this.send(this.buffer.slice(0,cut));this.buffer=this.buffer.slice(cut)
    }
  }
}

/** Core's records of this conversation's latest changes, as compact text
 * for the model: the targets a follow-up ("a bit narrower") refers to. */
export function recentChangesText(changes:TurnClaimOutput['recent_changes']):string{
  if(!changes?.length)return ''
  const value=(v:unknown)=>v===undefined||v===null?'—':typeof v==='string'?v:JSON.stringify(v).slice(0,200)
  const lines=['Recent verified changes in this conversation, newest first (from Ditto Core records):']
  for(const change of changes){
    lines.push(`- ${change.change_id}: ${change.state}${change.result?' / '+change.result:''}`)
    for(const item of change.items.slice(0,8)){
      const args=Object.entries(item.label_args??{}).map(([k,v])=>`${k}=${value(v)}`).join(', ')
      lines.push(`  · ${item.path}${args?' ('+args+')':''}: ${value(item.before)} → ${value(item.after)}`)
    }
  }
  const text=lines.join('\n')
  return Buffer.byteLength(text)>8192?text.slice(0,8192):text
}

/** The one Agent controller. Core owns the accepted queue and all event bytes;
 * this process retains only its active request, bounded stream and handles. */
export class AgentRuntime {
  readonly root=new Context()
  private queue:string[]=[]
  private processing?:Promise<void>
  private active?:{turnId:string;abort:AbortController}
  private stopped=false
  private handles=new Set<CoreSessionHandle>()
  private direct:DirectModelBackend
  constructor(private core:CoreChannel,private backend?:CodexBackend){
    this.direct=new DirectModelBackend(core)
    new AgentSessions(this.root,core);new AgentTools(this.root,core);new AgentModels(this.root,backend)
  }
  async start():Promise<void>{await this.root.plugin(controllerPlugin)}
  notification(method:string,raw:unknown):void{
    if(!raw||typeof raw!=='object')return
    const params=raw as Record<string,unknown>
    if(method==='agent.controller.turn_available'){
      const ids=typeof params.turn_id==='string'?[params.turn_id]:Array.isArray(params.turn_ids)?params.turn_ids:[]
      for(const id of ids){if(typeof id!=='string'||this.queue.includes(id)||this.active?.turnId===id)continue;if(this.queue.length>=32)break;this.queue.push(id)}
      this.pump()
    }else if(method==='agent.controller.cancel'&&params.turn_id===this.active?.turnId)this.active?.abort.abort()
    else if(method==='agent.controller.approval_decided'&&typeof params.request_id==='string'&&typeof params.decision==='string')this.root.agentTools.desktop.approvalDecided(params.request_id,params.decision)
    else if(method==='agent.controller.settings_changed'&&params.enabled===false){this.queue=[];this.active?.abort.abort()}
    else if(method==='agent.controller.stop')void this.stop()
  }
  private pump():void{
    if(this.processing||this.stopped)return
    this.processing=(async()=>{
      while(this.queue.length&&!this.stopped){const id=this.queue.shift()!;await this.run(id)}
    })().finally(()=>{this.processing=undefined;if(this.queue.length&&!this.stopped)this.pump()})
    // Unexpected storage/transport failures stop the controller. A supervisor
    // fences ownership; no queued history is dispatched by this old process.
    void this.processing.catch(()=>{void this.stop()})
  }
  private async run(turnId:string):Promise<void>{
    let claim:TurnClaimOutput
    try{claim=await this.core.request<TurnClaimOutput>('agent.turns.claim',{turn_id:turnId})}
    catch{return} // cancelled/claimed/stale hints are not an execution queue
    const abort=new AbortController();this.active={turnId,abort}
    let handle:CoreSessionHandle|undefined
    let state:Turn['state']='failed',reason:string|undefined
    try{
      handle=await this.root.agentSessions.open(claim.turn.session_id);this.handles.add(handle)
      // The backend is the one the turn's settings snapshot names; the two
      // never run one turn together (no second autonomous loop).
      const direct=claim.settings.provider==='direct-model'
      if(!direct&&!this.backend)throw new Error('backend_unsupported')
      const page=await handle.read(Math.max(0,claim.message_seq-50),50)
      let history=''
      for(const event of page.events){
        if(event.seq>=claim.message_seq||!['user/message','assistant/message'].includes(event.type))continue
        const data=event.data as Record<string,unknown>
        if(typeof data.text==='string')history+=JSON.stringify({role:event.type,text:data.text})+'\n'
      }
      // Slice by bytes, preserving valid UTF-8 through a bounded event window.
      while(Buffer.byteLength(history)>16384){const newline=history.indexOf('\n');history=newline>=0?history.slice(newline+1):''}
      const recent=recentChangesText(claim.recent_changes??[])
      if(recent)history+=(history?'\n':'')+recent
      const tools=await this.root.agentTools.desktop.discover()
      const execute=(callId:string,name:string,args:unknown)=>this.root.agentTools.desktop.execute(turnId,callId,name,args,abort.signal)
      const stream=new StreamBatcher(text=>{void this.core.request('agent.turns.stream',{turn_id:turnId,text}).catch(()=>{})})
      const onText=(delta:string)=>{this.root.emit('agent/text',turnId,delta);stream.push(delta)}
      const output=direct
        ?await this.direct.run(turnId,claim.text,history,claim.settings,tools,execute,abort.signal,onText,claim.contexts??[])
        :await this.backend!.run(claim.text,history,claim.settings,tools,execute,abort.signal,onText,claim.contexts??[])
      stream.flush()
      await handle.append('model/selection',{turn_id:turnId,provider:claim.settings.provider,model:output.model,settings_revision:claim.settings.revision})
      if(output.text)await handle.append('assistant/message',{turn_id:turnId,text:output.text,...(output.usage?{usage:output.usage}:{})})
      await handle.flush();state=output.interrupted?'cancelled':'succeeded'
    }catch(error){
      const message=error instanceof Error?error.message:''
      reason=['provider_unavailable','provider_timeout','rate_limited','keyring_locked','backend_unsupported','storage_full','cancelled'].includes(message)?message:'interrupted'
      state=abort.signal.aborted?'cancelled':'failed'
    }finally{
      try{await this.core.request('agent.turns.complete',{turn_id:turnId,state,error_reason:reason??null})}
      finally{
        if(handle){this.handles.delete(handle);await handle.close()}
        this.active=undefined
      }
    }
  }
  async request(method:string,params:unknown):Promise<unknown>{
    if(!method.startsWith('agent.controller.provider.')||!params||typeof params!=='object')throw new Error('unsupported controller request')
    const p=params as Record<string,unknown>
    if(p.provider!=='codex-app-server')throw new Error('unsupported model provider')
    if(!this.backend){
      if(method.endsWith('.status'))return {available:false,provider:'codex-app-server',authenticated:false,account_label:null,models:[],rate_limits:null} satisfies ProviderStatus
      throw new Error('backend_unsupported')
    }
    switch(method){
      case 'agent.controller.provider.status':return this.backend.status()
      case 'agent.controller.provider.login':return this.backend.startLogin()
      case 'agent.controller.provider.cancel_login':if(typeof p.login_id!=='string')throw new Error('invalid login');return this.backend.cancelLogin(p.login_id)
      case 'agent.controller.provider.logout':return this.backend.logout()
      default:throw new Error('unsupported controller request')
    }
  }
  async stop():Promise<void>{
    if(this.stopped)return;this.stopped=true;this.queue=[];this.active?.abort.abort()
    try{await this.backend?.interrupt()}catch{}
    this.backend?.close()
    try{await this.processing}catch{}
    for(const handle of this.handles){try{await handle.close()}catch{}}
    this.handles.clear();await this.root.fiber.dispose()
  }
}
