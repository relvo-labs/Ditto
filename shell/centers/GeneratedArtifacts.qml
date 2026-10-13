pragma ComponentBehavior: Bound
import QtQuick
import "../ui"
import "../change"

// A view of Core's durable artifacts, never a second artifact store.
Section {
    id: page
    required property var client
    property var artifacts: []
    property var jobs: ({})
    property string notice: ""
    property var record: null
    title: client.t(qsTr("生成的插件"))
    note: client.t(qsTr("顯示最近十個版本。每次修改都建立新版本並重新驗證；舊版本保留供檢查與回復。"))
    function reload() {
        client.capability("desktop.plugins.development.list", {}, result => { page.artifacts=result.artifacts; }, error => {page.notice=client.errorText(error);});
    }
    function stateText(state) {
        switch(state) {
        case "candidate": return client.t(qsTr("等待驗證"));
        case "validating": return client.t(qsTr("正在隔離環境中驗證"));
        case "inspect_only": return client.t(qsTr("隔離條件不足，只能檢查"));
        case "validated": return client.t(qsTr("驗證通過，尚未安裝"));
        case "published": return client.t(qsTr("已安裝，尚未啟用"));
        case "active": return client.t(qsTr("曾成功啟用；目前組合請見下方"));
        default: return client.t(qsTr("未通過，請檢查診斷並建立修正版"));
        }
    }
    function fieldName(field) {
        switch(field) {case "title":return client.t(qsTr("標題"));case "width":return client.t(qsTr("寬度"));case "accent":return client.t(qsTr("強調色"));case "content":return client.t(qsTr("顯示內容"));case "data":return client.t(qsTr("資料格式"));default:return "";}
    }
    function operation(a, action) {
        let input={artifact_id:a.artifact_id};
        if(action==="validate" || action==="preview" || action==="activate") input.idempotency_key="generated-"+action+"-"+Date.now();
        if(action==="activate") input.base_revision=client.headRevision;
        client.capability("desktop.plugins.development."+action,input,result=>{
            if(result.job_id){const next=Object.assign({},page.jobs);next[a.artifact_id]=result;page.jobs=next;}
            if(result.change_id) page.record=result;
            page.reload();
        },error=>{page.notice=client.errorText(error);page.reload();});
    }
    Component.onCompleted: reload()
    Connections {
        target: page.client
        function onJobUpdated(job) {
            const next=Object.assign({},page.jobs);
            for(const id in next) if(next[id].job_id===job.job_id) next[id]=job;
            page.jobs=next;
            if(["succeeded","failed","cancelled"].indexOf(job.state)>=0) page.reload();
        }
        function onProfileChanged(payload) { page.reload(); }
        function onCapabilitiesReloaded() { page.reload(); }
    }
    Text { width:parent.width;visible:page.notice.length>0;text:page.notice;textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.warning }
    ChangeCard {width:parent.width;visible:!!page.record;client:page.client;tokens:page.tokens;record:page.record}
    Repeater {
        model: page.artifacts
        Column {
            id: item
            required property var modelData
            readonly property var job: page.jobs[modelData.artifact_id] || null
            readonly property bool running: !!job && ["queued","running","cancelling"].indexOf(job.state)>=0
            width:parent.width
            spacing:page.tokens.space
            Text {width:parent.width;text:item.modelData.description.title+" · "+item.modelData.description.version;textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foreground;font.bold:true}
            Text {width:parent.width;text:page.stateText(item.modelData.state);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foregroundMuted}
            Text {width:parent.width;text:page.client.t(qsTr("需求：%1")).arg(item.modelData.origin.request_summary);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foreground}
            Text {width:parent.width;visible:!!item.modelData.parent_id;text:page.client.t(qsTr("本版本修改：%1")).arg(item.modelData.changed_fields.map(field=>page.fieldName(field)).join(", "));textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foregroundMuted}
            Text {visible:item.modelData.repair.stopped;text:page.client.t(qsTr("已達修復上限，停止自動重試。"));color:page.tokens.warning}
            Flow {
                width:parent.width
                spacing:page.tokens.space
                Button {tokens:page.tokens;visible:["candidate","inspect_only"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("驗證"));enabled:!item.running&&!item.modelData.repair.stopped;onClicked:page.operation(item.modelData,"validate")}
                Button {tokens:page.tokens;visible:["validated","published","active"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("開啟測試資料預覽"));enabled:!item.running;onClicked:page.operation(item.modelData,"preview")}
                Button {tokens:page.tokens;visible:item.modelData.state==="validated";text:page.client.t(qsTr("安裝這個版本"));onClicked:page.operation(item.modelData,"publish")}
                Button {tokens:page.tokens;visible:["published","active"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("套用這個版本"));onClicked:page.operation(item.modelData,"activate")}
                Button {tokens:page.tokens;visible:item.running;text:page.client.t(qsTr("取消"));onClicked:page.client.capability("desktop.jobs.cancel",{job_id:item.job.job_id},()=>page.reload(),error=>{page.notice=page.client.errorText(error);})}
            }
            Diagnostics {width:parent.width;tokens:page.tokens;title:page.client.t(qsTr("原始碼、驗證與啟用紀錄"));text:JSON.stringify(item.modelData,null,2)}
        }
    }
}
