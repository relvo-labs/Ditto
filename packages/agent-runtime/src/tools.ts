import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import {DittoError} from '../../host-runtime/src/errors.ts'
import {check} from '../../protocol/src/schema-check.ts'
import type {CapabilityDescriptor,CapabilitiesListOutput} from '../../protocol/src/generated/capabilities-list-output.ts'
import type {ToolIntent} from '../../protocol/src/generated/tool-intent.ts'
import type {Approval} from '../../protocol/src/generated/approval.ts'
import {snapshotJsonValue} from '../vendor/harness/values/index.ts'

const permitted=new Set([
  'desktop.profiles.list','desktop.profiles.get','desktop.profiles.diff',
  'desktop.changes.propose','desktop.changes.get','desktop.changes.list','desktop.changes.cancel','desktop.changes.undo',
  'desktop.appearance.get','desktop.appearance.set','desktop.panels.list','desktop.dock.get',
  'desktop.plugins.list','desktop.plugins.get','desktop.plugins.inspect',
  'desktop.windows.list','desktop.windows.get','desktop.outputs.list','desktop.workspaces.list','desktop.workspaces.get',
])
export interface DynamicTool {type:'function';name:string;description:string;inputSchema:unknown}
export interface ToolReply {contentItems:Array<{type:'inputText';text:string}>;success:boolean}

/** Native dispatch only: preflight → Core-correlated execute → immutable
 * outcome. Harness PTC/run_code, arbitrary JS, SDK generation and direct
 * provider APIs are deliberately outside this G2 adapter's tool surface. */
export class DesktopTools {
  private entries=new Map<string,CapabilityDescriptor>()
  private revision=0
  private approvals=new Map<string,{resolve:(decision:string)=>void}>()
  private decided=new Map<string,string>()
  constructor(private core:CoreChannel){}
  async discover():Promise<DynamicTool[]>{
    const catalog=await this.core.request<CapabilitiesListOutput>('desktop.capabilities.list',{})
    if(!Number.isSafeInteger(catalog.catalog_revision)||!Array.isArray(catalog.capabilities))throw new Error('invalid capability catalog')
    this.entries.clear();this.revision=catalog.catalog_revision
    const tools:DynamicTool[]=[]
    for(const descriptor of catalog.capabilities){
      if(!permitted.has(descriptor.capability_id))continue
      const available=descriptor.availability.kind==='always'||'available' in descriptor.availability&&descriptor.availability.available===true
      if(!available)continue
      const name=descriptor.capability_id.replaceAll('.','__')
      if(this.entries.has(name))throw new Error('duplicate capability tool name')
      this.entries.set(name,descriptor)
      tools.push({type:'function',name,description:`${descriptor.capability_id}; Core contract ${descriptor.version}. Discover current configuration before changes; only Core readback proves an outcome.`,inputSchema:descriptor.input_schema})
    }
    return tools
  }
  get catalogRevision():number{return this.revision}
  approvalDecided(id:string,decision:string):void {
    const pending=this.approvals.get(id)
    if(pending)pending.resolve(decision)
    else {if(this.decided.size>=32)this.decided.delete(this.decided.keys().next().value!);this.decided.set(id,decision)}
  }
  private async approval(intent:ToolIntent,descriptor:CapabilityDescriptor,signal:AbortSignal):Promise<boolean>{
    // Read the Core-owned turn; a tool name or a model cannot choose the
    // session, principal, connection generation or grant scope.
    const turn=await this.core.request<{session_id:string}>('agent.turns.get',{turn_id:intent.turn_id})
    const request=await this.core.request<Approval>('desktop.approvals.request',{
      session_id:turn.session_id,turn_id:intent.turn_id,capability_id:intent.capability_id,
      resource:descriptor.resource_scope.join(','),intent_hash:intent.payload_hash,purpose:'This desktop operation needs your permission.',
    })
    if(request.decision)return request.decision==='allowed-once'
    if(signal.aborted)return false
    return new Promise<boolean>(resolve=>{
      const finish=(decision:string)=>{clearTimeout(timer);signal.removeEventListener('abort',cancel);this.approvals.delete(request.request_id);this.decided.delete(request.request_id);resolve(decision==='allowed-once')}
      const cancel=()=>finish('cancelled')
      const timer=setTimeout(()=>finish('unavailable'),Math.max(1,Math.min(request.expires_at_ms-Date.now(),90000)));timer.unref()
      this.approvals.set(request.request_id,{resolve:finish});signal.addEventListener('abort',cancel,{once:true})
      if(signal.aborted){cancel();return}
      const early=this.decided.get(request.request_id);if(early)finish(early)
    })
  }
  async execute(turnId:string,callId:string,name:string,raw:unknown,signal:AbortSignal):Promise<ToolReply>{
    const descriptor=this.entries.get(name)
    if(!descriptor)throw new Error('unknown or unavailable tool')
    if(signal.aborted)throw new Error('cancelled')
    const args=snapshotJsonValue(raw)
    if(args===undefined||!args||typeof args!=='object'||Array.isArray(args))throw new Error('tool arguments must be lossless JSON object')
    if(Buffer.byteLength(JSON.stringify(args))>65536)throw new Error('tool input exceeds limit')
    if(check(descriptor.input_schema as boolean|Record<string,unknown>,args,{strict:true}).length)throw new Error('tool input does not match discovered schema')
    const intent=await this.core.request<ToolIntent>('agent.tools.intent',{turn_id:turnId,tool_call_id:callId,capability_id:descriptor.capability_id,arguments:args})
    // Re-delivery also goes through Core: a retained outcome is not a grant.
    // Core fences duplicate dispatch and checks the current authorization.
    if(signal.aborted){await this.core.request('agent.tools.abandon',{intent_id:intent.intent_id,reason:'cancelled'});throw new Error('cancelled')}
    try{
      const invoke=()=>this.core.request(descriptor.capability_id,args as Record<string,unknown>,{operationId:intent.intent_id,deadlineMs:descriptor.timeout_ms.max_ms})
      let result:unknown
      try{result=await invoke()}
      catch(error){
        if(!(error instanceof DittoError)||error.errorName!=='permission_denied'||error.reason!=='approval_unavailable')throw error
        if(!await this.approval(intent,descriptor,signal))throw error
        if(signal.aborted)throw new Error('cancelled')
        result=await invoke()
      }
      return this.reply(result,true)
    }catch(error){
      // Approval is an explicit user flow; no model text is authorization.
      // The caller may present this refusal to the user and await a new turn.
      if(error instanceof DittoError){
        if(error.outcome==='unknown')throw error
        if(error.errorName==='permission_denied')await this.core.request('agent.tools.abandon',{intent_id:intent.intent_id,reason:'permission_denied'})
        return this.reply({error:{name:error.errorName,data:error.data,outcome:error.outcome}},false)
      }
      if(error instanceof Error&&error.message==='cancelled')await this.core.request('agent.tools.abandon',{intent_id:intent.intent_id,reason:'cancelled'})
      throw error // lost acknowledgements remain unknown, never blindly retried
    }
  }
  private reply(value:unknown,success:boolean):ToolReply{
    const text=JSON.stringify(value)
    if(Buffer.byteLength(text)>131072)throw new Error('tool output exceeds limit')
    const contentItems=[Object.freeze({type:'inputText' as const,text})]
    Object.freeze(contentItems)
    return Object.freeze({contentItems,success})
  }
}
