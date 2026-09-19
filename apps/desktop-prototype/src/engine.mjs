export const defaults={name:'柔光果凍',theme:'lilac',dock:'bottom',layout:'floating',notifications:true,avatar:true,motion:true,scale:100,launcher:'grid',plugins:['dock','files','notes','launcher','weather','ditto'],widgets:[]};
export const copy=x=>JSON.parse(JSON.stringify(x));
export const labels={theme:'桌面配色',dock:'Dock 位置',layout:'視窗布局',notifications:'通知',avatar:'Ditto 角色',motion:'動態效果',scale:'Ditto 大小',launcher:'啟動器',plugins:'啟用模組',widgets:'桌面元件',name:'組合名稱'};
export const values={lilac:'柔光紫',mint:'薄荷綠',rose:'蜜桃粉',dark:'深夜紫',bottom:'底部',left:'左側',right:'右側',floating:'自由浮動',tiled:'雙欄平鋪',focus:'專注布局',grid:'應用網格',search:'搜尋式'};
export const catalog=[
{id:'dock',name:'Jelly Dock',icon:'dock',color:'violet',category:'介面',desc:'應用隨手可及。可放左側、右側或底部。',version:'1.0.0',deps:[],core:true},
{id:'files',name:'檔案空間',icon:'folder',color:'violet',category:'工作',desc:'整理專案、資料夾與你的靈感素材。',version:'1.0.0',deps:[]},
{id:'notes',name:'小小筆記',icon:'note',color:'peach',category:'工作',desc:'隨手記下想法，自動保存在此瀏覽器。',version:'1.0.0',deps:[]},
{id:'launcher',name:'應用啟動器',icon:'grid',color:'blue',category:'介面',desc:'搜尋或網格，選擇適合你的開啟方式。',version:'1.0.0',deps:[],core:true},
{id:'weather',name:'晴日天氣',icon:'sun',color:'peach',category:'元件',desc:'桌面角落的一點好天氣。使用示範資料。',version:'1.0.0',deps:[]},
{id:'ditto',name:'Ditto 助理',icon:'spark',color:'violet',category:'助理',desc:'活在桌面裡，隨時點一下就能對話。',version:'1.0.0',deps:[]},
{id:'terminal',name:'輕終端',icon:'terminal',color:'dark',category:'工作',desc:'前端命令示範，試試 help 或 ls。',version:'0.4.0',deps:[]},
{id:'tasks',name:'今日待辦',icon:'checklist',color:'mint',category:'元件',desc:'可勾選、可新增，讓下一步一目了然。',version:'1.1.0',deps:[]},
{id:'focus',name:'專注時鐘',icon:'clock',color:'rose',category:'元件',desc:'25 分鐘專注倒數，可開始、暫停與重設。',version:'1.0.0',deps:[]},
{id:'project',name:'專案摘要',icon:'layers',color:'blue',category:'元件',desc:'彙整待辦進度，會隨勾選狀態更新。',version:'0.8.0',deps:['tasks']}
];
export function display(key,v){if(key==='plugins')return v.map(id=>catalog.find(p=>p.id===id)?.name||id).join('、');if(key==='widgets')return v.length+' 個自訂元件';if(typeof v==='boolean')return v?'開啟':'關閉';if(key==='scale')return v+'%';return values[v]||String(v);}
export function diff(a,b){return Object.keys(defaults).filter(k=>JSON.stringify(a[k])!==JSON.stringify(b[k])).map(k=>({key:k,label:labels[k],before:display(k,a[k]),after:display(k,b[k])}));}
export function validate(c){if(!c||typeof c!=='object')throw Error('配置格式不正確');for(const [k,allowed] of Object.entries({theme:['lilac','mint','rose','dark'],dock:['bottom','left','right'],layout:['floating','tiled','focus'],launcher:['grid','search']}))if(!allowed.includes(c[k]))throw Error('不支援的'+labels[k]);if(!Array.isArray(c.plugins)||c.plugins.some(x=>!catalog.find(p=>p.id===x)))throw Error('包含未知模組');if(!['dock','launcher'].every(x=>c.plugins.includes(x)))throw Error('需要保留 Dock 與啟動器');for(const id of c.plugins){const p=catalog.find(p=>p.id===id);if(!p.deps.every(d=>c.plugins.includes(d)))throw Error(p.name+'需要「今日待辦」');}if(!Number.isFinite(c.scale)||c.scale<60||c.scale>120)throw Error('角色大小需介於 60–120%');for(const k of ['notifications','avatar','motion'])if(typeof c[k]!=='boolean')throw Error('設定格式不正確');if(typeof c.name!=='string'||c.name.length>40)throw Error('組合名稱不正確');if(!Array.isArray(c.widgets)||c.widgets.length>8||c.widgets.some(w=>!w||!['tasks','quote','clock','project'].includes(w.type)||typeof w.title!=='string'||w.title.length>60||typeof w.id!=='string'||w.id.length>80))throw Error('自訂元件格式不正確');return c;}
export function preset(kind,current=defaults){const c=copy(current);if(kind==='soft')Object.assign(c,copy(defaults));if(kind==='dev')Object.assign(c,{name:'開發工作室',dock:'left',layout:'tiled',notifications:false,launcher:'search',plugins:[...new Set([...c.plugins,'terminal','project','tasks'])]});if(kind==='focus')Object.assign(c,{name:'專注時刻',layout:'focus',notifications:false,plugins:[...new Set([...c.plugins,'focus'])]});if(kind==='present')Object.assign(c,{name:'簡報空間',dock:'bottom',layout:'focus',notifications:false,avatar:false,plugins:c.plugins.filter(x=>!['weather','focus','project','tasks'].includes(x))});return c;}
export function interpret(text,current){const t=text.trim();let next=copy(current),title='調整桌面',kind='配置修改',recognized=false;const add=id=>{next.plugins=[...new Set([...next.plugins,...(catalog.find(p=>p.id===id)?.deps||[]),id])];recognized=true;};
if(/還原|撤銷|undo|復原/i.test(t))return {action:'undo'};
if(/存成|保存|儲存|save/i.test(t)){const m=t.match(/(?:存成|保存為|儲存為|save as)\s*[「"『]?(.+?)[」"』]?$/i);return {action:'save',name:m?.[1]?.replace(/[」"』]$/,'').slice(0,40)};}
if(/紀錄|歷史|history/i.test(t))return {action:'center',tab:'history'};
if(/模組中心|插件中心|有哪些模組/i.test(t))return {action:'center',tab:'plugins'};
if(/組合中心|所有組合/i.test(t))return {action:'center',tab:'profiles'};
if(/工作區|workspace/i.test(t)){const m=t.match(/[1-4一二三四]/);if(m)return {action:'workspace',workspace:('一二三四'.includes(m[0])?'一二三四'.indexOf(m[0])+1:Number(m[0]))};}
if(/(?:做|建立|生成|新增|create|build).*(?:面板|元件|widget|小卡)/i.test(t)){const type=/專案|進度/.test(t)?'project':/待辦|任務|todo/i.test(t)?'tasks':/時鐘|時間|clock/i.test(t)?'clock':'quote';const m=t.match(/[「『"](.+?)[」』"]/);const names={tasks:'我的待辦',project:'專案進度',clock:'現在時間',quote:'每日一句'};next.widgets.push({id:'custom-'+Date.now(),type,title:m?.[1]?.slice(0,60)||names[type]});if(type==='project'||type==='tasks')add('tasks');kind='模板組合示範';title='建立'+(m?.[1]||names[type]);recognized=true;}
if(/開發|寫程式|coding|developer/i.test(t)&&!/關閉|停用/.test(t)){next=preset('dev',next);title='你的開發工作室';kind='跨模組組合';recognized=true;}
if(/简報|簡報|presentation/i.test(t)){next=preset('present',next);title='準備好簡報空間';kind='跨模組組合';recognized=true;}
if(/專注|focus/i.test(t)&&!/時鐘|取消|關閉/.test(t)){next=preset('focus',next);title='留給專注的空間';kind='跨模組組合';recognized=true;}
if(/柔光果凍|預設桌面|default/i.test(t)){next=preset('soft');title='回到柔光果凍';recognized=true;}
if(/左(?:邊|側)|left/i.test(t)&&/dock|工作列|工具列/i.test(t)){next.dock='left';recognized=true;}
if(/右(?:邊|側)|right/i.test(t)&&/dock|工作列|工具列/i.test(t)){next.dock='right';recognized=true;}
if(/底部|下方|下面|bottom/i.test(t)&&/dock|工作列|工具列/i.test(t)){next.dock='bottom';recognized=true;}
if(/深色|深夜|暗色|dark/i.test(t)){next.theme='dark';recognized=true;}
if(/薄荷|綠色|mint/i.test(t)){next.theme='mint';recognized=true;}
if(/粉色|粉紅|蜜桃|rose|pink/i.test(t)){next.theme='rose';recognized=true;}
if(/紫色|柔光紫|lilac/i.test(t)){next.theme='lilac';recognized=true;}
if(/平鋪|並排|整理|排列|til(e|ing)/i.test(t)){next.layout='tiled';recognized=true;}
if(/浮動|自由排列|floating/i.test(t)){next.layout='floating';recognized=true;}
if(/(?:關閉|暫停|不要|停用|關掉).*通知|勿擾|do not disturb/i.test(t)){next.notifications=false;recognized=true;}
if(/(?:開啟|恢復|取消勿擾).*通知|取消勿擾/.test(t)){next.notifications=true;recognized=true;}
if(/搜尋式|搜尋為主|search launcher/i.test(t)){next.launcher='search';recognized=true;}
if(/網格.*啟動器|網格式/.test(t)){next.launcher='grid';recognized=true;}
if(/(?:隱藏|關閉).*ditto|(?:隱藏|關閉).*角色/i.test(t)){next.avatar=false;recognized=true;}
if(/(?:顯示|開啟|恢復).*ditto|(?:顯示|開啟|恢復).*角色/i.test(t)){next.avatar=true;recognized=true;}
if(/小一點|縮小|smaller/i.test(t)){next.scale=Math.max(60,next.scale-15);recognized=true;}
if(/大一點|放大|bigger/i.test(t)){next.scale=Math.min(120,next.scale+15);recognized=true;}
if(/停止動畫|減少動畫|關閉動畫/.test(t)){next.motion=false;recognized=true;}
if(/開啟動畫|恢復動畫/.test(t)){next.motion=true;recognized=true;}
for(const [regex,id] of [[/待辦|todo/i,'tasks'],[/專注時鐘|番茄|timer/i,'focus'],[/專案摘要/,'project'],[/天氣|weather/i,'weather'],[/終端|terminal/i,'terminal']]){if(regex.test(t)&&!next.widgets.some(w=>w.id.startsWith('custom-')&&t.includes('面板'))){if(/移除|關閉|停用/.test(t)){next.plugins=next.plugins.filter(x=>x!==id&&(id!=='tasks'||x!=='project'));recognized=true;}else add(id);}}
if(/打開.*筆記|開啟.*筆記/.test(t))return {action:'open',app:'notes'};
if(/打開.*檔案|開啟.*檔案/.test(t))return {action:'open',app:'files'};
if(/保持.*(?:配色|顏色)|維持.*(?:配色|顏色)|保留.*(?:配色|原色)|keep.*color/i.test(t))next.theme=current.theme;
if(!recognized)return {action:'unsupported'};const changes=diff(current,next);return changes.length?{action:'plan',title,kind,next,changes}:{action:'noop'};
}
