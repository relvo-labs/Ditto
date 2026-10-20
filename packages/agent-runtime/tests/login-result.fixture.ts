// Private synthetic fixture for the production Core/controller/runtime seam.
// No Codex process, authorization request, keyring or provider network.
import assert from 'node:assert/strict'
import {closeSync,existsSync,readFileSync,watch,writeFileSync} from 'node:fs'
import {join} from 'node:path'
import {CoreLink} from '../../host-runtime/src/bridge/core-link.ts'
import {DittoError} from '../../host-runtime/src/errors.ts'
import {CodexBackend,type BackendTransport} from '../src/codex.ts'
import {AgentRuntime} from '../src/runtime.ts'

const directory=process.env.DITTO_LOGIN_FIXTURE_DIR!
const readyFile=join(directory,'controller-ready')
const sentinel='SENSITIVE-LOGIN-SENTINEL'
class NativeFixture implements BackendTransport {
  onNotification=(_method:string,_params:unknown)=>{}
  onRequest=async():Promise<unknown>=>undefined
  onClosed=(_error:Error)=>{}
  constructor(private id="fixture-attempt"){}
  async request<T>(method:string):Promise<T>{
    if(method==='account/login/start')return {type:'chatgptDeviceCode',loginId:this.id,verificationUrl:'https://auth.openai.com/codex/device',userCode:'TEST-ONLY'} as T
    if(method==='account/login/cancel')return {status:'canceled'} as T
    throw new Error('unexpected native action')
  }
  notify():void{}
  close():void{this.onClosed(new Error('fixture closed'))}
}
async function waitReady():Promise<void>{
  if(existsSync(readyFile))return
  await new Promise<void>((resolve,reject)=>{
    const watcher=watch(directory,()=>{if(existsSync(readyFile)){clearTimeout(timer);watcher.close();resolve()}})
    const timer=setTimeout(()=>{watcher.close();reject(new Error('fixture readiness timeout'))},5000)
    if(existsSync(readyFile)){clearTimeout(timer);watcher.close();resolve()}
  })
}
async function main():Promise<void>{
  const link=await CoreLink.connectSocket(process.env.DITTO_CORE_SOCKET!)
  const fd=Number(process.env.DITTO_CORE_TOKEN_FD),token=readFileSync(fd,'utf8').trim();closeSync(fd)
  if(process.env.DITTO_CLIENT_KIND==='agent'){
    const peer=new NativeFixture(),backend=new CodexBackend(peer),runtime=new AgentRuntime(link,backend)
    // Seed exactly one fixture attempt before exposing readback. Queries never start one.
    const attempt=await backend.startLogin()
    peer.onNotification('account/login/completed',{loginId:attempt.login_id,success:false,error:sentinel})
    // Independent synthetic producers exercise all safe states across Core.
    // This table is fixture setup, not a production attempt registry/history.
    const producers:Array<{id:string;runtime:AgentRuntime}>=[]
    for(const state of ['pending','succeeded','cancelled'] as const){
      const id='fixture-'+state,transport=new NativeFixture(id),adapter=new CodexBackend(transport)
      await adapter.startLogin()
      if(state==='succeeded')transport.onNotification('account/login/completed',{loginId:id,success:true,error:null})
      if(state==='cancelled')await adapter.cancelLogin(id)
      const producer=new AgentRuntime(link,adapter);await producer.start()
      producers.push({id,runtime:producer})
    }
    const stop=async()=>{await Promise.all([runtime.stop(),...producers.map(p=>p.runtime.stop())]);link.close()}
    link.attach({request:async(method,params)=>{
      const p=params as {login_id:string;generation:number}
      // Deliberately malformed/old producers exercise the real Core parser.
      if(p.login_id==='fixture-old')throw new DittoError('unsupported',sentinel)
      const result={login_id:p.login_id,generation:p.generation,state:'failed'}
      const envelope={result,expires_at_ms:Date.now()+60000}
      if(p.login_id==='fixture-extra')return {...envelope,result:{...result,error:sentinel}}
      if(p.login_id==='fixture-envelope-extra')return {...envelope,error:sentinel}
      if(p.login_id==='fixture-enum')return {...envelope,result:{...result,state:'browser_confirmed'}}
      if(p.login_id==='fixture-mismatch')return {...envelope,result:{...result,login_id:'other-attempt'}}
      if(p.login_id==='fixture-generation')return {...envelope,result:{...result,generation:p.generation+1}}
      if(p.login_id==='fixture-missing-deadline')return {...envelope,expires_at_ms:null}
      // A stale succeeded envelope must expire at Core publication, after await.
      if(p.login_id==='fixture-expired')return {...envelope,result:{...result,state:'succeeded'},expires_at_ms:Date.now()-1}
      if(p.login_id==='fixture-disconnect'){link.close();return new Promise(()=>{})}
      return (producers.find(producer=>producer.id===p.login_id)?.runtime??runtime).request(method,params)
    },notification:(method,params)=>{if(method==='agent.controller.stop')void stop();else runtime.notification(method,params)},closed:()=>{void stop()}})
    await runtime.start();await link.handshake(token,{kind:'agent',version:'0.3.0'})
    await link.request('agent.runtime.ready',{});writeFileSync(readyFile,'ready')
    process.on('SIGTERM',()=>{void stop()})
    return
  }
  await link.handshake(token,{kind:'dittoctl',version:'0.3.0'})
  const checks:string[]=[]
  const query=async(login_id:string,generation:number)=>link.request<Record<string,unknown>>('agent.providers.login_result',{provider:'codex-app-server',login_id,generation})
  const initial=await link.request<{generation:number;phase:string}>('agent.runtime.get',{})
  assert.equal((await query('fixture-attempt',initial.generation)).state,'unknown')
  const afterRead=await link.request<{generation:number;phase:string}>('agent.runtime.get',{})
  assert.equal(afterRead.generation,initial.generation);assert.equal(afterRead.phase,initial.phase)
  checks.push('read does not launch controller')
  const catalog=await link.request<{capabilities:Array<{capability_id:string;resource_scope:string[];claimable:boolean}>}>('desktop.capabilities.list',{})
  const result=catalog.capabilities.find(c=>c.capability_id==='agent.providers.login_result')!
  assert.deepEqual(result.resource_scope,catalog.capabilities.find(c=>c.capability_id==='agent.providers.status')!.resource_scope)
  assert.equal(result.claimable,false)
  checks.push('same narrow scope, nonclaimable')
  const {_meta,...settings}=await link.request<Record<string,unknown>>('agent.settings.describe',{})
  await link.request('agent.settings.patch',{expected_revision:settings.revision,settings:{...settings,enabled:true}})
  const active=await link.request<{generation:number}>('agent.runtime.ensure',{})
  await waitReady()
  const failed=await query('fixture-attempt',active.generation)
  assert.equal(failed.state,'failed');assert.equal(failed.login_id,'fixture-attempt');assert.equal(failed.generation,active.generation)
  assert(!JSON.stringify(failed).includes(sentinel))
  assert.deepEqual(Object.keys(failed).sort(),['_meta','generation','login_id','state'])
  for(const state of ['pending','succeeded','cancelled']){
    const id='fixture-'+state,readback=await query(id,active.generation)
    assert.equal(readback.state,state);assert.equal(readback.login_id,id)
    assert.deepEqual(Object.keys(readback).sort(),['_meta','generation','login_id','state'])
  }
  checks.push('native pending/success/false/cancel -> adapter -> runtime -> authenticated Core result, no error')
  for(const id of ['unknown-attempt','fixture-old'])assert.equal((await query(id,active.generation)).state,'unknown')
  assert.equal((await query('fixture-attempt',active.generation+1)).state,'unknown')
  checks.push('unknown attempt, old controller, wrong generation stay unknown')
  for(const id of ['fixture-extra','fixture-envelope-extra','fixture-enum','fixture-mismatch','fixture-generation','fixture-missing-deadline']){
    await assert.rejects(query(id,active.generation),(error:unknown)=>error instanceof DittoError&&error.errorName==='internal'&&!error.message.includes(sentinel))
  }
  assert.equal((await query('fixture-expired',active.generation)).state,'expired')
  checks.push('closed output parser, exact identity and post-await deadline fence')
  await assert.rejects(link.request('agent.providers.login_result',{provider:'codex-app-server',login_id:'fixture-attempt',generation:active.generation},{onBehalfOf:'forged-shell'}))
  await assert.rejects(link.request('agent.runtime.ready',{}))
  checks.push('forged caller and controller identity rejected')
  assert.equal((await query('fixture-disconnect',active.generation)).state,'unknown')
  await link.request('agent.runtime.stop',{})
  assert.equal((await query('fixture-attempt',active.generation)).state,'unknown')
  checks.push('lost controller is unknown; no restart')
  process.stdout.write('LOGIN_RESULT_FIXTURE_RESULT '+JSON.stringify({ok:true,checks})+'\n')
  link.close()
}
main().catch(()=>{process.stdout.write('LOGIN_RESULT_FIXTURE_RESULT {"ok":false}\n');process.exitCode=1})
