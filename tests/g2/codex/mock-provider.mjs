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
const say=text=>({type:'message',role:'assistant',id:'msg-'+Math.random().toString(36).slice(2),content:[{type:'output_text',text}]})

/** `decide(body)` returns the output items of one model response. */
export async function startProvider(decide){
  const requests=[],hanging=new Set(),closed=[]
  let count=0
  const server=http.createServer((req,res)=>{
    let body='';req.on('data',c=>body+=c);req.on('end',()=>{
      const parsed=body?JSON.parse(body):null
      requests.push({method:req.method,url:req.url,body:parsed,authorization:req.headers.authorization??null})
      if(!req.url.endsWith('/responses')){res.writeHead(404);res.end();return}
      const id='resp-'+(++count)
      let items
      try{items=decide(parsed)}catch(error){items=[say('mock provider error: '+error.message)]}
      if(items==='hang'){
        // A model that never finishes: the stream stays open until the
        // client goes away (interrupt, crash) or the server closes.
        res.writeHead(200,{'content-type':'text/event-stream'})
        res.write(`event: response.created\ndata: ${JSON.stringify({type:'response.created',response:{id}})}\n\n`)
        hanging.add(res);res.on('close',()=>{hanging.delete(res);closed.push(id)})
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
export {call,say}
