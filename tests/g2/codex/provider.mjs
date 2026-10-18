// Standalone scripted model for the desktop run (desktop.sh). Prints its
// port, then serves until killed; every request body goes to argv[2] as one
// JSON line. Scenario: read the profile, set the accent on its head
// revision, report from the real tool result.
import {appendFileSync} from 'node:fs'
import {startProvider,toolOutputs,userText,call,say,slowSay} from './mock-provider.mjs'

const log=process.argv[2]
const accent=process.argv[3]??'#3366ff'
const provider=await startProvider(body=>{
  appendFileSync(log,JSON.stringify(body)+'\n')
  const outputs=toolOutputs(body)
  if(userText(body).includes('慢慢說')){
    return [slowSay(['好的，','我會','一點一點','回答，','這是','串流','測試。'],400)]
  }
  if(userText(body).includes('附件')){
    const input=JSON.stringify(body.input)
    if(input.includes('input_image'))return [say('收到截圖。')]
    if(userText(body).includes('<ditto_context kind="clipboard"')&&userText(body).includes(process.env.DITTO_G2_CLIP??'\u0000'))return [say('收到剪貼簿。')]
    return [say('沒有看到附件。')]
  }
  if(userText(body).includes('設定檔')){
    // Deleting a Profile cannot be undone: Core asks the person each time.
    if(!outputs.has('list-profiles'))return [call('desktop__profiles__list',{},'list-profiles')]
    if(!outputs.has('delete-profile')){
      // The request names the Profile in 「」 (#91): first login has three,
      // so "the other one" would be a guess. No named, inactive match: no call.
      const named=[...userText(body).matchAll(/「([^」]+)」/g)].at(-1)?.[1]
      const spare=JSON.parse(outputs.get('list-profiles')).profiles.find(p=>!p.active&&p.name===named)
      if(!spare)return [say('找不到要刪除的設定檔。')]
      return [call('desktop__profiles__delete',{profile_id:spare.profile_id},'delete-profile')]
    }
    return [say(outputs.get('delete-profile').includes('"error"')?'設定檔沒有刪除。':'已刪除設定檔。')]
  }
  if(userText(body).includes('視窗')){
    // Reading windows needs the person's approval for the Agent.
    if(!outputs.has('list-windows'))return [call('desktop__windows__list',{},'list-windows')]
    const result=outputs.get('list-windows')
    let windows=null;try{windows=JSON.parse(result).windows}catch{}
    return [say(Array.isArray(windows)?`目前有 ${windows.length} 個視窗。`:'沒有取得視窗清單。')]
  }
  if(!outputs.has('read-profile'))return [call('desktop__profiles__get',{},'read-profile')]
  if(!outputs.has('set-accent')){
    const profile=JSON.parse(outputs.get('read-profile'))
    return [call('desktop__appearance__set',{base_revision:profile.profile.head_revision,tokens:{accent}},'set-accent')]
  }
  return [say(outputs.get('set-accent').includes('"committed"')?'已把強調色改成藍色。':'強調色沒有改成功。')]
})
console.log(provider.port)
