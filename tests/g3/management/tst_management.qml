import QtQuick
import QtTest
import "../../../shell/centers" as Centers

// Real management component, with read-only Core snapshots/events supplied
// by this fixture. OS isolation and transactions are verified separately.
TestCase {
    id: testCase
    name: "GeneratedManagement"
    width: 800
    height: 1200
    visible: true
    when: windowShown
    property var tokens: ({space:8,spaceTight:4,spaceWide:12,controlHeight:32,radiusSmall:6,fontBody:13,fontSmall:11,fontTitle:17,fontFamily:"",foreground:"#ffffff",foregroundMuted:"#aaaaaa",warning:"#ffcc00",surface:"#333333",surfaceStrong:"#444444",border:"#666666",focus:"#ffffff",accent:"#8B5CF6",onAccent:"#ffffff",danger:"#ff0000"})
    QtObject {
        id: client
        property var artifacts: []
        property var jobs: []
        property var cancelled: []
        property bool holdJobs: false
        property var pendingSnapshots: []
        property bool holdArtifacts: false
        property var pendingArtifacts: []
        signal jobUpdated(var job)
        signal profileChanged(var payload)
        signal capabilitiesReloaded()
        function t(text) { return text; }
        function key(text,args) { return text; }
        function errorText(error) { return "request failed"; }
        function capability(method,args,success,failure) {
            if(method==="desktop.plugins.development.list") {
                if(holdArtifacts) pendingArtifacts=pendingArtifacts.concat([{reply:success,artifacts:artifacts.slice()}]);
                else success({artifacts:artifacts});
            }
            else if(method==="desktop.jobs.list") {
                if(holdJobs) pendingSnapshots=pendingSnapshots.concat([{reply:success,jobs:jobs.slice()}]);
                else success({jobs:jobs});
            }
            else if(method==="desktop.jobs.cancel") {
                cancelled=cancelled.concat([args.job_id]);
                jobs=jobs.map(job=>job.job_id===args.job_id?Object.assign({},job,{state:"cancelled",cancellable:false,updated_at:"2026-10-14T10:00:02Z"}):job);
                success({});
            }else fail("unexpected capability "+method);
        }
    }
    Component { id: factory; Centers.GeneratedArtifacts {} }
    function artifact() {
        return {artifact_id:"art-one",description:{title:"Panel",version:"1.0.0"},origin:{request_summary:"fixture"},parent_id:null,changed_fields:[],state:"active",repair:{stopped:false},validation_job_id:"validate-one",previews:[{job_id:"preview-one"},{job_id:"preview-two"}],validation:{stages:[{stage:"syntax",result:"passed"},{stage:"contract",result:"failed"},{stage:"load",result:"not_run"}]}};
    }
    function job(id,kind,state,phase) {
        return {job_id:id,kind:kind,state:state,phase:phase,cancellable:state==="running",updated_at:"2026-10-14T10:00:00Z"};
    }
    function init() {
        client.cancelled=[];
        client.holdJobs=false;client.pendingSnapshots=[];
        client.holdArtifacts=false;client.pendingArtifacts=[];
        client.artifacts=[artifact()];
        client.jobs=[job("validate-one","generation.validate","succeeded","interaction"),job("preview-one","generation.preview","running","preview_opened"),job("preview-two","generation.preview","running","preview_opened")];
    }
    function page() { return createTemporaryObject(factory,testCase,{client:client,tokens:testCase.tokens}); }
    function test_completed_job_does_not_claim_failed_validation_succeeded() {
        const view=page();
        const completed=job("failed-validation","generation.validate","succeeded","syntax");
        completed.result={boundary:{enforcement:"full"},stages:[{stage:"syntax",result:"failed"}]};
        compare(view.jobText(completed),view.stateText("failed"));
        completed.result.boundary.enforcement="partial";
        compare(view.jobText(completed),view.stateText("inspect_only"));
    }
    function test_reopen_restores_both_previews_and_keyboard_cancellation() {
        let view=page();
        verify(view!==null);
        compare(view.artifactJobs(client.artifacts[0]).length,2);
        view.destroy();
        wait(0);
        view=page();
        const first=findChild(view,"cancelGeneration_preview-one"),second=findChild(view,"cancelGeneration_preview-two");
        verify(first.visible && second.visible && first.enabled && second.enabled);
        compare(findChild(view,"generationJob_preview-one").text,"測試資料預覽已開啟");
        first.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(client.cancelled.length,1);
        compare(client.cancelled[0],"preview-one");
        verify(findChild(view,"cancelGeneration_preview-two").enabled);
        findChild(view,"cancelGeneration_preview-two").forceActiveFocus();
        keyClick(Qt.Key_Return);
        compare(client.cancelled[1],"preview-two");
        compare(view.artifactJobs(client.artifacts[0])[0].state,"cancelled");
    }
    function test_failure_stages_are_readable_and_not_run_is_not_passed() {
        const view=page();
        compare(findChild(view,"generationStage_art-one_syntax").text,"語法檢查 · 通過");
        compare(findChild(view,"generationStage_art-one_contract").text,"契約檢查 · 未通過");
        compare(findChild(view,"generationStage_art-one_load").text,"載入檢查 · 未執行");
    }
    function test_external_job_progress_survives_an_older_snapshot() {
        const next=artifact();
        next.validation_job_id="external";next.previews=[];next.state="validating";
        client.artifacts=[next];
        client.jobs=[job("external","generation.validate","running","syntax")];
        const view=page();
        client.holdJobs=true;
        view.reload();
        const current=job("external","generation.validate","running","focus");
        // Two real updates may share a timestamp. Arrival order still wins.
        client.jobs=[current];
        client.jobUpdated(current);
        compare(findChild(view,"generationJob_external").text,"焦點檢查");
        for(const snapshot of client.pendingSnapshots) snapshot.reply({jobs:snapshot.jobs});
        compare(findChild(view,"generationJob_external").text,"焦點檢查");
        const cancelling=Object.assign({},current,{state:"cancelling",updated_at:"2026-10-14T10:00:02Z"});
        client.jobUpdated(cancelling);
        compare(findChild(view,"generationJob_external").text,"正在取消並清理");
        verify(!findChild(view,"cancelGeneration_external").enabled);
    }
    function test_a_new_agent_job_is_discovered_without_reopening() {
        const view=page(),next=artifact();
        next.validation_job_id="new-agent-job";next.previews=[];next.state="validating";
        client.artifacts=[next];
        const current=job("new-agent-job","generation.validate","running","contract");
        client.jobs=[current];
        client.jobUpdated(current);
        compare(findChild(view,"generationJob_new-agent-job").text,"契約檢查");
        verify(findChild(view,"cancelGeneration_new-agent-job").enabled);
    }
    function test_an_older_artifact_reply_cannot_hide_a_new_job() {
        client.holdArtifacts=true;
        const view=page(),next=artifact();
        next.validation_job_id="new-agent-job";next.previews=[];next.state="validating";
        client.artifacts=[next];
        const current=job("new-agent-job","generation.validate","running","load");
        client.jobs=[current];
        client.jobUpdated(current);
        compare(client.pendingArtifacts.length,2);
        const newer=client.pendingArtifacts[1],older=client.pendingArtifacts[0];
        newer.reply({artifacts:newer.artifacts});
        older.reply({artifacts:older.artifacts});
        compare(findChild(view,"generationJob_new-agent-job").text,"載入檢查");
        verify(findChild(view,"cancelGeneration_new-agent-job").enabled);
    }
}
