// Runs inside one authenticated physical test login. Every profile mutation
// goes through Core; the installed user's store is never opened here.
import {createConnection} from 'node:net'
import {readFileSync,writeFileSync} from 'node:fs'
import {spawnSync} from 'node:child_process'
import {trustMatrix} from '../integration/trust-matrix.mjs'
const run=process.env.DITTO_G3_RUN_SUFFIX, facts={checks:[]}
const call=(method,params={})=>new Promise((resolve,reject)=>{const s=createConnection(process.env.DITTO_G1_RELAY);let b='';const t=setTimeout(()=>{s.destroy();reject(Error('relay timeout'))},90000);s.on('error',e=>{clearTimeout(t);reject(e)});s.on('connect',()=>s.write(JSON.stringify({method,params})+'\n'));s.on('data',d=>{b+=d;if(b.includes('\n')){clearTimeout(t);s.destroy();resolve(JSON.parse(b.split('\n')[0]))}})})
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw Error(method+': '+JSON.stringify(r.error));return r.result}
const verify=(name,yes)=>{if(!yes)throw Error(name);facts.checks.push(name);console.log('PASS '+name)}
let original
try{
 original=await must('desktop.profiles.get')
 await must('desktop.profiles.create',{name:'G3 physical '+run,from:'default',idempotency_key:'physical-create-'+run})
 const test=(await must('desktop.profiles.list')).profiles.find(p=>p.name==='G3 physical '+run)
 await must('desktop.changes.propose',{base_revision:original.profile.head_revision,ops:[{op:'switch_profile',to_profile:test.profile_id}],idempotency_key:'physical-switch-'+run})
 const desktop=spawnSync(process.execPath,['tests/g3/desktop/driver.mjs'],{stdio:'inherit',env:process.env})
 verify('physical generation, preview, two modifications and schema rollback',desktop.status===0)
 facts.trust=await trustMatrix({call,must},(await must('desktop.profiles.get')).profile.head_revision,verify)
 if(process.env.DITTO_G3_REFERENCE_MODE==='desktop')facts.real_model='not_run: desktop-only interaction regression'
 else {
  const model=spawnSync(process.execPath,['tests/g3/agent/real-driver.mjs'],{stdio:'inherit',env:process.env})
  verify('physical real subscription: two new plugins and conversational modifications',model.status===0)
 }
}catch(error){facts.error=String(error);process.exitCode=1;console.error(error)}
finally{
 try{if(original){const p=(await must('desktop.profiles.get')).profile;await must('desktop.changes.propose',{base_revision:p.head_revision,ops:[{op:'switch_profile',to_profile:original.profile.profile_id,to_revision:original.profile.head_revision}],idempotency_key:'physical-restore-'+run});facts.restored=await must('desktop.profiles.get');verify('private test composition restored by authoritative readback',facts.restored.revision.document_sha256===original.revision.document_sha256)}}catch(error){facts.restore_error=String(error);process.exitCode=1}
 facts.physical_context=JSON.parse(readFileSync(process.env.DITTO_G3_PHYSICAL_CONTEXT,'utf8'))
 writeFileSync(process.env.DITTO_G3_TEST_OUT,JSON.stringify({ok:!process.exitCode,...facts},null,2)+'\n')
}
