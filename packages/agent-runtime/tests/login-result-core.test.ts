import {expect,it} from 'vitest'
import {build} from 'tsdown'
import {spawn} from 'node:child_process'
import {once} from 'node:events'
import {mkdtemp,readFile,readdir,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'
import {agentAliases} from '../vendor-alias.mjs'

// Local fixture Core/launcher/listeners only. Not VM, native capture or real auth.
it('reads sanitized native fixture completion over the production Core/controller socket path',async()=>{
  const root=resolve(import.meta.dirname,'../../..'),directory=await mkdtemp(join(tmpdir(),'ditto-login-result-'))
  let child:ReturnType<typeof spawn>|undefined
  let logs=''
  try{
    await build({config:false,cwd:resolve(root,'packages/agent-runtime'),tsconfig:'../host-runtime/tsconfig.build.json',entry:{fixture:'tests/login-result.fixture.ts'},format:'esm',platform:'node',target:'node22',outDir:join(directory,'bundle'),fixedExtension:true,dts:false,clean:true,alias:agentAliases,outputOptions:{codeSplitting:false},logLevel:'silent'})
    const spec=`${process.execPath} ${join(directory,'bundle/fixture.mjs')}`
    const env={...process.env,DITTO_RUNTIME_DIR:join(directory,'run'),DITTO_DATA_DIR:join(directory,'store'),DITTO_LOGIN_FIXTURE_DIR:directory,DITTO_SYSTEM:'none'}
    for(const key of ['DITTO_DEV_TOKEN','DITTO_REQUIRE_QUOTA','DITTO_LAUNCH_SCOPE_PREFIX','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key as keyof typeof env]
    child=spawn(join(root,'target/debug/ditto-core'),['serve','--compositor','fixture','--agent',`agent 0.3.0 ${spec}`,'--launch',`dittoctl 0.3.0 ${spec}`],{env,detached:true,stdio:['ignore','pipe','pipe']})
    const result=await new Promise<{ok:boolean;checks:string[]}>((resolveResult,reject)=>{
      const timer=setTimeout(()=>reject(new Error('Core fixture timeout')),15000)
      child!.on('error',error=>{clearTimeout(timer);reject(error)})
      child!.on('exit',()=>{clearTimeout(timer);reject(new Error('Core fixture exited before result'))})
      const output=(chunk:Buffer)=>{
        logs+=chunk.toString()
        const match=logs.match(/LOGIN_RESULT_FIXTURE_RESULT (\{[^\n]+\})\n/)
        if(match){clearTimeout(timer);resolveResult(JSON.parse(match[1]!))}
      }
      child!.stdout!.on('data',output);child!.stderr!.on('data',output)
    })
    expect(result.ok).toBe(true)
    expect(result.checks).toHaveLength(7)
    expect(logs).not.toContain('SENSITIVE-LOGIN-SENTINEL')
    const data=join(directory,'store/data')
    for(const name of (await readdir(data)).filter(name=>name==='core.db'||name==='core.db-wal')){
      expect((await readFile(join(data,name))).includes(Buffer.from('SENSITIVE-LOGIN-SENTINEL'))).toBe(false)
    }
  }finally{
    if(child?.pid){
      const exited=once(child,'exit')
      try{process.kill(-child.pid,'SIGTERM')}catch{}
      const timer=setTimeout(()=>{try{process.kill(-child!.pid!,'SIGKILL')}catch{}},2000)
      if(child.exitCode===null&&child.signalCode===null)await exited
      clearTimeout(timer)
    }
    await rm(directory,{recursive:true,force:true})
  }
},30000)
