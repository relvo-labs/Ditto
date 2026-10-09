// The loopback model for VM measurement logins (run-g2-measure.sh): the VM
// has no Codex subscription, so the session's Core is pointed at this
// stand-in on a fixed port. Every answer is about 130 characters streamed
// in ten-character pieces every 200 ms (about 2.6 s), like a short real
// answer. It measures Ditto's
// processes under turns, never a model or the network.
import {startProvider} from '../../tests/g2/codex/mock-provider.mjs'

const text='在 Ditto 桌面上，外觀可以調整主題、強調色、圓角、字級與間距，也可以開啟減少動畫或降低透明度。布局方面，可以把應用程式放在工作區的固定區域，例如左半邊放編輯器、右半邊放終端機，之後開啟的視窗也會照規則放置。這些變更都會成為可檢查、可撤銷的設定紀錄。'
const pieces=text.match(/.{1,10}/gs)
const provider=await startProvider(()=>[{type:'message',role:'assistant',id:'msg-'+Math.random().toString(36).slice(2),_stream:pieces,_delay:200}],Number(process.argv[2]??18080))
provider.requests.length=0
setInterval(()=>{provider.requests.length=0},60_000).unref?.()
console.log(`loopback model on 127.0.0.1:${provider.port}`)
