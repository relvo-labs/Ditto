            // #183 accepted addition, independently specified on the historical page.
            // No production source extraction and no filtering implementation here.
            Text {
                text: page.t(qsTr("搜尋已安裝的插件"))
                color: page.tokens.foreground
                font.pixelSize: page.tokens.fontBody
            }
            TextField {
                width: parent.width
                tokens: page.tokens
                accessibleName: page.t(qsTr("搜尋已安裝的插件"))
                placeholder: page.t(qsTr("名稱、ID、說明或條目"))
            }
