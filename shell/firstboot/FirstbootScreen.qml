pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell.Io
import "jelly"
import "ui" as Ui
import "Validation.js" as Validation

Item {
    id: screen
    required property var translator
    property string phase: "editing"
    property string errorCode: ""
    property string pamInfo: ""
    readonly property bool busy: phase === "creating" || phase === "authenticating" || phase === "launching"
    property alias displayField: display
    property alias usernameField: username
    property alias passwordField: password
    property alias confirmField: confirm
    property alias createButton: create
    property alias returnButton: back
    readonly property bool valid: Validation.valid(display.text, username.text, password.text, confirm.text)
    readonly property bool weakWarning: Validation.password(password.text) && Validation.weak(password.text)
    signal submitted(string displayName, string username, string password, string confirm)
    signal returnToLogin()

    function t(source) { return translator.t(source); }
    function clearSecrets() { password.text = ""; confirm.text = ""; }
    onPhaseChanged: if (phase === "stopped") Qt.callLater(() => back.forceActiveFocus())
    onErrorCodeChanged: {
        if (phase === "editing" && errorCode.length > 0)
            Qt.callLater(focusError);
    }
    function focusError() { errorText.forceActiveFocus(Qt.OtherFocusReason); }
    function revealFocused() {
        const window = screen.Window.window;
        const item = window ? window.activeFocusItem : null;
        if (!item) return;
        let ancestor = item;
        while (ancestor && ancestor !== scroll.contentItem) ancestor = ancestor.parent;
        if (!ancestor) return;
        const point = item.mapToItem(scroll.contentItem, 0, 0);
        if (point.y < scroll.contentY) scroll.contentY = Math.max(0, point.y - 12);
        else if (point.y + item.height > scroll.contentY + scroll.height)
            scroll.contentY = Math.min(scroll.contentHeight - scroll.height, point.y + item.height - scroll.height + 12);
    }
    function disableIme() {
        if (!imeCloser.running) imeCloser.running = true;
    }
    Process {
        id: imeCloser
        objectName: "firstbootImeCloser"
        command: ["fcitx5-remote", "-c"]
    }

    function submit() {
        if (valid && phase === "editing") submitted(display.text, username.text, password.text, confirm.text);
    }
    Messages { id: messages }
    Tokens {
        id: style
        readsSystemPreference: false
        appearance: ({theme: "soft-jelly-light", tokens: {ui_style: "j1", font_family: "Noto Sans CJK TC"}})
    }
    Backdrop { anchors.fill: parent; tokens: style; wallpaperSource: style.wallpaper }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#a6f7f5ff" }
            GradientStop { position: 0.65; color: "#00f7f5ff" }
        }
    }
    component Copy: Text {
        color: "#423c5e"
        font.family: style.fontFamily
        font.pixelSize: 14
        wrapMode: Text.WordWrap
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
    Copy {
        x: 28; y: screen.height < 800 ? 20 : 24
        text: screen.t(qsTr("Ditto · 首次設定"))
        font.pixelSize: 18
        font.bold: true
    }
    // No dead language/keyboard/accessibility pills. The actual Orca shortcut
    // is documented below; text scaling follows the Qt environment on restart.
    Flickable {
        id: scroll
        x: Math.max(24, screen.width * 0.075)
        y: 76
        width: Math.min(560, screen.width - 48)
        height: Math.max(0, screen.height - y - 68)
        contentWidth: width
        contentHeight: Math.max(height, card.height + 16)
        onContentHeightChanged: Qt.callLater(screen.revealFocused)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: card
            y: Math.max(8, (scroll.height - height) / 2)
            x: 4
            width: scroll.width - 8
            height: body.implicitHeight + (screen.height < 800 ? 40 : 48)
            Ui.JellySurface {
                anchors.fill: parent
                tokens: style
                fill: style.uiSheet
                iris: true
                radius: style.uiRadiusWindow
            }
            Column {
                id: body
                x: 28; y: screen.height < 800 ? 20 : 24
                width: card.width - 56
                spacing: screen.height < 800 ? 9 : 14
                Copy {
                    text: screen.t(qsTr("建立你的帳號"))
                    color: style.uiInk
                    font.pixelSize: 28
                    font.bold: true
                    Accessible.role: Accessible.Heading
                }
                Copy {
                    width: parent.width
                    text: screen.t(qsTr("這台電腦還沒有帳號。建立後會用剛設定的密碼登入 Ditto 桌面，之後登入與解鎖都用這組密碼。"))
                }
                Rectangle {
                    width: parent.width
                    height: visible ? errorText.implicitHeight + 24 : 0
                    visible: screen.errorCode.length > 0
                    radius: style.uiRadiusControl
                    color: style.uiDangerFill
                    border.color: style.uiFocus
                    border.width: errorText.activeFocus ? 2 : 0
                    Copy {
                        id: errorText
                        objectName: "errorMessage"
                        x: 12; y: 12; width: parent.width - 24
                        text: screen.t(messages.errorText(screen.errorCode))
                        color: style.uiDanger
                        Accessible.role: Accessible.AlertMessage
                        Accessible.description: text
                        Accessible.focusable: true
                        activeFocusOnTab: visible
                        onTextChanged: () => { if (visible && text.length > 0) Accessible.announce(text, Accessible.Assertive); }
                    }
                }
                Column {
                    width: parent.width; spacing: 5
                    Copy { id: displayLabel; text: display.accessibleName; font.bold: true }
                    Ui.TextField {
                        id: display
                        accessibleLabel: displayLabel
                        objectName: "displayName"
                        width: parent.width; tokens: style
                        accessibleName: screen.t(qsTr("你的名字"))
                        accessibleDescription: screen.t(qsTr("顯示在登入畫面，可用中文，也可以留空。Ctrl+空白切換注音輸入。"))
                        maximumLength: 256
                        enabled: screen.phase === "editing"
                        nextTabItem: username.inputItem
                        previousTabItem: create.enabled ? create : confirm.inputItem
                        onAccepted: username.focusInput()
                        Component.onCompleted: focusInput()
                    }
                    Copy { width: parent.width; text: display.accessibleDescription }
                }
                Column {
                    width: parent.width; spacing: 5
                    Copy { id: usernameLabel; text: username.accessibleName; font.bold: true }
                    Ui.TextField {
                        id: username
                        accessibleLabel: usernameLabel
                        objectName: "username"
                        width: parent.width; tokens: style
                        accessibleName: screen.t(qsTr("帳號名稱"))
                        accessibleDescription: screen.t(qsTr("以英文小寫字母開頭，只能用小寫字母、數字與「-」，最多 31 個字元。"))
                        maximumLength: 31
                        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhLatinOnly
                        // Hints describe content. The focus action actually
                        // deactivates fcitx5; the validator rejects IM commits.
                        validator: RegularExpressionValidator { regularExpression: /^[a-z][a-z0-9-]{0,30}$/ }
                        onInputFocused: screen.disableIme()
                        enabled: screen.phase === "editing"
                        nextTabItem: password.inputItem; previousTabItem: display.inputItem
                        onAccepted: password.focusInput()
                    }
                    Copy { width: parent.width; text: username.accessibleDescription }
                    Copy {
                        width: parent.width
                        visible: username.text.length > 0 && !Validation.username(username.text)
                        text: screen.t(messages.errorText("invalid_username"))
                        color: style.uiDanger
                    }
                }
                Column {
                    width: parent.width; spacing: 6
                    Row {
                        width: parent.width; spacing: 16
                        Column {
                            width: (parent.width - 16) / 2; spacing: 5
                            Copy { id: passwordLabel; text: password.accessibleName; font.bold: true }
                            Ui.TextField {
                                id: password
                                accessibleLabel: passwordLabel
                                objectName: "password"
                                width: parent.width; tokens: style; secret: true
                                accessiblePassword: true
                                onInputFocused: screen.disableIme()
                                accessibleName: screen.t(qsTr("密碼"))
                                accessibleDescription: screen.t(qsTr("密碼至少 8 個字元"))
                                maximumLength: 511
                                inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhLatinOnly | Qt.ImhSensitiveData | Qt.ImhHiddenText
                                enabled: screen.phase === "editing"
                                nextTabItem: confirm.inputItem; previousTabItem: username.inputItem
                                onAccepted: confirm.focusInput()
                            }
                        }
                        Column {
                            width: (parent.width - 16) / 2; spacing: 5
                            Copy { id: confirmLabel; text: confirm.accessibleName; font.bold: true }
                            Ui.TextField {
                                id: confirm
                                accessibleLabel: confirmLabel
                                objectName: "confirmPassword"
                                width: parent.width; tokens: style; secret: true
                                accessiblePassword: true
                                onInputFocused: screen.disableIme()
                                accessibleName: screen.t(qsTr("再輸入一次"))
                                accessibleDescription: password.accessibleDescription
                                maximumLength: 511
                                inputMethodHints: password.inputMethodHints
                                enabled: screen.phase === "editing"
                                nextTabItem: create.enabled ? create : display.inputItem
                                previousTabItem: password.inputItem
                                onAccepted: screen.submit()
                            }
                        }
                    }
                    Copy { text: password.accessibleDescription }
                    Copy {
                        width: parent.width
                        visible: password.text.length > 0 && !Validation.password(password.text)
                        text: screen.t(messages.errorText(Validation.characters(password.text) < 8 ? "password_too_short" : "password_invalid"))
                        color: style.uiDanger
                    }
                    Copy {
                        width: parent.width
                        visible: confirm.text.length > 0
                        text: password.text === confirm.text ? screen.t(qsTr("兩次輸入相同。")) : screen.t(qsTr("兩次密碼不同，請再確認。"))
                        color: password.text === confirm.text ? style.uiSuccess : style.uiDanger
                    }
                    Copy {
                        objectName: "weakWarning"
                        width: parent.width
                        visible: screen.weakWarning
                        text: screen.t(qsTr("這組密碼比較容易被猜到，建議換成較長的詞句；仍可使用這組密碼建立帳號。"))
                        color: style.uiWarning
                    }
                }
                Copy {
                    width: parent.width
                    text: screen.t(qsTr("這個帳號是管理員，可以變更系統設定。"))
                }
                Copy {
                    width: parent.width
                    visible: screen.busy
                    text: screen.phase === "creating" ? screen.t(qsTr("正在建立帳號與家目錄…"))
                        : screen.phase === "authenticating" ? screen.t(qsTr("帳號已建立，正在驗證登入…")) : screen.t(qsTr("正在啟動 Ditto 桌面…"))
                    Accessible.role: Accessible.AlertMessage
                    onTextChanged: () => { if (visible && text.length > 0) Accessible.announce(text, Accessible.Polite); }
                }
                Copy {
                    objectName: "pamInfo"
                    width: parent.width
                    visible: screen.busy && screen.pamInfo.length > 0
                    text: screen.pamInfo
                    textFormat: Text.PlainText
                    Accessible.role: Accessible.AlertMessage
                    onTextChanged: () => { if (visible && text.length > 0) Accessible.announce(text, Accessible.Polite); }
                }
                Ui.Button {
                    id: create
                    objectName: "createAccount"
                    anchors.right: parent.right
                    tokens: style; kind: "primary"; implicitHeight: 42
                    text: screen.t(qsTr("建立帳號並進入桌面"))
                    enabled: screen.valid && screen.phase === "editing"
                    Accessible.description: screen.t(qsTr("建立管理員帳號，驗證密碼後進入桌面。"))
                    KeyNavigation.tab: display.inputItem
                    KeyNavigation.backtab: confirm.inputItem
                    onClicked: screen.submit()
                }
                Ui.Button {
                    id: back
                    objectName: "returnToLogin"
                    visible: screen.phase === "stopped"
                    enabled: visible
                    tokens: style
                    text: screen.t(qsTr("回到登入畫面"))
                    Accessible.description: screen.t(qsTr("結束首次設定畫面，重新檢查帳號狀態。"))
                    onClicked: screen.returnToLogin()
                }
            }
        }
    }
    Copy {
        x: 28; y: screen.height - height - 18; width: screen.width - 56
        text: screen.t(qsTr("Tab 移動　Enter 確認　Super+Alt+S 開啟螢幕閱讀器　·　沒有預設帳號，不會自動登入"))
        font.pixelSize: 13
    }
    // Keep the keyboard's single focused control visible even on smaller outputs.
    Connections {
        target: screen.Window.window
        function onActiveFocusItemChanged() { Qt.callLater(screen.revealFocused); }
    }
}
