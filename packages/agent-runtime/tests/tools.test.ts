import {it,expect} from 'vitest'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import {DittoError} from '../../host-runtime/src/errors.ts'
import {DesktopTools,modelSchema} from '../src/tools.ts'

const descriptor={capability_id:'desktop.appearance.get',version:'0.3.0',availability:{kind:'always'},input_schema:{type:'object',properties:{},additionalProperties:false},resource_scope:['read'],timeout_ms:{max_ms:1000}}
function fixture(operation:(params:Record<string,unknown>)=>unknown|Promise<unknown>,previous?:unknown){
  const calls:Array<{method:string;params:Record<string,unknown>;options?:unknown}>=[]
  const core:CoreChannel={async request<T>(method:string,params:Record<string,unknown>,options?:unknown):Promise<T>{
    calls.push({method,params,options})
    if(method==='desktop.capabilities.list')return {catalog_revision:5,capabilities:[descriptor,{...descriptor,capability_id:'desktop.permissions.grant'},{...descriptor,capability_id:'desktop.windows.list',availability:{kind:'depends_on_compositor',available:false}}]} as T
    if(method==='agent.tools.intent')return {intent_id:'intent-one',turn_id:'turn-one',tool_call_id:'call-one',capability_id:descriptor.capability_id,payload_hash:'hash',previous_result:previous??null} as T
    if(method==='agent.turns.get')return {session_id:'ses-one'} as T
    if(method==='desktop.approvals.request')return {request_id:'approval-one',decision:'rejected'} as T
    if(method===descriptor.capability_id)return await operation(params) as T
    return {} as T
  }}
  return {tools:new DesktopTools(core),calls}
}

it('uses current descriptors and refuses unavailable, management and malformed tools before intent acceptance',async()=>{
  const f=fixture(()=>({})),tools=await f.tools.discover()
  expect(tools.map(t=>t.name)).toEqual(['desktop__appearance__get'])
  for(const [name,args] of [['desktop__windows__list',{}],['desktop__permissions__grant',{}],['desktop__appearance__get',{unknown:true}],['desktop__appearance__get',{bad:NaN}]] as const){
    await expect(f.tools.execute('turn-one','call-one',name,args,new AbortController().signal)).rejects.toThrow()
  }
  expect(f.calls.map(c=>c.method)).toEqual(['desktop.capabilities.list'])
})

it('rejects unsupported constraints even in absent optional schema fields',async()=>{
  const f=fixture(()=>({}));descriptor.input_schema.properties={optional:{not:{type:'string'}}} as typeof descriptor.input_schema.properties
  try{await f.tools.discover();await expect(f.tools.execute('turn-one','call-one','desktop__appearance__get',{},new AbortController().signal)).rejects.toThrow('unsupported schema keyword')}
  finally{descriptor.input_schema.properties={}}
  expect(f.calls).toHaveLength(1)
})

it('returns retained outcomes only through a fresh authorized Core call',async()=>{
  const f=fixture(()=>{throw new DittoError('permission_denied','revoked',{reason:'policy_denied'})},{result:{old_private:'value'}})
  await f.tools.discover()
  const reply=await f.tools.execute('turn-one','call-one','desktop__appearance__get',{},new AbortController().signal)
  expect(reply.success).toBe(false);expect(reply.contentItems[0].text).not.toContain('old_private')
  expect(f.calls.find(c=>c.method===descriptor.capability_id)?.options).toMatchObject({operationId:'intent-one'})
  expect(Object.isFrozen(reply)).toBe(true);expect(Object.isFrozen(reply.contentItems)).toBe(true)
})

it('does not retry lost acknowledgements, and abandons only definitively unexecuted calls',async()=>{
  const lost=fixture(()=>{throw new DittoError('timeout','lost',undefined,'unknown')});await lost.tools.discover()
  await expect(lost.tools.execute('turn-one','call-one','desktop__appearance__get',{},new AbortController().signal)).rejects.toThrow('lost')
  expect(lost.calls.filter(c=>c.method===descriptor.capability_id)).toHaveLength(1)
  expect(lost.calls.some(c=>c.method==='agent.tools.abandon')).toBe(false)
  const refused=fixture(()=>{throw new DittoError('permission_denied','ask',{reason:'approval_unavailable'})});await refused.tools.discover()
  expect((await refused.tools.execute('turn-one','call-one','desktop__appearance__get',{},new AbortController().signal)).success).toBe(false)
  expect(refused.calls.filter(c=>c.method===descriptor.capability_id)).toHaveLength(1)
  expect(refused.calls.at(-1)).toMatchObject({method:'agent.tools.abandon',params:{reason:'permission_denied'}})
})
it('spells out untyped values for the model, since Codex turns an untyped schema into a string',()=>{
  const shown=modelSchema({type:'object',properties:{after:true,before:{description:'old'},config:{},path:{type:'string'},list:{type:'array',items:{}}},$defs:{Op:{oneOf:[{type:'object',properties:{after:true}}]}},additionalProperties:false}) as any
  for(const value of [shown.properties.after,shown.properties.before,shown.properties.config,shown.properties.list.items,shown.$defs.Op.oneOf[0].properties.after]){
    expect(value.anyOf.map((s:any)=>s.type)).toEqual(['string','number','boolean','null','object','array'])
  }
  expect(shown.properties.before.description).toBe('old')
  expect(shown.properties.path).toEqual({type:'string'})
  expect(shown.additionalProperties).toBe(false)
})
it('asks for a Profile deletion with its arguments, so Core can name the Profile, and deletes only when allowed',async()=>{
  const remove={...descriptor,capability_id:'desktop.profiles.delete',input_schema:{type:'object',properties:{profile_id:{type:'string'}},required:['profile_id'],additionalProperties:false},resource_scope:['desktop.config','profiles.delete']}
  for(const decision of ['allowed-once','rejected']){
    const calls:Array<{method:string;params:Record<string,unknown>}>=[]
    let asked=false
    const core:CoreChannel={async request<T>(method:string,params:Record<string,unknown>):Promise<T>{
      calls.push({method,params})
      if(method==='desktop.capabilities.list')return {catalog_revision:1,capabilities:[remove]} as T
      if(method==='agent.tools.intent')return {intent_id:'intent-one',turn_id:'turn-one',tool_call_id:'call-one',capability_id:remove.capability_id,payload_hash:'hash',previous_result:null} as T
      if(method==='agent.turns.get')return {session_id:'ses-one'} as T
      if(method==='desktop.approvals.request'){asked=true;return {request_id:'approval-one',decision} as T}
      if(method===remove.capability_id){if(!asked)throw new DittoError('permission_denied','ask',{reason:'approval_unavailable'});return {profile_id:'prof-a',name:'A'} as T}
      return {} as T
    }}
    const tools=new DesktopTools(core);await tools.discover()
    const reply=await tools.execute('turn-one','call-one','desktop__profiles__delete',{profile_id:'prof-a'},new AbortController().signal)
    expect(calls.find(c=>c.method==='desktop.approvals.request')?.params).toMatchObject({capability_id:'desktop.profiles.delete',resource:'desktop.config,profiles.delete',arguments:{profile_id:'prof-a'}})
    expect(reply.success).toBe(decision==='allowed-once')
    expect(calls.filter(c=>c.method===remove.capability_id)).toHaveLength(decision==='allowed-once'?2:1)
  }
})
