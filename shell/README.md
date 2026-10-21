# Ditto Shell（G1）

Quickshell／QML 的桌面工作階段。對應 [plan/03/04](../plan/03/04-shell-and-surfaces.md) 的 G1-SHELL-01～13；G0 的部分見 [plan/02/04](../plan/02/04-shell-and-avatar.md)。

> 本檔描述的是**開發中**的 G1 Shell。下文「已驗證」一律指開發機上 headless Wayfire 的開發證據，不是參考機的出口證據。

## Shell 擁有什麼

| 擁有 | 不擁有 |
| --- | --- |
| 畫面上有什麼：背景、角色、四個管理中心、試看列、救援介面、鎖定畫面 | 任何配置。Profile、revision、授權、能力綁定都是 Core 的；Shell 不寫檔 |
| **目前掛上的是哪個供應者**（觀測狀態）：以 `participant.state` 與 `shell.report` 回報，Core 據此回讀 | 「換成功了沒」的判定：Core 比對 Shell 的觀測與 ChangeSet 目標，不採信自述 |
| 把 Core 的翻譯鍵依語系呈現成文字 | 差異的計算：變更卡的內容全部來自 Core |

寫入只有一條路：`desktop.changes.propose`（或 `desktop.appearance.set`，Core 內部同樣是 ChangeSet），每次都帶讀到的 `base_revision` 與 `idempotency_key`。組合的命名與刪除不改內容，用 profile 能力本身。

## 結構

| 路徑 | 內容 |
| --- | --- |
| `shell.qml` | 背景、角色、管理中心與試看列的載入、`shell.sock` 控制路徑、Shell 擁有的命令 |
| `core/DittoClient.qml` | 協定 0.2：握手、`_meta`、雙向請求（`core-` 開頭的是 Core 發的）、事件鏈（`prev_seq`）與重新同步、`shell.command`、ChangeSet 輔助函式、head revision |
| `core/ProviderHost.qml`、`core/SlotHost.qml` | 交易參與者：每個 slot 的 active／candidate 兩個載入位置 |
| `core/Tr.qml` | 執行期翻譯（見 i18n） |
| `core/RpcCounter.qml` | 每個請求計數並印時間戳；`mark()` 記錄互動時間點（啟動器喚出、供應者提交），不計為請求 |
| `jelly/` | `Tokens`（完整 token 與替代值）、`Material`、`Surface` |
| `ui/` | Shell 自有表面的元件（按鈕、欄位、開關、選項、診斷區…） |
| `change/` | 變更卡、試看列（保留／取消與倒數）、ChangeSet 狀態的產品語言 |
| `centers/` | 組合中心、插件中心、變更紀錄、個人化設定（同一個視窗，關閉時不存在） |
| `providers/<dir>/` | 可替換的 UI 供應者，每個目錄一個套件（`manifest.json` ＋ `qml/`） |
| `lock/` | 鎖定客戶端 `ditto-lock`：獨立的 Quickshell 設定 |
| `rescue/` | 救援介面：獨立的 Quickshell 設定 |
| `i18n/` | `ditto_zh_TW.ts`、`ditto_en.ts`（權威）與產生的 `.json`（執行期）、`.qm` |
| `tests/fixtures/` | 驗證用的故障供應者（語法錯誤、`healthy()` 為 false、永不 ready、慢、會自己隱藏），**不隨產品發行** |
| `avatar/` | 角色、命中遮罩、幀時取樣（G0） |

## UI 供應者

| 套件 | 目錄 | slot | 形態 |
| --- | --- | --- | --- |
| `ditto.panel.top` | `panel_top` | `ui.panel_top` | 工作區、作用中視窗、音量（PipeWire）、網路（NetworkManager）、時鐘、Ditto 選單（四個中心、啟動器、鎖定與電源） |
| `ditto.dock.bottom` | `dock_bottom` | `ui.dock` | Dock A：底部置中、執行中視窗列（`client.windows`）；每個視窗顯示應用圖示與視窗標題（名稱、圖示取自 `desktop.launcher.list_apps`，找不到時用首字方塊），作用中視窗以底板＋粗體＋底線標示，最小化淡化、其他工作區加「工作區 N」標籤，關閉鈕只在滑鼠或鍵盤焦點停留時出現 |
| `ditto.dock.pill` | `dock_pill` | `ui.dock` | Dock B：左側或底部的膠囊；釘選應用（`desktop.launcher.list_apps`）＋執行中指示；`config.pinned`、`config.position` |
| `ditto.launcher.grid` | `launcher_grid` | `ui.launcher` | 啟動器 A：全螢幕網格、依類別分頁；方向鍵、PageUp／PageDown、Enter、Esc |
| `ditto.launcher.search` | `launcher_search` | `ui.launcher` | 啟動器 B：中央搜尋框（`desktop.launcher.search`）；輸入即搜、上下、Enter、Esc |
| `ditto.tasks.panel` | `tasks_panel` | `ui.tasks_panel` | 待辦（`desktop.tasks.*`）；示範資料與服務不可用都如實標示 |
| `ditto.notifications.area` | `notifications` | `ui.notifications` | 通知（事件＋`desktop.notifications.dismiss`）；策略服務不可用時照常顯示並說明 |

兩個啟動器都宣告命令 `launcher.toggle`；只有綁在 `ui.launcher` 的那個擁有它（Core 在預檢裡檢查）。應用一律經 `desktop.launcher.launch` 啟動，供應者不 exec 任何東西。

### 介面

供應者的根物件是 `Scope`（它擁有自己的 layer-shell 視窗）。ProviderHost 在建立時給它這些屬性：

| 屬性 | 說明 |
| --- | --- |
| `client` | `DittoClient`：唯一的資料與能力入口；翻譯用 `client.t(qsTr("…"))`、`client.key(key, args)` |
| `tokens` | `jelly/Tokens` |
| `config` | 這個條目在 Profile 裡的 `config` |
| `screen` | 主輸出 |
| `slotName`、`entryId` | 掛在哪個 slot、哪個條目（寫自己的 config 時要用） |
| `shown` | 由 ProviderHost 控制：`false` 時不得有任何表面、保留區或輸入區 |

供應者要宣告：

| 成員 | 說明 |
| --- | --- |
| `reservedEdge` | `top`／`bottom`／`left`／`right`／`none` |
| `ready`（bool） | 自己的元件都建立好了 |
| `healthy()` | 在 `ready` 之後 2 秒內回答 `true` |
| `release()` | 同步交出表面、exclusive zone 與輸入區（至少 `shown = false`、關掉彈出物） |
| 啟動器另加 `open()`、`close()`、`toggle()`、`isOpen` | |

所有表面的 `visible` 與 `exclusiveZone` 都要綁 `shown`。資料訂閱在 `shown` 變成 `true` 才開始，所以候選載入不發請求、不佔輸入區、不影響幀時。

限制：供應者從套件庫以絕對路徑載入，**不能 import Shell 內部的相對路徑**，而且目前必須是**單一檔案**——Quickshell 0.3.1 對設定資料夾以外的目錄只解析得到第一個型別。

### 交易（ProviderHost）

| Core 的請求 | Shell 的動作 |
| --- | --- |
| `participant.prepare` | 目標是完整投影；只替有差異的 slot 在隱藏狀態非同步建立候選，等 `ready` 後呼叫 `healthy()`（2 秒上限；載入本身 6 秒上限，在 Core 的 10 秒內）；逐 slot 回 `ready`／`failed(reason)` |
| `participant.commit` | 每個 slot：舊的 `release()` → 候選 `shown = true` → 角色交換；再套用外觀與角色設定；送出 `shell.report` |
| `participant.abort` | 候選銷毀後才回應 |
| `participant.rollback` | 反向：新的 `release()` 並銷毀，恢復**同一個**舊實例 |
| `participant.state` | `{role: "shell", mounts, appearance, avatar}`，以及這個 `change_id` 的階段（不記得就是 `unknown`） |

舊實例在提交後「退休」：已釋放、沒有表面，保留到下一次 prepare 或 20 秒，讓 rollback 恢復原物件而不是重建。開機與重連走同一條路：Core 以 `participant_boot` 推送已提交的投影，準備失敗的 slot 被略過，其餘照常掛上。

掛載的 `visible` 指「供應者被允許顯示」（`shown`）。啟動器沒打開、通知區沒有通知時，表面本身不存在，但掛載仍是 `mounted: true, visible: true`。

## 柔光果凍 token

值來自 Profile 的 `appearance`（Core 在投影裡送來）。`appearance.tokens` 可覆寫：

| 名稱 | 形式 |
| --- | --- |
| `accent`、`on_accent`、`background`、`surface`、`surface_strong`、`foreground`、`foreground_muted`、`border`、`focus`、`warning`、`danger`、`success` | `#rrggbb` 或 `#aarrggbb` |
| `blur_radius`（0–64）、`surface_opacity`（0.5–1）、`shadow_radius`（0–48） | 數字字串 |
| `radius_scale`（0–2）、`font_scale`（0.75–2）、`space_scale`（0.5–2）、`font_family` | 數字字串／字型名 |
| `ui_style` | `j1`（預設）／`j2`／`j3`：淺色主題下自有視窗與膠囊 Dock 的風格 |

QML 的 accent 前景色屬性為 `accentForeground`；Profile 覆寫鍵仍為 `appearance.tokens.on_accent`。狀態色作為背景時使用衍生的 `statusForeground`（深色主題 `#1a1626`、淺色主題 `#ffffff`），不新增 Profile 覆寫鍵。

#116 應用風格（owner 2026-10-20：三種可選、預設 J1；見 [component-sheet §8](../docs/design/default-desktop/component-sheet.md#8-116-soft-jelly-應用風格已定案三種可選預設-j1)）：Profile 覆寫鍵 `ui_style`（`j1` 果凍玻璃／`j2` 軟糖／`j3` 泡泡，預設 `j1`，只作用於 `soft-jelly-light`；Core 預檢拒絕其他值），在個人化中心「外觀風格」選擇。QML：`Tokens.choiceToken()`、`uiStyleChosen`、`uiStyle`（淺色主題時＝`uiStyleChosen`，其他主題為空）、`uiCandidate`、`uiJ1`／`uiJ2`／`uiJ3`、`uiGloss`、`uiShadows`、`uiFill()`；顏色 `uiInk`、`uiInkMuted`、`uiInkDisabled`、`uiCanvas`、`uiCanvasLow`、`uiSidebar`、`uiCard`、`uiCardBorder`、`uiCardHighlight`、`uiShadow`、`uiLip`、`uiTrack`、`uiBead`、`uiBeadEdge`、`uiSelectFill`、`uiSelectDot`、`uiAccent`、`uiAccentTop`、`uiAccentLip`、`uiOnAccent`、`uiAccentInk`、`uiTonal`、`uiTonalHover`、`uiGhostHover`、`uiFocus`、`uiSeparator`、`uiSuccess`／`uiWarning`／`uiDanger`／`uiInfo`（各有 `…Fill`）、`uiDangerSolid`、`uiIris`、視窗鈕 `uiBeadMinimize`／`uiBeadMaximize`／`uiBeadClose`／`uiBeadCloseHot`／`uiBeadGlyph`／`uiBeadRim`（J3 中空珠外環）；形狀與字級 `uiRadiusWindow`／`Card`／`Control`、`uiFontPage`／`Group`／`Label`／`Body`／`Caption`／`CardTitle`、間距 `uiGap`、`uiPadCard`、`uiPadPage`、`uiGapGroup`、`uiControlHeight`、`uiRowHeight`、`uiHeaderHeight`、`uiWindowClearance`（自有視窗留給頂部列、待辦面板與 Dock 的螢幕高度）；動態 `uiPressScaleX`／`Y`。頁面畫字用的 `appInk`、`appInkMuted`、`appWarning`、`appDanger`、`appSuccess`、`appFontCaption`／`Body`／`Title`／`Heading`、`appPagePad`、`appPlate`／`Strong`／`Border`／`Radius` 在未設定時等於原 token。除 `ui_style` 外這些都不是 Profile 覆寫鍵；`readsSystemPreference: false` 給預覽用的 Tokens（不另起程序）。`shell/ui/FocusReveal.js`（捲動內容的鍵盤可達：焦點捲入、翻頁；中心頁與空狀態共用）；`uiSheet`／`uiSheetLow`（對話與確認視窗的近不透明底）。`shell/ui/` 新元件：`JellySurface`、`SegmentedControl`（`segmentPad`）、`GroupedList`、`ListRow`、`OverflowMenu`、`WindowControls`、`WindowHeader`、`WindowFrameless`（Qt 標題列的開關，只在視窗未顯示時改；見 `WindowHeader.qml` 開頭）、`EmptyState`、`StylePicker`；`Button` 另有 `dangerQuiet`、`checked` 與 `jellyPad`。

替代值：`reduced_transparency`（材質不透明、邊框與次要文字對比提高、模糊 0）、`reduced_motion`（位移時長 0，只留短淡入）、`low_power_style`（無模糊、無陰影）。系統的減少動畫偏好（`gsettings … enable-animations`）在啟動時讀一次；`DITTO_REDUCED_MOTION=1`、`DITTO_REDUCED_TRANSPARENCY=1`、`DITTO_LOW_POWER_STYLE=1` 供量測使用。模糊半徑目前只是 token：Wayfire 0.11 上沒有背景效果協定可用。

## i18n

- 所有 Ditto 自有字串寫成 `qsTr("…")`（原文為繁體中文），並經 `t()` 顯示：`client.t(qsTr("…"))`。
- Quickshell 0.3.1 不安裝 QTranslator，所以 `qsTr()` 本身永遠回傳原文。`core/Tr.qml` 在執行期讀 `i18n/ditto_<lang>.json`，以原文為鍵查譯文；語言跟著 Profile 的 `appearance.locale`，切換後所有綁定立即重算，不必重啟。
- Core 送的是翻譯鍵（預檢原因、變更卡標題、差異標籤…），放在 `.ts` 的 `DittoKeys` context，由 `client.key(key, args)` 呈現；`{slot}`、`{package}` 等參數以產品語言命名。
- `.ts` 是權威，與 `lupdate` 相容（context 是 QML 檔名；已比對 `lupdate -extensions qml` 的結果一致）。`.json` 與 `.qm` 由它產生；`.qm` 目前不在執行期使用，留給 Qt 工具與日後的 QTranslator。

```sh
node scripts/lint-shell-i18n.mjs --update     # 把新的 qsTr 原文加進兩個 .ts（英文待翻），移除不再使用的
# 在 shell/i18n/ditto_en.ts 補上英文（Qt Linguist 或直接編輯）
node scripts/lint-shell-i18n.mjs --write      # 產生 .json 與 .qm（有 lrelease 時）
node scripts/lint-shell-i18n.mjs              # CI 檢查
node scripts/lint-shell-i18n.mjs --scan-core  # 另列 crates/ 中像翻譯鍵、但目錄沒有的字面值
```

lint 檢查：QML 字串字面值含中日韓字元卻不在 `qsTr()`／`QT_TR_NOOP()` 內；任何原文或必要的翻譯鍵在任一語言缺譯；`.json`／`.qm` 與 `.ts` 不一致。CI：`.github/workflows/shell-i18n.yml`（另以 `qmllint --max-warnings -1` 檢查語法）。

## 在開發環境執行

```sh
# 1. Core：開發模式（共用 token，不是身分證據）、丟棄式資料目錄、內建套件
scripts/build-builtin-packages.sh target/ditto-packages
export DITTO_DEV_TOKEN=dev DITTO_DATA_DIR=$(mktemp -d)
ditto-core serve --development --compositor wayfire --builtin-packages target/ditto-packages &

# 2. Shell（同一個 DITTO_DEV_TOKEN）
quickshell -p shell/shell.qml

# 存檔即重載（只在開發時）：Shell 預設不監看檔案，因為 Core 交給它的 token
# 只能用一次，重載後的 Shell 連不回 Core，桌面會失去面板與 Dock
DITTO_SHELL_WATCH=1 quickshell -p shell/shell.qml

# 供應者直接從來源樹載入（只在開發時；登入工作階段不會設）
DITTO_SHELL_DEV_PROVIDERS=$PWD/shell/providers quickshell -p shell/shell.qml

# hostd（待辦與通知策略服務）也可以用同一個 token 手動啟動
node packages/host-runtime/dist/ditto-hostd.mjs
```

Quickshell 會監看設定目錄，改了 `shell/` 下的 QML 就整個重新載入（重新握手，Core 再推一次開機投影）。

`shell.sock`（`$DITTO_RUNTIME_DIR/shell.sock`）的控制行：

| 行 | 動作 |
| --- | --- |
| `ping <n>` | 在 UI 執行緒立刻回 `pong <n>`（`ditto-supervisor` 的存活檢查） |
| `recall` | 角色被遮住或隱藏時喚回 |
| `workspace <id>` | 與點擊面板同一條能力路徑 |
| `command <id>` | 在本機執行 Shell 擁有的命令（`launcher.toggle`、`composition.open`…），供開發與驗證；產品路徑是 Core 的 `shell.command` |
| `focus` | 唯讀，回一行 JSON：管理中心裡持有鍵盤焦點的控制項的無障礙名稱、角色與所在群組（鍵盤驗證用） |
| `tasks` | 唯讀，回一行 JSON：待辦面板是否已掛載，以及它手上要顯示的未完成待辦文字（EX1-07 用；不問 Core） |

鎖定客戶端與救援介面各自是一個設定：`quickshell -p shell/lock`、`quickshell -p shell/rescue/shell.qml`。兩者的 `core`、`jelly`、`ui`、`i18n` 是指向 Shell 目錄的符號連結（同一個 Quickshell 限制），安裝時要保留符號連結。

- 鎖定：`WlSessionLock`（ext_session_lock_v1）＋ PAM（`DITTO_LOCK_PAM_SERVICE`，預設 `login`）。只有成功解鎖後才以 0 結束；合成器沒確認鎖定（5 秒）、鎖定被合成器結束都以非 0 結束，Core 會再起一個。它不連 Core；語言取 `DITTO_LOCALE`，否則依 `LANG`。
- 救援：以 `rescue-shell` 身分連 Core，只有視窗清單、停用最近變更的插件、恢復最近可用組合與診斷；可以操作時印出 `ditto-rescue ready`。連不上 Core 時提供 `foot -- dittoctl rescue`。

## 還沒做到的

- 角色的位置只有螢幕與四個角落（Profile 的 `avatar.output`、`avatar.corner`），還不能拖曳到任意位置。指定的螢幕沒接上或被拔除時，角色在主輸出（排列在最左上的輸出）；實際位置由 Shell 依自己的表面回報（`shell.report` 的 `avatar_placement`），不是合成器的回讀。實體第二螢幕上的拔插尚未在參考機驗證。
- 快捷鍵「Super＋數字聚焦第 N 個視窗」：沒有對應的命令，未實作。
- 音量與網路只顯示與簡單調整（PipeWire、NetworkManager）；headless 開發環境兩者都不可用，只驗到「不可用」的顯示。
- 螢幕閱讀（Orca）的人工走查、中文輸入法在命名欄位的實測，屬人工驗收清單，尚未執行。
- 供應者必須是單一 QML 檔（見上）。
