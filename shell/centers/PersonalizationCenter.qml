pragma ComponentBehavior: Bound
import QtQuick
import "../ui"
import "../change"

/// Personalization (G1-SHELL-09): appearance tokens and material, reduced
/// transparency and motion, language, shortcuts with conflicts, the
/// character, accessibility. Every setting here is a ChangeSet (appearance
/// through `desktop.appearance.set`, the rest through `desktop.changes.propose`);
/// display settings that could leave the screen unusable come back with a
/// countdown and must be kept (Core decides which: plan/03/02 §10).
Flickable {
    id: page

    required property var client
    required property var tokens
    /// #116 application style (Profile `ui_style`, light recipe); false keeps the existing page.
    readonly property bool jelly: tokens.uiCandidate === true
    property var providers: null

    contentWidth: width
    contentHeight: column.implicitHeight + tokens.appPagePad * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    property var appearance: null
    property var avatar: null
    property var outputs: []          // desktop.outputs.list
    property var placement: null      // where the Shell reports the character
    property var shortcuts: []        // the Profile's own bindings
    property var shortcutInfo: []     // desktop.shortcuts.list
    property var commands: []
    property string notice: ""
    property string diagnostic: ""
    property var lastRecord: null
    property bool busy: false

    readonly property var accents: ["#b9a4ff", "#8ab4ff", "#7fd1b9", "#ffb3c7", "#ffd28a"]

    ChangeText {
        id: words
        client: page.client
    }

    function t(source) {
        return client.t(source);
    }

    function fail(error) {
        busy = false;
        notice = client.errorText(error);
        diagnostic = client.diagnosticText(error);
        if (error.data && error.data.change_id) {
            client.capability("desktop.changes.get", { change_id: error.data.change_id }, function (record) {
                page.lastRecord = record;
            });
        }
    }

    function done(record) {
        busy = false;
        notice = "";
        lastRecord = record;
        client.notePending(record);
        reload();
    }

    function reload() {
        client.capability("desktop.appearance.get", {}, function (result) {
            page.appearance = result.appearance;
            page.avatar = result.avatar;
        }, fail);
        client.capability("desktop.profiles.get", { history_limit: 1 }, function (result) {
            page.shortcuts = result.document.shortcuts || [];
        }, fail);
        client.capability("desktop.shortcuts.list", {}, function (result) {
            page.shortcutInfo = result.shortcuts;
        });
        client.capability("desktop.commands.list", {}, function (result) {
            page.commands = result.commands;
        });
        client.capability("desktop.outputs.list", {}, function (result) {
            page.outputs = result.outputs.filter(output => output.enabled !== false);
        });
        client.capability("desktop.panels.list", {}, function (result) {
            page.placement = result.avatar || null;
        });
    }

    function cornerName(corner) {
        switch (corner) {
        case "top_left":
            return t(qsTr("左上"));
        case "top_right":
            return t(qsTr("右上"));
        case "bottom_left":
            return t(qsTr("左下"));
        }
        return t(qsTr("右下"));
    }

    /// The character's screen as options: the primary one, or one by name.
    /// A named screen that is unplugged stays listed, so the choice reads
    /// true while the character waits on the primary screen.
    function screenOptions() {
        const options = [{ value: "", label: t(qsTr("主螢幕")) }];
        for (const output of outputs) {
            options.push({ value: output.name, label: output.name });
        }
        const named = avatar && avatar.output ? avatar.output : "";
        if (named.length > 0 && !outputs.some(output => output.name === named)) {
            options.push({ value: named, label: t(qsTr("%1（未連接）")).arg(named) });
        }
        return options;
    }

    /// Where the character is now, in words, from the Shell's report.
    function placementText() {
        if (!placement || !placement.output) {
            return t(qsTr("目前沒有顯示角色。"));
        }
        const where = t(qsTr("角色目前在 %1 的%2。")).arg(placement.output).arg(cornerName(placement.corner));
        if (avatar && avatar.output && placement.follows_primary) {
            return where + " " + t(qsTr("指定的螢幕 %1 沒有連接，所以先放在主螢幕。")).arg(avatar.output);
        }
        return where;
    }

    /// `output` absent means the primary screen; the key is left out rather
    /// than set to null, as Core writes it.
    function setAvatarScreen(name) {
        if (!avatar) {
            return;
        }
        const after = Object.assign({}, avatar);
        if (name && name.length > 0) {
            after.output = name;
        } else {
            delete after.output;
        }
        busy = true;
        client.propose([{ op: "set_value", path: "/avatar", before: avatar, after: after }], { surface: "personalization" }, done, fail);
    }

    function setAppearance(fields) {
        busy = true;
        notice = t(qsTr("正在套用…"));
        client.setAppearance(fields, done, fail);
    }

    /// The appearance every control shows and every "already chosen"
    /// judgement uses: the committed projection the Shell runs
    /// (`tokens.appearance`, from Core at every commit and at every
    /// (re)connect), not this page's own read, which can miss an event.
    /// Before Core has sent a projection, the page's read.
    readonly property var committed: tokens.appearance ? tokens.appearance : appearance

    function token(name) {
        return committed && committed.tokens ? committed.tokens[name] : undefined;
    }

    function setAvatar(field, value) {
        if (!avatar) {
            return;
        }
        const after = Object.assign({}, avatar);
        after[field] = value;
        busy = true;
        client.propose([{ op: "set_value", path: "/avatar", before: avatar, after: after }], { surface: "personalization" }, done, fail);
    }

    function setShortcuts(after) {
        busy = true;
        client.propose([{ op: "set_value", path: "/shortcuts", before: shortcuts, after: after }], { surface: "personalization" }, done, fail);
    }

    function commandTitle(commandId) {
        const command = commands.find(item => item.command_id === commandId);
        return command ? client.key(command.title_key, {}) : commandId;
    }

    Component.onCompleted: reload()

    Connections {
        target: page.client
        function onProfileChanged(payload) {
            page.reload();
        }
        // After a resync or a reconnect (the catalog is read again on both),
        // as the plugin center does: an event missed meanwhile is not lost.
        function onCapabilitiesReloaded() {
            page.reload();
        }
    }

    Column {
        id: column
        x: page.tokens.appPagePad
        y: page.tokens.appPagePad
        width: page.width - page.tokens.appPagePad * 2
        spacing: page.tokens.spaceSection

        Text {
            text: page.t(qsTr("個人化設定"))
            color: page.tokens.appInk
            font.pixelSize: page.tokens.appFontHeading
            font.bold: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            visible: page.notice.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: page.notice
            color: page.tokens.appWarning
            font.pixelSize: page.tokens.appFontBody
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Diagnostics {
            width: parent.width
            tokens: page.tokens
            title: page.t(qsTr("診斷"))
            text: page.diagnostic
        }

        ChangeCard {
            visible: !!page.lastRecord
            width: parent.width
            client: page.client
            tokens: page.tokens
            record: page.lastRecord
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("外觀"))

            // #116 (owner 2026-10-20): three application styles, J1 jelly
            // glass by default. A ChangeSet like every appearance token;
            // the Shell's windows change as soon as it commits. The styles
            // belong to the light theme; with another theme nothing here
            // would change anything, so the choice is not shown.
            Text {
                visible: page.tokens.lightRecipe
                text: page.t(qsTr("外觀風格"))
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
                font.weight: Font.DemiBold
            }
            StylePicker {
                id: stylePicker
                objectName: "uiStylePicker"
                visible: page.tokens.lightRecipe
                width: parent.width
                tokens: page.tokens
                enabled: !page.busy && !!page.appearance
                accessibleName: page.t(qsTr("外觀風格"))
                value: page.tokens.uiStyleChosen
                defaultValue: "j1"
                defaultNote: page.t(qsTr("預設"))
                options: [
                    { value: "j1", label: page.t(qsTr("J1 果凍玻璃")), accessibleName: page.t(qsTr("J1 果凍玻璃（預設）")),
                      caption: page.t(qsTr("半透明磨砂與柔光邊，安靜、輕盈。")) },
                    { value: "j2", label: page.t(qsTr("J2 軟糖")), accessibleName: page.t(qsTr("J2 軟糖")),
                      caption: page.t(qsTr("不透明的軟糖質感，按下會微微壓扁，色彩較暖。")) },
                    { value: "j3", label: page.t(qsTr("J3 泡泡")), accessibleName: page.t(qsTr("J3 泡泡")),
                      caption: page.t(qsTr("泡泡與虹彩細邊，留白最多。")) }
                ]
                onChosen: value => {
                    if (value !== page.tokens.uiStyleChosen) page.setAppearance({ tokens: { ui_style: value } });
                }
            }
            Text {
                objectName: "uiStyleNote"
                visible: page.tokens.lightRecipe
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.t(qsTr("套用到設定、對話、確認視窗與膠囊式 Dock。其他應用的標題列與終端機目前維持果凍玻璃樣式。"))
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontCaption
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("強調色"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Repeater {
                    model: page.accents
                    Rectangle {
                        required property var modelData
                        readonly property bool selected: page.token("accent") === modelData
                        width: 30
                        height: 30
                        radius: 15
                        color: modelData
                        border.color: selected || activeFocus ? page.tokens.focus : page.tokens.border
                        border.width: selected || activeFocus ? 3 : 1
                        activeFocusOnTab: true
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: page.t(qsTr("強調色 %1")).arg(modelData)
                        Accessible.checked: selected
                        Keys.onSpacePressed: page.setAppearance({ tokens: { accent: modelData } })
                        Keys.onReturnPressed: page.setAppearance({ tokens: { accent: modelData } })
                        Text {
                            anchors.centerIn: parent
                            visible: parent.selected && !page.jelly
                            text: "✓"
                            color: "#1a1626"
                            font.bold: true
                        }
                        // Candidate: the chosen colour is a bubble ring (white
                        // inner ring inside a thick ink ring), not a ✓ character.
                        Rectangle {
                            visible: parent.selected && page.jelly
                            anchors.fill: parent
                            anchors.margins: 3
                            radius: width / 2
                            color: "transparent"
                            border.color: "#ffffff"
                            border.width: 3
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !page.busy
                            onClicked: page.setAppearance({ tokens: { accent: modelData } })
                        }
                    }
                }
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("圓角"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Choice {
                    tokens: page.tokens
                    enabled: !page.busy
                    value: page.token("radius_scale") || "1"
                    accessibleName: page.t(qsTr("圓角"))
                    options: [{ value: "0.5", label: page.t(qsTr("小")) }, { value: "1", label: page.t(qsTr("標準")) }, { value: "1.5", label: page.t(qsTr("大")) }]
                    onChosen: value => page.setAppearance({ tokens: { radius_scale: value } })
                }
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("文字大小"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Choice {
                    tokens: page.tokens
                    enabled: !page.busy
                    value: page.token("font_scale") || "1"
                    accessibleName: page.t(qsTr("文字大小"))
                    options: [{ value: "1", label: page.t(qsTr("標準")) }, { value: "1.15", label: page.t(qsTr("較大")) }, { value: "1.3", label: page.t(qsTr("最大")) }]
                    onChosen: value => page.setAppearance({ tokens: { font_scale: value } })
                }
            }

            Toggle {
                tokens: page.tokens
                enabled: !page.busy && !!page.appearance
                text: page.t(qsTr("降低透明度"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: !!page.committed && page.committed.reduced_transparency === true
                onToggled: value => page.setAppearance({ reduced_transparency: value })
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.t(qsTr("關閉「降低透明度」後會出現倒數，按「保留」才會留下，避免看不清楚時無法改回。"))
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontCaption
            }

            Toggle {
                tokens: page.tokens
                enabled: !page.busy && !!page.appearance
                text: page.t(qsTr("低效能樣式（關閉模糊與陰影）"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: !!page.committed && page.committed.low_power_style === true
                onToggled: value => page.setAppearance({ low_power_style: value })
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("動畫"))

            Toggle {
                tokens: page.tokens
                enabled: !page.busy && !!page.appearance
                text: page.t(qsTr("減少動畫"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: !!page.committed && page.committed.reduced_motion === true
                onToggled: value => page.setAppearance({ reduced_motion: value })
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.tokens.systemReducedMotion
                    ? page.t(qsTr("系統已設定減少動畫，這裡關閉也不會恢復動畫。系統設定在桌面啟動時讀取。"))
                    : page.t(qsTr("系統的減少動畫設定在桌面啟動時讀取，兩者任一開啟都會減少動畫。"))
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontCaption
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("語言"))

            Choice {
                tokens: page.tokens
                enabled: !page.busy && !!page.appearance
                value: page.committed && page.committed.locale ? page.committed.locale : "zh-TW"
                accessibleName: page.t(qsTr("語言"))
                options: [{ value: "zh-TW", label: qsTr("繁體中文") }, { value: "en", label: "English" }]
                onChosen: value => page.setAppearance({ locale: value })
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("快捷鍵"))
            note: page.t(qsTr("快捷鍵由 Ditto 綁定到視窗管理。同一組按鍵只能有一個用途；衝突會在套用前被擋下並說明。"))

            Repeater {
                model: page.shortcutInfo

                Row {
                    required property var modelData
                    spacing: page.tokens.space
                    Text {
                        width: 140
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.chord
                        color: page.tokens.appInk
                        font.pixelSize: page.tokens.appFontBody
                        font.family: "monospace"
                    }
                    Text {
                        width: 200
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.commandTitle(modelData.command)
                        color: page.tokens.appInk
                        font.pixelSize: page.tokens.appFontBody
                    }
                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        tokens: page.tokens
                        text: modelData.reserved ? page.t(qsTr("系統保留"))
                            : modelData.conflict ? page.t(qsTr("衝突"))
                            : modelData.bound ? page.t(qsTr("已生效"))
                            : page.t(qsTr("未生效"))
                        tone: modelData.conflict ? "bad" : modelData.bound ? "good" : "warn"
                    }
                    Button {
                        visible: !modelData.reserved && page.shortcuts.some(binding => binding.chord === modelData.chord)
                        tokens: page.tokens
                        kind: "subtle"
                        text: page.t(qsTr("移除"))
                        enabled: !page.busy
                        onClicked: page.setShortcuts(page.shortcuts.filter(binding => binding.chord !== modelData.chord))
                    }
                }
            }

            Row {
                spacing: page.tokens.space
                TextField {
                    id: chordField
                    width: 160
                    tokens: page.tokens
                    placeholder: page.t(qsTr("例如 Super+Space"))
                }
                Choice {
                    id: commandChoice
                    tokens: page.tokens
                    maxWidth: column.width - 260
                    property string chosenCommand: ""
                    value: chosenCommand
                    options: page.commands.filter(command => command.command_id !== "session.lock" && command.command_id !== "rescue.open")
                        .map(command => ({ value: command.command_id, label: page.client.key(command.title_key, {}) }))
                    onChosen: value => chosenCommand = value
                }
                Button {
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("加入"))
                    enabled: !page.busy && chordField.text.trim().length > 0 && commandChoice.chosenCommand.length > 0
                    onClicked: {
                        page.setShortcuts(page.shortcuts.concat([{ chord: chordField.text.trim(), command: commandChoice.chosenCommand }]));
                        chordField.text = "";
                    }
                }
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("角色"))

            Toggle {
                tokens: page.tokens
                enabled: !page.busy && !!page.avatar
                text: page.t(qsTr("顯示 Ditto 角色"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: !!page.avatar && page.avatar.enabled === true && page.avatar.hidden !== true
                onToggled: value => page.setAvatar("hidden", !value)
            }

            Toggle {
                tokens: page.tokens
                enabled: !page.busy && !!page.avatar
                text: page.t(qsTr("角色動畫"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: !!page.avatar && page.avatar.animations !== false
                onToggled: value => page.setAvatar("animations", value)
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("大小"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Choice {
                    tokens: page.tokens
                    enabled: !page.busy && !!page.avatar
                    value: page.avatar ? page.avatar.scale : 1
                    accessibleName: page.t(qsTr("角色大小"))
                    options: [{ value: 0.75, label: page.t(qsTr("小")) }, { value: 1, label: page.t(qsTr("標準")) }, { value: 1.25, label: page.t(qsTr("大")) }]
                    onChosen: value => page.setAvatar("scale", value)
                }
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("螢幕"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Choice {
                    tokens: page.tokens
                    enabled: !page.busy && !!page.avatar
                    maxWidth: column.width - 140 - page.tokens.space
                    value: page.avatar && page.avatar.output ? page.avatar.output : ""
                    accessibleName: page.t(qsTr("角色所在螢幕"))
                    options: page.screenOptions()
                    onChosen: value => page.setAvatarScreen(value)
                }
            }

            Row {
                spacing: page.tokens.space
                Text {
                    width: 140
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.t(qsTr("位置"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                }
                Choice {
                    tokens: page.tokens
                    enabled: !page.busy && !!page.avatar
                    maxWidth: column.width - 140 - page.tokens.space
                    value: page.avatar && page.avatar.corner ? page.avatar.corner : "bottom_right"
                    accessibleName: page.t(qsTr("角色位置"))
                    options: ["top_left", "top_right", "bottom_left", "bottom_right"].map(corner => ({ value: corner, label: page.cornerName(corner) }))
                    onChosen: value => page.setAvatar("corner", value)
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.placementText()
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.t(qsTr("主螢幕是排列在最左上的螢幕。角色所在的螢幕拔除時，角色會移到主螢幕，接回後再回去。被視窗蓋住時可以用喚回快捷鍵叫出來。"))
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontCaption
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("無障礙"))

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.t(qsTr("鍵盤焦點一律以外框標示，所有操作都可以只用 Tab、Enter、空白鍵與方向鍵完成。每個按鈕與欄位都有螢幕閱讀器可以讀出的名稱；狀態同時以文字表示，不只靠顏色或動畫。"))
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }
        }
    }
}
