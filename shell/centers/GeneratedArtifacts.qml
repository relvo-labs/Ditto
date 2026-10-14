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
    property int jobEventSerial: 0
    property var jobEventVersions: ({})
    property int reloadSerial: 0
    property string notice: ""
    property var record: null
    title: client.t(qsTr("生成的插件"))
    note: client.t(qsTr("顯示最近十個版本。每次修改都建立新版本並重新驗證；舊版本保留供檢查與回復。"))
    function reload() {
        const request=++page.reloadSerial;
        client.capability("desktop.plugins.development.list", {}, result => {
            if(request===page.reloadSerial) page.artifacts=result.artifacts;
        }, error => {if(request===page.reloadSerial) page.notice=client.errorText(error);});
        const requestedAt=page.jobEventSerial;
        client.capability("desktop.jobs.list", {}, result => {
            if(request!==page.reloadSerial) return;
            const next=Object.assign({},page.jobs);
            for(const job of result.jobs) {
                // A response requested before a received event must not
                // overwrite it, even if wall-clock timestamps are equal.
                if(!(page.jobEventVersions[job.job_id]>requestedAt)) next[job.job_id]=job;
            }
            page.jobs=next;
        }, error => {if(request===page.reloadSerial) page.notice=client.errorText(error);});
    }
    function artifactJobs(a) {
        const ids=[a.validation_job_id].concat((a.previews || []).map(p=>p.job_id));
        const known=ids.filter(id=>!!id && !!page.jobs[id]).map(id=>page.jobs[id]);
        const live=known.filter(job=>["queued","running","cancelling"].indexOf(job.state)>=0);
        return live.length ? live : known.sort((a,b)=>b.updated_at.localeCompare(a.updated_at)).slice(0,1);
    }
    function stageText(stage) {
        switch(stage) {
        case "syntax":return client.t(qsTr("語法檢查"));
        case "contract":return client.t(qsTr("契約檢查"));
        case "load":return client.t(qsTr("載入檢查"));
        case "focus":return client.t(qsTr("焦點檢查"));
        case "interaction":return client.t(qsTr("互動檢查"));
        case "preview_opened":return client.t(qsTr("測試資料預覽已開啟"));
        default:return client.t(qsTr("準備隔離環境"));
        }
    }
    function jobText(job) {
        switch(job.state) {
        case "queued":return client.t(qsTr("等待其他工作完成"));
        case "cancelling":return client.t(qsTr("正在取消並清理"));
        case "cancelled":return client.t(qsTr("已取消並完成清理"));
        case "failed":return client.t(qsTr("工作未完成，請檢查診斷後再試"));
        case "succeeded":return client.t(qsTr("工作已完成"));
        default:return stageText(job.phase);
        }
    }
    function resultText(result) {
        switch(result) {
        case "passed":return client.t(qsTr("通過"));
        case "failed":return client.t(qsTr("未通過"));
        default:return client.t(qsTr("未執行"));
        }
    }
    function cancelJob(job) {
        client.capability("desktop.jobs.cancel",{job_id:job.job_id},()=>page.reload(),error=>{page.notice=client.errorText(error);});
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
            if(result.job_id){const next=Object.assign({},page.jobs);next[result.job_id]=result;page.jobs=next;}
            if(result.change_id) page.record=result;
            page.reload();
        },error=>{page.notice=client.errorText(error);page.reload();});
    }
    Component.onCompleted: reload()
    Connections {
        target: page.client
        function onJobUpdated(job) {
            if(job.kind.indexOf("generation.")!==0) return;
            const known=!!page.jobs[job.job_id];
            page.jobEventSerial++;
            const versions=Object.assign({},page.jobEventVersions);
            versions[job.job_id]=page.jobEventSerial;
            page.jobEventVersions=versions;
            const next=Object.assign({},page.jobs);
            next[job.job_id]=job;
            page.jobs=next;
            if(!known || ["succeeded","failed","cancelled"].indexOf(job.state)>=0) page.reload();
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
            readonly property var work: page.artifactJobs(modelData)
            readonly property bool running: work.some(job=>["queued","running","cancelling"].indexOf(job.state)>=0)
            width:parent.width
            spacing:page.tokens.space
            Text {width:parent.width;text:item.modelData.description.title+" · "+item.modelData.description.version;textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foreground;font.bold:true}
            Text {width:parent.width;text:page.stateText(item.modelData.state);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foregroundMuted}
            Text {width:parent.width;text:page.client.t(qsTr("需求：%1")).arg(item.modelData.origin.request_summary);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foreground}
            Text {width:parent.width;visible:!!item.modelData.parent_id;text:page.client.t(qsTr("本版本修改：%1")).arg(item.modelData.changed_fields.map(field=>page.fieldName(field)).join(", "));textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foregroundMuted}
            Text {width:parent.width;visible:item.modelData.repair.stopped;text:page.client.t(qsTr("已停止自動修復。請檢查診斷，重新說明需求後再試。"));textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.warning}
            Repeater {
                model:item.work
                Column {
                    required property var modelData
                    width:item.width
                    Text {objectName:"generationJob_"+modelData.job_id;width:item.width;text:page.jobText(modelData);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:page.tokens.foreground}
                    Button {objectName:"cancelGeneration_"+modelData.job_id;tokens:page.tokens;visible:modelData.cancellable;enabled:modelData.state!=="cancelling";text:modelData.kind==="generation.preview"?page.client.t(qsTr("關閉測試資料預覽")):page.client.t(qsTr("取消驗證"));onClicked:page.cancelJob(modelData)}
                }
            }
            Repeater {
                model:item.modelData.validation ? item.modelData.validation.stages : []
                Text {required property var modelData;objectName:"generationStage_"+item.modelData.artifact_id+"_"+modelData.stage;width:item.width;text:page.stageText(modelData.stage)+" · "+page.resultText(modelData.result);textFormat:Text.PlainText;wrapMode:Text.Wrap;color:modelData.result==="failed"?page.tokens.warning:page.tokens.foregroundMuted}
            }
            Flow {
                width:parent.width
                spacing:page.tokens.space
                Button {tokens:page.tokens;visible:["candidate","inspect_only"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("驗證"));enabled:!item.running&&!item.modelData.repair.stopped;onClicked:page.operation(item.modelData,"validate")}
                Button {tokens:page.tokens;visible:["validated","published","active"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("開啟測試資料預覽"));enabled:!item.running;onClicked:page.operation(item.modelData,"preview")}
                Button {tokens:page.tokens;visible:item.modelData.state==="validated";text:page.client.t(qsTr("安裝這個版本"));onClicked:page.operation(item.modelData,"publish")}
                Button {tokens:page.tokens;visible:["published","active"].indexOf(item.modelData.state)>=0;text:page.client.t(qsTr("套用這個版本"));onClicked:page.operation(item.modelData,"activate")}
            }
            Diagnostics {width:parent.width;tokens:page.tokens;title:page.client.t(qsTr("原始碼、驗證與啟用紀錄"));text:JSON.stringify(item.modelData,null,2)}
        }
    }
}
