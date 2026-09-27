import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
// core, jelly, ui and i18n are symlinks to the Shell's own directories:
// Quickshell 0.3.1 resolves only the first type of a directory imported from
// outside the configuration folder, so the shared files are linked in.
import "core"
import "jelly"
import "ui"

/// The rescue UI (plan/03/05 §3, D-29): a Quickshell configuration of its
/// own, connected to Core as `rescue-shell`. It loads no character, no
/// provider, no center and no plugin QML — only what is needed when the
/// desktop is broken:
///
///   · the open windows (focus, ask to close)
///   · 「停用最近變更的插件」   desktop.rescue.disable
///   · 「恢復最近可用組合」     desktop.rescue.restore_last_good
///   · 「顯示診斷」            desktop.rescue.status + desktop.plugins.diagnostics
///
/// It prints `ditto-rescue ready` once its surface is up and takes input.
/// If Quickshell itself cannot start, ditto-rescue-ui falls back to
/// `dittoctl rescue` in foot; the same fallback is offered here when Core
/// cannot be reached.
ShellRoot {
    id: root

    property var status: null
    property var diagnostics: null
    property var recentEntries: []
    property var lastRecord: null
    property string notice: ""
    property bool showDiagnostics: false
    property bool announced: false
    property string requestReason: ""

    function t(source) {
        return translator.t(source);
    }

    Tr {
        id: translator
        locale: Quickshell.env("DITTO_LOCALE") || "zh-TW"
    }

    Tokens {
        id: theme
        // Rescue is opaque and still: nothing here may depend on the look.
        appearance: ({ theme: "soft-jelly", reduced_transparency: true, reduced_motion: true, low_power_style: true, locale: translator.locale })
    }

    DittoClient {
        id: client
        // Launched by Core, the kind comes from the launcher (it is bound to
        // the token); started any other way, this is the rescue UI's kind.
        clientKind: Quickshell.env("DITTO_CLIENT_KIND") || "rescue-shell"
        topics: ["desktop", "changes", "session"]
        loadDesktopState: false
        tr: translator
        onOnlineChanged: if (online) root.refresh()
    }

    function refresh() {
        client.capability("desktop.rescue.status", {}, function (result) {
            root.status = result;
            root.findRecentEntries();
        }, function (error) {
            root.notice = client.errorText(error);
        });
    }

    /// The plugins changed since the last composition known to work: the
    /// entries a diff between that revision and the head adds or changes.
    function findRecentEntries() {
        if (!status || !status.last_known_good || !status.head_revision || status.last_known_good === status.head_revision) {
            recentEntries = [];
            return;
        }
        client.capability("desktop.profiles.diff", { from: { revision_id: status.last_known_good }, to: { revision_id: status.head_revision } }, function (result) {
            const seen = {};
            const list = [];
            for (const item of result.items) {
                const match = /^\/entries\/([^/]+)/.exec(item.path);
                if (match && !seen[match[1]] && item.kind !== "removed") {
                    seen[match[1]] = true;
                    list.push({ entryId: match[1], packageId: (item.label_args && item.label_args.package) || "" });
                }
                if (item.label_key === "diff.slot.changed" && item.after && !seen[item.after]) {
                    seen[item.after] = true;
                    list.push({ entryId: item.after, packageId: (item.label_args && item.label_args.to_package) || "" });
                }
            }
            root.recentEntries = list;
        }, function (error) {
            root.recentEntries = [];
        });
    }

    function disable(entry) {
        notice = t(qsTr("正在停用…"));
        client.capability("desktop.rescue.disable", { target: entry.entryId, idempotency_key: client.newKey("rescue") }, function (record) {
            root.lastRecord = record;
            root.notice = record.state === "committed" ? t(qsTr("已停用。可以回到一般模式再重新啟用。")) : t(qsTr("沒有停用成功，原本的組合沒有改變。"));
            root.refresh();
        }, function (error) {
            root.notice = client.errorText(error);
        });
    }

    function restoreLastGood() {
        notice = t(qsTr("正在恢復…"));
        client.capability("desktop.rescue.restore_last_good", { idempotency_key: client.newKey("rescue") }, function (record) {
            root.lastRecord = record;
            root.notice = record.state === "committed" ? t(qsTr("已恢復最近可用的組合。")) : t(qsTr("沒有恢復成功，目前的組合沒有改變。"));
            root.refresh();
        }, function (error) {
            root.notice = client.errorText(error);
        });
    }

    function loadDiagnostics() {
        showDiagnostics = !showDiagnostics;
        if (!showDiagnostics) {
            return;
        }
        refresh();
        client.capability("desktop.plugins.diagnostics", {}, function (result) {
            root.diagnostics = result;
        }, function (error) {
            root.diagnostics = { error: client.diagnosticText(error) };
        });
    }

    function textRescue() {
        const dittoctl = Quickshell.env("DITTO_DITTOCTL") || "dittoctl";
        Quickshell.execDetached(["foot", "--title", "Ditto rescue", "--", dittoctl, "rescue"]);
    }

    /// Why the rescue UI is up, from the supervisor's runtime record.
    FileView {
        path: (Quickshell.env("DITTO_RUNTIME_DIR") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ditto")) + "/rescue-request.json"
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                root.requestReason = JSON.parse(text()).reason || "";
            } catch (error) {
                root.requestReason = "";
            }
        }
    }

    PanelWindow {
        id: window

        anchors { top: true; bottom: true; left: true }
        implicitWidth: 560
        exclusionMode: ExclusionMode.Ignore
        color: theme.background
        focusable: true
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "ditto-rescue"

        onBackingWindowVisibleChanged: {
            if (backingWindowVisible && !root.announced) {
                root.announced = true;
                console.log("ditto-rescue ready");
            }
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 24
            contentHeight: content.implicitHeight
            clip: true

            Column {
                id: content
                width: parent.width
                spacing: 16

                Text {
                    text: root.t(qsTr("Ditto 救援模式"))
                    color: theme.foreground
                    font.pixelSize: theme.fontHeading
                    font.bold: true
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.requestReason === "shell_unresponsive"
                        ? root.t(qsTr("桌面介面沒有回應，已被停止。你的應用程式仍在執行，未儲存的內容沒有被關閉。"))
                        : root.requestReason === "core_failure"
                        ? root.t(qsTr("桌面服務一再失敗。你的應用程式仍在執行，未儲存的內容沒有被關閉。"))
                        : root.t(qsTr("桌面沒有正常啟動。你的應用程式仍在執行，未儲存的內容沒有被關閉。"))
                    color: theme.foreground
                    font.pixelSize: theme.fontBody
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: client.online ? client.status : root.t(qsTr("連不上桌面服務。可以改用文字救援工具。"))
                    color: client.online ? theme.foregroundMuted : theme.warning
                    font.pixelSize: theme.fontSmall
                }

                Button {
                    visible: !client.online
                    tokens: theme
                    kind: "primary"
                    text: root.t(qsTr("開啟文字救援工具"))
                    onClicked: root.textRescue()
                }

                Text {
                    visible: root.notice.length > 0
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.notice
                    color: theme.warning
                    font.pixelSize: theme.fontBody
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }

                Text {
                    text: root.t(qsTr("開啟中的視窗"))
                    color: theme.foreground
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                }

                Text {
                    visible: client.windows.length === 0
                    text: client.online ? root.t(qsTr("沒有開啟中的視窗")) : ""
                    color: theme.foregroundMuted
                    font.pixelSize: theme.fontBody
                }

                Repeater {
                    model: client.windows

                    Row {
                        required property var modelData
                        spacing: 8
                        Text {
                            width: 300
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: (modelData.focused ? "▸ " : "") + modelData.title + "  ·  " + modelData.app_id
                            color: theme.foreground
                            font.pixelSize: theme.fontBody
                        }
                        Button {
                            tokens: theme
                            text: root.t(qsTr("聚焦"))
                            visible: client.capabilityAvailable("desktop.windows.focus")
                            onClicked: client.focusWindow(modelData.id)
                        }
                        Button {
                            tokens: theme
                            kind: "subtle"
                            text: root.t(qsTr("要求關閉"))
                            accessibleName: root.t(qsTr("要求關閉「%1」")).arg(modelData.title)
                            visible: client.capabilityAvailable("desktop.windows.close_request")
                            onClicked: client.closeWindow(modelData.id)
                        }
                    }
                }

                Text {
                    text: root.t(qsTr("修復"))
                    color: theme.foreground
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.t(qsTr("停用最近變更的插件"))
                    color: theme.foreground
                    font.pixelSize: theme.fontBody
                    font.bold: true
                }

                Text {
                    visible: root.recentEntries.length === 0
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.status && root.status.last_known_good
                        ? root.t(qsTr("和最近可用的組合相比，沒有新加入或變更的插件。"))
                        : root.t(qsTr("還沒有最近可用的組合可以比較。"))
                    color: theme.foregroundMuted
                    font.pixelSize: theme.fontSmall
                }

                Repeater {
                    model: root.recentEntries
                    Button {
                        required property var modelData
                        tokens: theme
                        text: root.t(qsTr("停用「%1」")).arg(modelData.packageId || modelData.entryId)
                        enabled: client.online
                        onClicked: root.disable(modelData)
                    }
                }

                Button {
                    tokens: theme
                    kind: "primary"
                    text: root.t(qsTr("恢復最近可用組合"))
                    enabled: client.online && !!root.status && !!root.status.last_known_good
                    onClicked: root.restoreLastGood()
                }

                Button {
                    tokens: theme
                    text: root.showDiagnostics ? root.t(qsTr("隱藏診斷")) : root.t(qsTr("顯示診斷"))
                    onClicked: root.loadDiagnostics()
                }

                TextEdit {
                    visible: root.showDiagnostics
                    width: parent.width
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    color: theme.foregroundMuted
                    font.pixelSize: theme.fontSmall
                    font.family: "monospace"
                    text: JSON.stringify({ status: root.status, diagnostics: root.diagnostics, last_change: root.lastRecord }, null, 2)
                }
            }
        }
    }
}
