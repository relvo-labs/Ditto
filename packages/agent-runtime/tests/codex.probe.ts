// Opt-in native protocol probe. A blank HOME/CODEX_HOME, ephemeral auth and
// no turn/start mean no personal credentials and no inference are requested.
import {spawn,spawnSync} from 'node:child_process'
import {mkdtempSync,mkdirSync,readFileSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {createHash} from 'node:crypto'
import {StdioPeer} from '../src/framing.ts'
import {CodexBackend} from '../src/codex.ts'

const executable=process.env.DITTO_CODEX_PROBE_BINARY
if(!executable)throw new Error('DITTO_CODEX_PROBE_BINARY must name the exact local CLI binary')
const version=spawnSync(executable,['--version'],{encoding:'utf8'}).stdout.trim()
if(version!=='codex-cli 0.160.0')throw new Error('this probe supports only the inspected 0.160.0 experimental schema')
const sha256=createHash('sha256').update(readFileSync(executable)).digest('hex')
const root=mkdtempSync(tmpdir()+'/ditto-codex-probe-')
for(const directory of ['home','codex','work'])mkdirSync(root+'/'+directory,{mode:0o700})
const child=spawn(executable,['app-server','--listen','stdio://','-c','cli_auth_credentials_store="ephemeral"','-c','analytics.enabled=false'],{
  cwd:root+'/work',env:{HOME:root+'/home',CODEX_HOME:root+'/codex',PATH:'/usr/bin:/bin',LANG:'C.UTF-8'},stdio:['pipe','pipe','pipe'],detached:true,
})
let diagnostic='';child.stderr.on('data',chunk=>{if(diagnostic.length<8192)diagnostic+=String(chunk)})
const transport=new StdioPeer(child.stdout,child.stdin)
const backend=new CodexBackend(transport)
try{
  await backend.initialize()
  const status=await backend.status()
  if(status.authenticated)throw new Error('a blank ephemeral probe must not be authenticated')
  // Exercise the actual experimental dynamicTools parser, without a turn.
  const thread=await transport.request<{thread:{id:string}}>('thread/start',{
    cwd:root+'/work',sandbox:'read-only',approvalPolicy:'never',ephemeral:true,
    dynamicTools:[{type:'function',name:'desktop__appearance__get',description:'protocol probe only',inputSchema:{type:'object',properties:{},additionalProperties:false}}],
  })
  if(typeof thread.thread?.id!=='string')throw new Error('thread/start did not return an identifier')
  console.log(JSON.stringify({ok:true,version,sha256,initialize:true,subscription_auth:false,model_catalog_count:status.models.length,dynamic_tool_parser:true,thread_ephemeral:true,inference:false,login:false,os_isolation_verified:false,evidence_class:'native-protocol-probe'}))
}catch(error){
  console.error('Codex native protocol probe failed: '+String(error));
  // Empty test home only; no personal provider response is ever printed.
  if(diagnostic)console.error(diagnostic.slice(0,4096));process.exitCode=1
}finally{
  backend.close();try{process.kill(-child.pid!,'SIGKILL')}catch{}
  await new Promise<void>(resolve=>{if(child.exitCode!==null||child.signalCode!==null)resolve();else child.once('exit',()=>resolve())})
  rmSync(root,{recursive:true,force:true})
}
