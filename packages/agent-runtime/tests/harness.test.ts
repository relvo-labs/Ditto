import {describe,it,expect} from 'vitest'
import {BlockAssembler} from '../vendor/harness/llm/assembler.ts'
import {ToolCallId} from '../vendor/harness/llm/brand.ts'
import {snapshotJsonValue} from '../vendor/harness/values/index.ts'
describe('unchanged Harness value modules',()=>{
  it('preserves interrupted text but never invents a result for an unfinished tool',()=>{
    const a=new BlockAssembler()
    a.push({type:'text-delta',index:0,text:'調整中'})
    a.push({type:'tool-call-delta',index:1,id:ToolCallId('call'),name:'desktop',argumentsDelta:'{"ops":'})
    expect(a.interruptedBlocks()).toEqual([{type:'text',text:'調整中'}])
    a.push({type:'finish',reason:{kind:'max-tokens'}})
    expect(a.blocks()).toEqual([{type:'text',text:'調整中'}])
  })
  it('ignores late deltas after block closure and freezes assembled messages',()=>{
    const a=new BlockAssembler();a.push({type:'block-end',index:0,block:{type:'text',text:'done'}})
    a.push({type:'text-delta',index:0,text:' forged'})
    const m=a.message({provider:'test',model:'test'})
    expect(m.content).toEqual([{type:'text',text:'done'}]);expect(Object.isFrozen(m)).toBe(true);expect(Object.isFrozen(m.content)).toBe(true)
  })
  it('detaches argument values and rejects lossy or executable objects',()=>{
    const source={__proto__:null,value:[1,'中文']};const snapshot=snapshotJsonValue(source)!
    source.value[0]=2;expect(snapshot.value[0]).toBe(1)
    for(const value of [new Date(),NaN,Infinity,-0,{run:()=>{}},[undefined]])expect(snapshotJsonValue(value)).toBeUndefined()
    const cycle:Record<string,unknown>={};cycle.self=cycle;expect(snapshotJsonValue(cycle)).toBeUndefined()
  })
})
