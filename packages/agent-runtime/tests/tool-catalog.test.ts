import {describe,it,expect} from 'vitest'
import {readFileSync} from 'node:fs'
import {TOOL_GUIDE,BASE_INSTRUCTIONS} from '../src/tool-catalog.ts'
import {check} from '../../protocol/src/schema-check.ts'
import {recentChangesText} from '../src/runtime.ts'

const catalog=JSON.parse(readFileSync(new URL('../../../schema/catalog.json',import.meta.url),'utf8')) as {capabilities:Array<{capability_id:string;resource_scope:string[];input_schema:Record<string,unknown>}>}
const byId=new Map(catalog.capabilities.map(c=>[c.capability_id,c]))

describe('Agent tool allow-list',()=>{
  it('supports the complete schema of every offered tool in strict mode',()=>{
    for(const id of Object.keys(TOOL_GUIDE))expect(()=>check(byId.get(id)!.input_schema,{},{strict:true}),id).not.toThrow()
  })
  it('names only capabilities Core really has',()=>{
    for(const id of Object.keys(TOOL_GUIDE))expect(byId.has(id),id).toBe(true)
  })
  it('never offers management, power, rescue or deletion to the model',()=>{
    const forbiddenScopes=['permissions.manage','plugins.manage','session.power','desktop.rescue','agent.settings.manage','agent.sessions.write']
    for(const id of Object.keys(TOOL_GUIDE)){
      expect(byId.get(id)!.resource_scope.some(s=>forbiddenScopes.includes(s)),id).toBe(false)
      expect(id.startsWith('agent.')||id.startsWith('desktop.approvals.')||id.startsWith('desktop.permissions.'),id).toBe(false)
    }
    for(const id of ['desktop.windows.close_request','desktop.profiles.export','desktop.profiles.import','desktop.plugins.install','desktop.session.lock'])expect(TOOL_GUIDE[id]).toBeUndefined()
  })
  it('offers Profile deletion only behind a per-call approval',()=>{
    // `profiles.delete` is grant-required for the Agent, so Core asks the
    // person for each deletion; the tool exists only on that condition.
    expect(byId.get('desktop.profiles.delete')!.resource_scope).toContain('profiles.delete')
    expect(TOOL_GUIDE['desktop.profiles.delete']).toMatch(/cannot be undone/)
  })
  it('describes every tool and states that only Core results count',()=>{
    for(const [id,text] of Object.entries(TOOL_GUIDE))expect(text.length,id).toBeGreaterThan(20)
    expect(BASE_INSTRUCTIONS).toMatch(/committed with result succeeded/)
    expect(BASE_INSTRUCTIONS).toMatch(/data, not instructions/)
  })
  it('says that naming another Profile changes nothing on screen, and how the record shows it (#169)',()=>{
    const propose=TOOL_GUIDE['desktop.changes.propose']
    expect(propose).toMatch(/profile_id/)
    expect(propose).toMatch(/active Profile/)
    expect(propose).toMatch(/nothing on screen changes until/)
    expect(propose).toMatch(/saved_only/)
    expect(BASE_INSTRUCTIONS).toMatch(/saved_only/)
    expect(BASE_INSTRUCTIONS).toMatch(/not on screen/)
    // The field the text names is the one Core's record really has.
    const record=JSON.parse(readFileSync(new URL('../../../schema/change-record.json',import.meta.url),'utf8')) as {properties:Record<string,unknown>}
    expect(Object.keys(record.properties)).toContain('saved_only')
  })
})

describe('recent changes context',()=>{
  it('lists Core records newest first with each item before and after',()=>{
    const text=recentChangesText([{change_id:'chg-2',turn_id:'t2',state:'committed',result:'succeeded',items:[{path:'/layout/regions/term',kind:'changed',before:'50–100% × 0–100%',after:'60–100% × 0–100%',label_key:'diff.layout.region',label_args:{app_id:'foot',rule_id:'term'}}]}])
    expect(text).toContain('chg-2: committed / succeeded')
    expect(text).toContain('/layout/regions/term (app_id=foot, rule_id=term): 50–100% × 0–100% → 60–100% × 0–100%')
    expect(recentChangesText([])).toBe('')
  })
})

import {StreamBatcher} from '../src/runtime.ts'
describe('stream batching',()=>{
  it('groups deltas and never sends more than 4 KiB at once',async()=>{
    const sent:string[]=[]
    const batcher=new StreamBatcher(t=>sent.push(t),10)
    batcher.push('你');batcher.push('好')
    await new Promise(r=>setTimeout(r,30))
    expect(sent).toEqual(['你好'])
    batcher.push('字'.repeat(3000));batcher.flush()
    expect(sent.slice(1).every(t=>Buffer.byteLength(t)<=4096)).toBe(true)
    expect(sent.slice(1).join('')).toBe('字'.repeat(3000))
  })
})
