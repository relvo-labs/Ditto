import {randomUUID} from 'node:crypto'
import type {CoreChannel} from '../../host-runtime/src/bridge/core-link.ts'
import type {Conversation} from '../../protocol/src/generated/conversation.ts'
import type {SessionEvent} from '../../protocol/src/generated/session-event.ts'
import type {SessionOpenOutput} from '../../protocol/src/generated/session-open-output.ts'
import type {SessionReadOutput} from '../../protocol/src/generated/session-read-output.ts'

/** Harness SessionHandle semantics over Core's stronger append+fsync barrier.
 * Header creation, files, indexing and writer identity remain wholly in Core.
 * This is the supported event subset; it does not impersonate the full dsh
 * SessionHeader, forks, seeded logs or an on-disk Harness backend. */
export class CoreSessionHandle implements AsyncDisposable {
  private next:number
  private closing?:Promise<void>
  private tail:Promise<unknown>=Promise.resolve()
  private constructor(private core:CoreChannel,readonly header:Conversation,private lease:string) {this.next=header.next_seq}
  get id():string{return this.header.session_id}
  static async open(core:CoreChannel,id:string):Promise<CoreSessionHandle>{
    const opened=await core.request<SessionOpenOutput>('agent.sessions.open',{session_id:id})
    return new CoreSessionHandle(core,opened.session,opened.writer_lease)
  }
  async read(offset=0,limit=50):Promise<SessionReadOutput>{
    if(this.closing)throw new Error('session handle closed')
    return this.core.request('agent.sessions.read',{session_id:this.id,offset,limit})
  }
  append(kind:SessionEvent['type'],data:Record<string,unknown>):Promise<void>{
    if(this.closing)return Promise.reject(new Error('session handle closed'))
    const batchId=randomUUID()
    const work=this.tail.then(async()=>{
      // Core may have appended a user message or tool record meanwhile. Read
      // its current cursor; never overwrite or renumber accepted event bytes.
      const current=await this.core.request<Conversation>('agent.sessions.stat',{session_id:this.id})
      this.next=current.next_seq
      const session=await this.core.request<Conversation>('agent.sessions.append',{
        session_id:this.id,writer_lease:this.lease,batch_id:batchId,expected_next_seq:this.next,
        events:[{seq:this.next,type:kind,data}],
      })
      this.next=session.next_seq
    })
    // A failed append fences this handle's pending work. Re-open/re-read on
    // explicit recovery; no automatic retry of an unknown acknowledgement.
    this.tail=work
    return work
  }
  async flush():Promise<void>{
    if(this.closing)throw new Error('session handle closed')
    await this.tail
    await this.core.request('agent.sessions.flush',{session_id:this.id,writer_lease:this.lease})
  }
  close():Promise<void>{
    this.closing??=(async()=>{
      try{await this.tail}finally{await this.core.request('agent.sessions.close',{session_id:this.id,writer_lease:this.lease})}
    })()
    return this.closing
  }
  [Symbol.asyncDispose]():Promise<void>{return this.close()}
}
