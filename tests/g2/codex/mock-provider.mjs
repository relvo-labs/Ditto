// A loopback stand-in for the model service, speaking the Responses API
// subset Codex 0.160.0 streams. It is test scaffolding: it never measures or
// proves model quality, only the plumbing between Codex, Ditto and Core.
import http from 'node:http'

const sse=(res,events)=>{
  res.writeHead(200,{'content-type':'text/event-stream'})
  for(const event of events)res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)
  res.end()
}
const call=(name,args,id)=>({type:'function_call',name,arguments:JSON.stringify(args),call_id:id})
/** An answer streamed in pieces, `delay` ms apart. */
const slowSay=(pieces,delay)=>({type:'message',role:'assistant',id:'msg-'+Math.random().toString(36).slice(2),_stream:pieces,_delay:delay})
const say=text=>({type:'message',role:'assistant',id:'msg-'+Math.random().toString(36).slice(2),content:[{type:'output_text',text}]})

/** `decide(body)` returns the output items of one model response. */
export async function startProvider(decide){
  const requests=[],hanging=new Set(),closed=[]
  let count=0
  const server=http.createServer((req,res)=>{
    let body='';req.on('data',c=>body+=c);req.on('end',async()=>{
      const parsed=body?JSON.parse(body):null
      requests.push({method:req.method,url:req.url,body:parsed,authorization:req.headers.authorization??null})
      if(!req.url.endsWith('/responses')){res.writeHead(404);res.end();return}
      const id='resp-'+(++count)
      // `decide` may return a promise: a scripted model can wait for the
      // test to do something between two of its steps.
      let items
      try{items=await decide(parsed)}catch(error){items=[say('mock provider error: '+error.message)]}
      if(items==='hang'){
        // A model that never finishes: the stream stays open until the
        // client goes away (interrupt, crash) or the server closes.
        res.writeHead(200,{'content-type':'text/event-stream'})
        res.write(`event: response.created\ndata: ${JSON.stringify({type:'response.created',response:{id}})}\n\n`)
        hanging.add(res);res.on('close',()=>{hanging.delete(res);closed.push(id)})
        return
      }
      const streamed=items.find(item=>item._stream)
      if(streamed){
        // An answer written a piece at a time, as a real model streams it.
        res.writeHead(200,{'content-type':'text/event-stream'})
        const send=o=>res.write(`event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`)
        send({type:'response.created',response:{id}})
        const {_stream:pieces,_delay:delay,...item}=streamed
        send({type:'response.output_item.added',output_index:0,item:{...item,content:[]}})
        let i=0
        const next=()=>{
          if(i<pieces.length){send({type:'response.output_text.delta',item_id:item.id,output_index:0,content_index:0,delta:pieces[i++]});setTimeout(next,delay)}
          else{
            send({type:'response.output_item.done',output_index:0,item:{...item,content:[{type:'output_text',text:pieces.join('')}]}})
            send({type:'response.completed',response:{id,usage:{input_tokens:100,input_tokens_details:null,output_tokens:20,output_tokens_details:null,total_tokens:120}}})
            res.end()
          }
        }
        next()
        return
      }
      sse(res,[{type:'response.created',response:{id}},...items.map(item=>({type:'response.output_item.done',item})),
        {type:'response.completed',response:{id,usage:{input_tokens:100,input_tokens_details:null,output_tokens:20,output_tokens_details:null,total_tokens:120}}}])
    })
  })
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
  return {port:server.address().port,requests,closed,hanging:()=>hanging.size,
    close:()=>new Promise(resolve=>{for(const res of hanging)res.destroy();server.close(resolve)})}
}

/** Outputs of earlier tool calls in this request, keyed by call id. */
export function toolOutputs(body){
  const outputs=new Map()
  for(const item of body?.input??[])if(item.type==='function_call_output')outputs.set(item.call_id,typeof item.output==='string'?item.output:JSON.stringify(item.output))
  return outputs
}
export function userText(body){
  const texts=[]
  for(const item of body?.input??[])if(item.type==='message'&&item.role==='user')for(const part of item.content??[])if(part.type==='input_text')texts.push(part.text)
  return texts.join('\n')
}
export {call,say,slowSay}
