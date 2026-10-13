import type {Readable,Writable} from 'node:stream'
/** Codex stdio uses JSON-RPC envelopes without a jsonrpc member. Keep that
 * protocol separate from Ditto's strict versioned Core envelopes. */
export class StdioPeer {
  private buffer=Buffer.alloc(0)
  private next=0
  private pending=new Map<string,{resolve:(value:unknown)=>void,reject:(error:Error)=>void,timer:NodeJS.Timeout}>()
  private ended=false
  private requests=new Set<string>()
  onNotification:(method:string,params:unknown)=>void=()=>{}
  onRequest:(method:string,params:unknown)=>Promise<unknown>=async()=>{throw new Error('unsupported backend request')}
  onClosed:(error:Error)=>void=()=>{}
  constructor(private input:Readable,private output:Writable,private limit=1_048_576){
    input.on('data',(chunk:Buffer)=>this.receive(chunk));input.on('error',error=>this.close(error))
    input.on('end',()=>this.close(new Error('backend disconnected')))
    output.on('error',error=>this.close(error))
  }
  request<T>(method:string,params:unknown,timeoutMs=10000):Promise<T>{
    if(this.ended)return Promise.reject(new Error('backend disconnected'))
    if(this.pending.size>=64)return Promise.reject(new Error('backend request budget exceeded'))
    const id=String(++this.next)
    return new Promise<T>((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('provider_timeout'))},timeoutMs);timer.unref()
      this.pending.set(id,{resolve:value=>resolve(value as T),reject,timer})
      try{this.send({id,method,params})}catch(error){this.pending.delete(id);clearTimeout(timer);reject(error)}
    })
  }
  notify(method:string,params:unknown):void{this.send({method,params})}
  private send(message:unknown):void{
    if(this.ended)throw new Error('backend disconnected')
    const bytes=Buffer.from(JSON.stringify(message)+'\n')
    if(bytes.length>this.limit)throw new Error('backend frame exceeds limit')
    if(this.output.writableLength+bytes.length>this.limit*2)throw new Error('backend output budget exceeded')
    this.output.write(bytes)
  }
  private receive(chunk:Buffer):void{
    if(this.ended)return
    // Node's pipe reads are bounded; reject a hostile custom transport before
    // copying an arbitrarily large chunk into a second allocation.
    if(chunk.length>this.limit*2){this.close(new Error('backend chunk exceeds limit'));return}
    this.buffer=Buffer.concat([this.buffer,chunk])
    while(!this.ended){
      const end=this.buffer.indexOf(10)
      if(end<0){if(this.buffer.length>this.limit)this.close(new Error('backend frame exceeds limit'));return}
      if(end>this.limit){this.close(new Error('backend frame exceeds limit'));return}
      const line=this.buffer.subarray(0,end);this.buffer=this.buffer.subarray(end+1)
      try{
        const value:unknown=JSON.parse(new TextDecoder('utf8',{fatal:true}).decode(line))
        if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('invalid backend envelope')
        const message=value as Record<string,unknown>
        if(message.jsonrpc!==undefined&&message.jsonrpc!=='2.0')throw new Error('unsupported backend envelope')
        this.dispatch(message)
      }catch(error){this.close(error instanceof Error?error:new Error('invalid backend frame'))}
    }
  }
  private dispatch(message:Record<string,unknown>):void{
    if(typeof message.method==='string'){
      if(message.id===undefined){this.onNotification(message.method,message.params);return}
      if(typeof message.id!=='string'&&typeof message.id!=='number')throw new Error('invalid backend request id')
      const key=String(message.id)
      if(this.requests.size>=24)throw new Error('backend tool request budget exceeded')
      if(this.requests.has(key))throw new Error('duplicate backend request id')
      this.requests.add(key)
      const response=(body:Record<string,unknown>)=>{this.requests.delete(key);if(!this.ended)this.send({id:message.id,...body})}
      void this.onRequest(message.method,message.params).then(result=>response({result}),()=>response({error:{code:-32601,message:'request denied by Ditto policy'}})).catch(error=>this.close(error))
      return
    }
    if(typeof message.id!=='string'&&typeof message.id!=='number')throw new Error('invalid backend response id')
    const wait=this.pending.get(String(message.id));if(!wait)return // late timed-out answer
    if(('result' in message)===('error' in message))throw new Error('invalid backend response')
    this.pending.delete(String(message.id));clearTimeout(wait.timer)
    if(message.error)wait.reject(new Error('provider_error'));else wait.resolve(message.result)
  }
  close(error=new Error('backend disconnected')):void{
    if(this.ended)return;this.ended=true
    for(const wait of this.pending.values()){clearTimeout(wait.timer);wait.reject(error)}
    this.pending.clear();this.input.destroy();this.output.destroy();this.onClosed(error)
  }
}
