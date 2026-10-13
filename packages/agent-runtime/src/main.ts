import {closeSync,readFileSync} from 'node:fs'
import {Socket} from 'node:net'
import {CoreLink} from '../../host-runtime/src/bridge/core-link.ts'
import {AgentRuntime} from './runtime.ts'
import {CodexBackend} from './codex.ts'
import {StdioPeer} from './framing.ts'

/** The backend channel is a socketpair end that Core hands over at launch.
 * Core started the confined app-server on the other end; this process never
 * chooses the binary, its arguments, its account store or its OS boundary. */
async function backend(env:NodeJS.ProcessEnv):Promise<CodexBackend|undefined>{
  if(!env.DITTO_BACKEND_FD)return undefined
  const fd=Number(env.DITTO_BACKEND_FD)
  if(!Number.isInteger(fd)||fd<4)throw new Error('invalid backend descriptor')
  const socket=new Socket({fd,readable:true,writable:true})
  const provider=env.DITTO_BACKEND_PROVIDER==='ditto_test'?'ditto_test':'openai'
  const codex=new CodexBackend(new StdioPeer(socket,socket),{modelProvider:provider,testProvider:env.DITTO_BACKEND_AUTH==='test-provider'})
  try{await codex.initialize();return codex}
  catch{codex.close();return undefined} // reported as backend_unsupported
}

async function main():Promise<void>{
  const env=process.env
  if(env.DITTO_CLIENT_KIND!=='agent'||!env.DITTO_CORE_SOCKET||!env.DITTO_CORE_TOKEN_FD)throw new Error('Core launcher identity is required')
  const fd=Number(env.DITTO_CORE_TOKEN_FD)
  if(!Number.isInteger(fd)||fd<3)throw new Error('invalid launcher descriptor')
  const token=readFileSync(fd,'utf8').trim();closeSync(fd)
  if(!token)throw new Error('empty launcher token')
  const link=await CoreLink.connectSocket(env.DITTO_CORE_SOCKET)
  const runtime=new AgentRuntime(link,await backend(env))
  let stopping:Promise<void>|undefined
  const stop=()=>stopping??=(async()=>{await runtime.stop();link.close()})()
  link.attach({request:(method,params)=>runtime.request(method,params),notification:(method,params)=>{
    if(method==='agent.controller.stop'){void stop();return}runtime.notification(method,params)
  },closed:()=>{void stop()}})
  await runtime.start()
  await link.handshake(token,{kind:'agent',version:env.DITTO_CLIENT_VERSION??'0.3.0'})
  await link.request('agent.runtime.ready',{})
  process.on('SIGTERM',()=>{void stop()});process.on('SIGINT',()=>{void stop()})
}
main().catch(()=>{process.stderr.write('Ditto Agent could not start; see Core diagnostics.\n');process.exitCode=1})
