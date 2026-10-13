import {describe,it,expect} from 'vitest'
import {PassThrough} from 'node:stream'
import {StdioPeer} from '../src/framing.ts'

function setup(limit=1024){
  const incoming=new PassThrough(),outgoing=new PassThrough(),lines:string[]=[]
  outgoing.on('data',chunk=>lines.push(String(chunk)))
  const peer=new StdioPeer(incoming,outgoing,limit)
  return {peer,incoming,lines}
}
describe('Codex framing',()=>{
  it('accepts split UTF-8 and numeric response ids, without a jsonrpc member',async()=>{
    const s=setup();const result=s.peer.request('test',{})
    const bytes=Buffer.from(JSON.stringify({id:1,result:{text:'中文'}})+'\n')
    const split=bytes.indexOf(Buffer.from('中文'))+1
    s.incoming.write(bytes.subarray(0,split));s.incoming.write(bytes.subarray(split))
    expect(await result).toEqual({text:'中文'});s.peer.close()
  })
  it('fails every waiter on malformed envelopes instead of guessing a result',async()=>{
    const s=setup();const result=s.peer.request('test',{});const failure=expect(result).rejects.toThrow('invalid backend response')
    s.incoming.write('{"id":"1","result":{},"error":{}}\n');await failure
  })
  it('rejects invalid UTF-8 and oversized incomplete frames',async()=>{
    for(const frame of [Buffer.from([0xff,0x0a]),Buffer.alloc(129,65)]){
      const s=setup(128);const result=s.peer.request('test',{});const failure=expect(result).rejects.toThrow()
      s.incoming.write(frame);await failure
    }
  })
  it('denies duplicate outstanding backend request ids',async()=>{
    const s=setup();s.peer.onRequest=()=>new Promise(()=>{})
    const result=s.peer.request('test',{});const failure=expect(result).rejects.toThrow('duplicate')
    s.incoming.write('{"id":7,"method":"item/tool/call","params":{}}\n{"id":7,"method":"item/tool/call","params":{}}\n');await failure
  })
  it('bounds pending requests by their deadline and ignores late acknowledgements',async()=>{
    const s=setup();await expect(s.peer.request('test',{},5)).rejects.toThrow('provider_timeout')
    s.incoming.write('{"id":"1","result":{}}\n')
    const next=s.peer.request('next',{});s.incoming.write('{"id":"2","result":{"ok":true}}\n')
    expect(await next).toEqual({ok:true});s.peer.close()
  })
})
