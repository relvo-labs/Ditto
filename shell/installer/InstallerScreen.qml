pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import "jelly"
import "ui" as Ui

// Whole-disk installer (#221). Every state is stated in words; colour only
// repeats it. Destructive confirmation defaults to Cancel.
Item {
    id: screen
    required property var translator
    required property var client
    readonly property string view: client.lost ? "lost"
        : client.medium === "searching" ? "searching"
        : client.medium !== "ready" ? "medium"
        : client.phase === "confirming" && client.confirmation ? "confirm"
        : client.phase === "installing" ? "installing"
        : client.phase === "succeeded" ? "done"
        : client.phase === "failed" || client.phase === "cancelled" ? "result"
        : client.phase === "listing" ? "list" : "searching"
    readonly property var eligible: (client.disks || []).filter(d => typeof d.token === "string" && d.token.length > 0)
    readonly property var excluded: (client.disks || []).filter(d => !d.token)
    readonly property var chosen: client.confirmation ? client.confirmation.disk : null
    property bool cancelRequested: false
    property alias cancelConfirmButton: cancelConfirm
    property alias eraseButton: erase
    property alias cancelInstallButton: cancelInstall
    property alias rebootButton: rebootDone
    property alias chooseAgainButton: chooseAgain
    property alias diskButtons: diskRepeater

    function t(source) { return translator.t(source); }
    function sizeText(bytes) {
        const units = [["TB", 1e12], ["GB", 1e9], ["MB", 1e6]];
        for (const [unit, scale] of units)
            if (bytes >= scale) return (bytes / scale).toFixed(1) + " " + unit;
        return bytes + " B";
    }
    function unknown(value) { return value && value.length > 0 ? value : t(qsTr("（無法讀取）")); }
    function focusDefault() {
        if (view === "confirm") cancelConfirm.forceActiveFocus();
        else if (view === "installing") cancelInstall.forceActiveFocus();
        else if (view === "done") rebootDone.forceActiveFocus();
        else if (view === "result") chooseAgain.forceActiveFocus();
        else if (view === "list") {
            const first = diskRepeater.count > 0 ? diskRepeater.itemAt(0) : null;
            if (first) first.forceActiveFocus(); else refresh.forceActiveFocus();
        } else if (view === "medium") rebootMedium.forceActiveFocus();
    }
    onViewChanged: {
        if (view !== "installing") cancelRequested = false;
        Qt.callLater(focusDefault);
    }
    onEligibleChanged: if (view === "list") Qt.callLater(focusDefault)

    InstallerMessages { id: messages }
    Tokens {
        id: style
        readsSystemPreference: false
        appearance: ({theme: "soft-jelly-light", tokens: {ui_style: "j1", font_family: "Noto Sans CJK TC"}})
    }
    Backdrop { anchors.fill: parent; tokens: style; wallpaperSource: style.wallpaper }
    component Copy: Text {
        color: "#423c5e"
        font.family: style && style.fontFamily ? style.fontFamily : "Noto Sans CJK TC"
        font.pixelSize: 15
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
    component Heading: Copy {
        color: style.uiInk
        font.pixelSize: 28
        font.bold: true
        Accessible.role: Accessible.Heading
    }
    component Status: Copy {
        // Announced on change, so a screen reader hears progress and results.
        Accessible.role: Accessible.AlertMessage
        onTextChanged: () => { if (visible && text.length > 0) Accessible.announce(text, Accessible.Polite); }
    }
    Copy {
        x: 28; y: 24
        text: screen.t(qsTr("Ditto · 安裝"))
        font.pixelSize: 18
        font.bold: true
    }
    Flickable {
        id: scroll
        x: Math.max(24, screen.width * 0.075)
        y: 76
        width: Math.min(640, screen.width - 48)
        height: Math.max(0, screen.height - y - 68)
        contentWidth: width
        contentHeight: Math.max(height, card.height + 16)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Item {
            id: card
            x: 4
            y: Math.max(8, (scroll.height - height) / 2)
            width: scroll.width - 8
            height: body.implicitHeight + 48
            Ui.JellySurface { anchors.fill: parent; tokens: style; fill: style.uiSheet; iris: true; radius: style.uiRadiusWindow }
            Column {
                id: body
                x: 28; y: 24
                width: card.width - 56
                spacing: 14

                // -- looking for the medium / medium problem / service lost ----------
                Status {
                    width: parent.width
                    visible: screen.view === "searching"
                    text: screen.t(messages.status("searching"))
                }
                Column {
                    width: parent.width; spacing: 14
                    visible: screen.view === "medium" || screen.view === "lost"
                    Heading { width: parent.width; text: screen.t(qsTr("無法開始安裝")) }
                    Status {
                        objectName: "mediumProblem"
                        width: parent.width
                        text: screen.t(messages.result(screen.view === "lost" ? "service_lost" : screen.client.medium))
                        color: style.uiDanger
                    }
                    Ui.Button {
                        id: rebootMedium
                        visible: screen.view === "medium"
                        enabled: visible
                        tokens: style
                        text: screen.t(qsTr("重新開機"))
                        onClicked: screen.client.reboot()
                    }
                }

                // -- choose a disk ----------------------------------------------------
                Column {
                    width: parent.width; spacing: 12
                    visible: screen.view === "list"
                    Heading { width: parent.width; text: screen.t(qsTr("選擇要安裝 Ditto 的磁碟")) }
                    Copy {
                        width: parent.width
                        text: screen.t(qsTr("Ditto 會使用整顆磁碟，選好之後還會再確認一次。隨身碟等可移除裝置不能當作安裝目標。"))
                    }
                    Status {
                        objectName: "notice"
                        width: parent.width
                        visible: screen.client.notice.length > 0 || screen.client.lastError.length > 0
                        text: screen.client.notice.length > 0 ? screen.t(messages.result(screen.client.notice))
                            : screen.t(messages.result("stale_action"))
                        color: style.uiDanger
                    }
                    Repeater {
                        id: diskRepeater
                        model: screen.eligible
                        delegate: Ui.Button {
                            required property var modelData
                            width: body.width
                            tokens: style
                            text: screen.unknown(modelData.model) + "  " + screen.sizeText(modelData.size_bytes)
                                + "  " + screen.t(qsTr("序號")) + " " + screen.unknown(modelData.serial)
                            Accessible.description: screen.t(qsTr("選擇這顆磁碟。下一步會再確認，不會立刻清除。"))
                            onClicked: screen.client.select(modelData.token)
                        }
                    }
                    Copy {
                        objectName: "noDisk"
                        width: parent.width
                        visible: screen.eligible.length === 0
                        text: screen.t(messages.status("no_disk"))
                        font.bold: true
                    }
                    Copy {
                        width: parent.width
                        visible: screen.excluded.length > 0
                        text: screen.t(qsTr("不能安裝的磁碟："))
                        font.bold: true
                    }
                    Repeater {
                        model: screen.excluded
                        delegate: Copy {
                            required property var modelData
                            width: body.width
                            text: "• " + screen.unknown(modelData.model) + "  " + screen.sizeText(modelData.size_bytes) + ": "
                                + (modelData.reasons || []).map(code => screen.t(messages.excluded(code))).join(" ")
                        }
                    }
                    Row {
                        spacing: 12
                        Ui.Button { id: refresh; tokens: style; text: screen.t(qsTr("重新整理")); onClicked: screen.client.refresh() }
                        Ui.Button { tokens: style; text: screen.t(qsTr("重新開機")); onClicked: screen.client.reboot() }
                    }
                }

                // -- second confirmation ------------------------------------------------
                Column {
                    width: parent.width; spacing: 12
                    visible: screen.view === "confirm"
                    Heading { width: parent.width; text: screen.t(qsTr("確認要清除這顆磁碟嗎？")) }
                    Copy { objectName: "confirmModel"; width: parent.width
                        text: screen.t(qsTr("型號")) + ": " + screen.unknown(screen.chosen ? screen.chosen.model : "") }
                    Copy { objectName: "confirmSize"; width: parent.width
                        text: screen.t(qsTr("容量")) + ": " + (screen.chosen ? screen.sizeText(screen.chosen.size_bytes) + " ("
                            + screen.chosen.size_bytes + " bytes)" : "") }
                    Copy { objectName: "confirmSerial"; width: parent.width
                        text: screen.t(qsTr("序號")) + ": " + screen.unknown(screen.chosen ? screen.chosen.serial : "") }
                    Rectangle {
                        width: parent.width
                        height: warning.implicitHeight + 24
                        radius: style.uiRadiusControl
                        color: style.uiDangerFill
                        Copy {
                            id: warning
                            objectName: "eraseWarning"
                            x: 12; y: 12; width: parent.width - 24
                            text: "⚠ " + screen.t(messages.status("erase_warning")) + screen.t(qsTr("。這個動作無法復原。"))
                            color: style.uiDanger
                            font.bold: true
                            Accessible.role: Accessible.AlertMessage
                        }
                    }
                    Row {
                        spacing: 12
                        Ui.Button {
                            id: cancelConfirm
                            objectName: "cancelConfirm"
                            tokens: style
                            text: screen.t(qsTr("取消"))
                            Accessible.description: screen.t(qsTr("回到磁碟清單，不寫入任何資料。"))
                            onClicked: screen.client.back()
                        }
                        Ui.Button {
                            id: erase
                            objectName: "eraseAndInstall"
                            tokens: style
                            kind: "danger"
                            text: screen.t(qsTr("清除並安裝"))
                            Accessible.description: screen.t(qsTr("清除整顆磁碟的全部資料並安裝 Ditto。"))
                            onClicked: screen.client.confirm()
                        }
                    }
                }

                // -- installing -----------------------------------------------------------
                Column {
                    width: parent.width; spacing: 12
                    visible: screen.view === "installing"
                    Heading { width: parent.width; text: screen.t(qsTr("正在安裝")) }
                    Status {
                        objectName: "stageText"
                        width: parent.width
                        text: screen.cancelRequested ? screen.t(messages.status("cancelling"))
                            : screen.t(messages.stage(screen.client.progress.stage || "verify"))
                              + (screen.client.progress.total > 0 ? "  " + screen.client.percent + "%" : "")
                    }
                    Rectangle {
                        width: parent.width; height: 10; radius: 5
                        color: style.uiSheet
                        border.color: style.uiInk; border.width: 1
                        Accessible.role: Accessible.ProgressBar
                        Accessible.name: screen.t(qsTr("安裝進度"))
                        Rectangle {
                            width: parent.width * screen.client.percent / 100; height: parent.height
                            radius: parent.radius; color: style.uiFocus
                        }
                    }
                    Copy { width: parent.width; text: screen.t(qsTr("安裝期間請不要拔除安裝媒體或關機。")) }
                    Ui.Button {
                        id: cancelInstall
                        objectName: "cancelInstall"
                        enabled: !screen.cancelRequested
                        tokens: style
                        text: screen.t(qsTr("取消安裝"))
                        Accessible.description: screen.t(qsTr("停止安裝。已開始寫入的磁碟會無法開機，需要重新安裝。"))
                        onClicked: { screen.cancelRequested = true; screen.client.cancel(); }
                    }
                }

                // -- finished ---------------------------------------------------------------
                Column {
                    width: parent.width; spacing: 12
                    visible: screen.view === "done"
                    Heading { width: parent.width; text: screen.t(qsTr("安裝完成")) }
                    Status { objectName: "doneText"; width: parent.width; text: screen.t(messages.result("ok")) }
                    Ui.Button {
                        id: rebootDone
                        objectName: "rebootDone"
                        tokens: style
                        kind: "primary"
                        text: screen.t(qsTr("已拔除，重新開機"))
                        onClicked: screen.client.reboot()
                    }
                }
                Column {
                    width: parent.width; spacing: 12
                    visible: screen.view === "result"
                    Heading {
                        width: parent.width
                        text: screen.client.phase === "cancelled" ? screen.t(qsTr("已取消安裝")) : screen.t(qsTr("安裝沒有完成"))
                    }
                    Status {
                        objectName: "resultText"
                        width: parent.width
                        text: screen.client.result ? screen.t(messages.result(screen.client.result.code)) : ""
                        color: style.uiDanger
                    }
                    Copy {
                        objectName: "diskStateText"
                        width: parent.width
                        text: screen.client.result ? screen.t(messages.diskState(screen.client.result.disk_state)) : ""
                    }
                    Row {
                        spacing: 12
                        Ui.Button {
                            id: chooseAgain
                            objectName: "chooseAgain"
                            tokens: style
                            text: screen.t(qsTr("重新選擇磁碟"))
                            onClicked: screen.client.refresh()
                        }
                        Ui.Button { tokens: style; text: screen.t(qsTr("重新開機")); onClicked: screen.client.reboot() }
                    }
                }
            }
        }
    }
    Copy {
        x: 28; y: screen.height - height - 18; width: screen.width - 56
        text: screen.t(qsTr("Tab 移動　Enter 確認　·　只支援 UEFI x86_64，Secure Boot 須關閉"))
        font.pixelSize: 13
    }
}
