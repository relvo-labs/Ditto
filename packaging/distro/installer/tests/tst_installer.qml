import QtQuick
import QtTest
import "../../../../shell/installer" as Installer

// Offscreen screen/client tests with the #212 Socket double: replies are fed in
// by the test; nothing connects to a real backend.
TestCase {
    id: testCase
    name: "Installer"
    width: 1280; height: 800
    visible: true
    when: windowShown
    QtObject { id: testTranslator; function t(source) { return source; } }
    Component { id: clientFactory; Installer.InstallerClient {} }
    Component { id: screenFactory; Installer.InstallerScreen { translator: testTranslator } }

    readonly property var target: ({name: "nvme0n1", model: "WD SN770", vendor: "", serial: "SN-42",
                                     size_bytes: 512110190592, removable: false, read_only: false})
    function setup() {
        const client = createTemporaryObject(clientFactory, testCase);
        const screen = createTemporaryObject(screenFactory, testCase, {client: client, width: 1280, height: 800});
        return {client: client, screen: screen};
    }
    function sent(client) {
        return client.transport.sent.split("\n").filter(line => line.length > 0).map(line => JSON.parse(line));
    }
    function last(client) { const all = sent(client); return all[all.length - 1]; }
    function reply(client, message) { client.consume(JSON.stringify(message)); }
    function state(client, phase, extra) {
        client.poll();
        reply(client, Object.assign({ok: true, medium: "ready", state: phase, notice: null,
                                     progress: {stage: null, done: 0, total: 0}, result: null, rebooting: false},
                                    extra || {}));
    }
    function toList(t) {
        state(t.client, "listing");
        compare(last(t.client), {action: "list"});
        reply(t.client, {ok: true, disks: [
            Object.assign({token: "disk-token", reasons: []}, target),
            {name: "sdb", model: "USB Stick", vendor: "", serial: "", size_bytes: 32000000000, removable: true,
             read_only: false, token: null, reasons: ["install_medium", "removable"]}]});
    }
    function toConfirm(t) {
        toList(t);
        t.client.select("disk-token");
        compare(last(t.client), {action: "select", token: "disk-token"});
        reply(t.client, {ok: true, confirm_token: "confirm-token", disk: target});
    }

    function test_list_shows_eligible_and_excluded_disks() {
        const t = setup();
        compare(t.screen.view, "searching");
        toList(t);
        compare(t.screen.view, "list");
        compare(t.screen.diskButtons.count, 1);
        const button = t.screen.diskButtons.itemAt(0);
        verify(button.text.indexOf("WD SN770") >= 0 && button.text.indexOf("512.1 GB") >= 0
               && button.text.indexOf("SN-42") >= 0, button.text);
        tryVerify(() => button.activeFocus);
        const excluded = findChild(t.screen, "noDisk");
        verify(!excluded.visible);
    }

    function test_confirmation_shows_identity_and_defaults_to_cancel() {
        const t = setup();
        toConfirm(t);
        compare(t.screen.view, "confirm");
        verify(findChild(t.screen, "confirmModel").text.indexOf("WD SN770") >= 0);
        verify(findChild(t.screen, "confirmSize").text.indexOf("512.1 GB") >= 0);
        verify(findChild(t.screen, "confirmSize").text.indexOf("512110190592 bytes") >= 0);
        verify(findChild(t.screen, "confirmSerial").text.indexOf("SN-42") >= 0);
        verify(findChild(t.screen, "eraseWarning").text.indexOf("將清除整顆磁碟的全部資料") >= 0);
        tryVerify(() => t.screen.cancelConfirmButton.activeFocus);
        compare(t.screen.cancelConfirmButton.accessibleName, "取消");
        compare(t.screen.eraseButton.accessibleName, "清除並安裝");
        compare(t.screen.eraseButton.kind, "danger");
        keyClick(Qt.Key_Return);   // Enter on the default button cancels
        compare(last(t.client), {action: "back"});
        verify(sent(t.client).every(message => message.action !== "confirm"));
    }

    function test_erase_sends_only_the_token() {
        const t = setup();
        toConfirm(t);
        t.screen.eraseButton.clicked();
        compare(last(t.client), {action: "confirm", token: "confirm-token"});
        for (const message of sent(t.client))
            verify(Object.keys(message).every(key => key === "action" || key === "token"), JSON.stringify(message));
        reply(t.client, {ok: true, state: "installing"});
        compare(t.screen.view, "installing");
    }

    function test_progress_and_cancel_are_text() {
        const t = setup();
        toConfirm(t);
        t.screen.eraseButton.clicked();
        reply(t.client, {ok: true, state: "installing"});
        state(t.client, "installing", {progress: {stage: "write", done: 50, total: 100}});
        const stage = findChild(t.screen, "stageText");
        verify(stage.text.indexOf("正在寫入") >= 0 && stage.text.indexOf("50%") >= 0, stage.text);
        tryVerify(() => t.screen.cancelInstallButton.activeFocus);
        t.screen.cancelInstallButton.clicked();
        compare(last(t.client), {action: "cancel"});
        verify(stage.text.indexOf("正在取消") >= 0, stage.text);
        verify(!t.screen.cancelInstallButton.enabled);
    }

    function test_success_failure_and_reboot() {
        const t = setup();
        state(t.client, "succeeded", {result: {outcome: "succeeded", stage: "done", code: "ok",
                                               disk_state: "installed", detail: ""}});
        compare(t.screen.view, "done");
        verify(findChild(t.screen, "doneText").text.indexOf("請拔除安裝媒體") >= 0);
        tryVerify(() => t.screen.rebootButton.activeFocus);
        t.screen.rebootButton.clicked();
        compare(last(t.client), {action: "reboot"});

        const f = setup();
        state(f.client, "failed", {result: {outcome: "failed", stage: "verify", code: "payload_hash_mismatch",
                                            disk_state: "untouched", detail: ""}});
        compare(f.screen.view, "result");
        verify(findChild(f.screen, "resultText").text.indexOf("核對不符") >= 0);
        verify(findChild(f.screen, "diskStateText").text.indexOf("沒有被更動") >= 0);
        verify(findChild(f.screen, "doneText").text.length === 0 || !findChild(f.screen, "doneText").visible);
        tryVerify(() => f.screen.chooseAgainButton.activeFocus);
        f.screen.chooseAgainButton.clicked();
        compare(last(f.client), {action: "list"});
    }

    function test_medium_problem_and_lost_backend() {
        const t = setup();
        state(t.client, "starting", {medium: "medium_unavailable"});
        compare(t.screen.view, "medium");
        verify(findChild(t.screen, "mediumProblem").text.indexOf("找不到安裝媒體") >= 0);

        const l = setup();
        l.client.everConnected = true;
        toConfirm(l);
        l.screen.eraseButton.clicked();
        reply(l.client, {ok: true, state: "installing"});
        l.client.transport.connected = false;   // backend vanished mid-write
        verify(l.client.lost);
        compare(l.screen.view, "lost");
        verify(findChild(l.screen, "mediumProblem").text.indexOf("無法確認結果") >= 0);
        const before = sent(l.client).length;
        l.client.reboot();
        compare(sent(l.client).length, before);   // nothing is sent after a lost result
    }

    function test_rejections_refresh_or_stop() {
        const t = setup();
        toList(t);
        t.client.select("disk-token");
        reply(t.client, {ok: false, error: "unknown_disk"});
        compare(t.client.confirmation, null);
        compare(last(t.client), {action: "list"});
        verify(findChild(t.screen, "notice").visible);
        reply(t.client, {ok: false, error: "peer_rejected"});
        verify(t.client.lost);
    }
}
