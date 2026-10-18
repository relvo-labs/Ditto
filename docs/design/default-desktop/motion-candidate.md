# R2 原生動態候選（#66，checkpoint）

狀態：可執行的 S2 候選，基底 `f99b4ea0db5ceff1ef98956b7e32895784746157`。參數尚待原生樣本與 owner 確認；不是 #66 關閉、NFR-05 通過或 final 動態核定。沿用 [設計契約 §4](design-contract.md#4-動態編排提案) 與 [M1／P1](workplan-and-acceptance.md#2-驗收矩陣)。

## 盤點與狀態／過渡表

基底已有 Tokens 的 fast／medium／slow／fade、reducedMotion／reducedTransparency／lowPower；系統 reduced-motion 在 Shell 啟動時讀一次。Material 的局部陰影依 renderer 降級。DockPill 與 AssistantEntry 原本沒有動畫；compact／full chat 依 `chat.open` 與 mode 建立／銷毀。既有 avatar 動作、ChatFocusReturn、ConversationState、approval／preview 不在本 slice 重做。

| 表面／真實狀態 | 本 checkpoint 的過渡／提示 | 中斷、回退與界線 |
| --- | --- | --- |
| 首次呈現 | 淺色 Dock 圖示 0.98→1；助理符號 0.96→1；compact 內容透明度 0.92→1 | 固定背板、幾何與 hit target；沒有開場操作鎖。頂部、桌布、launcher 及 full window 開場未新增動態 |
| hover／鍵盤 focus | Dock 圖示／助理符號縮至 0.96，原有底板／焦點框與標籤保留 | 120 ms；移開／失焦轉向新目標；不重排相鄰按鈕，不縮放 hit target |
| pointer press／release | 同一局部圖示縮至 0.90，再回當下 hover／focus／expanded 目標 | 120 ms；連點不排隊。Enter／Space／Accessible action 立即沿原路操作，以 focus 框提供等價鍵盤提示 |
| Dock launch／focus | 點擊直接發原命令；首次觀測建立基線；其後 focused window ID 真正改變才一次 0.94→1；running 點與 current 長條立即反映真狀態 | 180 ms，沒有樂觀成功或無限彈跳。新視窗未聚焦時只有原 running 點；失敗沿原 notice。`dock_bottom` 與 launcher 維持原樣 |
| 助理 open／close | 入口的 expanded 目標為 0.98；compact 新建時內容短淡入，focus 立即進 editor | compact close／compact↔full／full close 仍立即銷毀舊表面；**退場動畫延後**，不延長焦點或輸入租用。重開建立新表面，舊 completion 不會藏起或重開它 |
| thinking／executing | 僅既有投影 `turn.state=running`、Core online、provider connected、非 reconnecting 且 taskState 為 thinking／executing 時，符號透明度 1↔0.65 | 每段 650 ms，純 QML；不是百分比。queued／starting 目前維持原文字，無活動 pulse；沒有待命彈跳 |
| cancelling／awaiting | 原文字「正在停止」／「需要你的確認」；working cue 同步停止並回 1 | 不改 cancel／approval／preview。收合不是取消，不新增自動操作 |
| succeeded／failed／partial／unknown／cancelled／offline | 原真實文字與操作；無結果動畫 | working cue 同步停止。unknown／partial 不當成功；完成回彈延後，避免未經核定的結果編排 |
| 隱藏／銷毀／重定位 | 立即停止 interpolation；隱藏停止 working cue，Dock 釋放陰影層；助理隱藏停止既有 remap timer | 不動已訂閱的會話生命週期；該投影仍供 task／approval 使用。screen／corner／entry scale／Dock position 改變就 settle，沒有位置平滑 |

`MotionValue.qml` 僅保存一個 Shell 視覺數值，stop 後從當下值重定向；沒有延後寫語意狀態的 completion。Dock 是獨立套件，使用相同的簡單 NumberAnimation stop／retarget 模式，不 import Shell 目錄。無新程序、RPC、輪詢、持久化設定或第二份 ConversationState。

## 候選參數與降級

- `motionFeedback=120 ms`、`motionPresent=180 ms`；OutCubic。Dock readback 的 OutBack 設 overshoot=0，只做有界回復，最大不超過原圖示。無未測 spring／damping 常數。
- `reduced_motion`、現有 system／environment reduced-motion，或 `low_power_style` 關閉 interpolation 和 working pulse；運行中改 Profile 偏好會同步 settle。同內容、狀態文字、Accessible name／description、鍵盤與 pointer action。
- reduced-transparency 沿原不透明材質；software renderer 沿原 non-shader 材質。這些純 scalar 動態不需要 shader，故可保留；運行中切降低透明度不改動作或內容。沒有新的 renderer 能力宣稱。
- `avatar.animations=false` 同時停助理與其 compact 淡入；legacy compact（無 entryRect）、legacy avatar、非淺色 Dock 的呈現沿用原樣。OS gsettings 的即時監看仍由 #47 接手，本 slice 不新增 watcher。
- 局部 QML 材質陰影、compositor live backdrop、整窗 wobble 是三件事。本 slice 沒有新增 blur／shader，沒有啟用 live backdrop 或整窗 wobble，也沒有 drag-position smoothing。

## 重跑與證據界線

Node 依 `.nvmrc` 經 NVM；Qt 依 runner 指定 `QT_PREFIX` 與 `LD_LIBRARY_PATH`。執行：

```sh
bash tests/g4/motion/run.sh /data/hermes/ditto-runs/g4-impl/r2-motion/evidence/checkpoint/focused
```

QtTest 使用實際 AssistantEntry、MotionValue、staged DockPill／ChatPanel，檢查實際 scale／opacity、反向與連點、長幀、偏好切換、隱藏與銷毀、終態停止、同一草稿／turn、回讀後才給 Dock 提示及輸入區。Core／視窗資料都是 fixture；Quickshell layer-shell 是既有純 QML 替身。不是實際 Wayfire 命中區或焦點證據。

首個 regression 在 production 修正前 RED（press scale 仍為 1）；原始 log 在 repo 外 `…/evidence/checkpoint/motion-red.log`。同目錄保存 focused motion、既有 Dock／assistant unit／assistant flow、i18n 與逐檔 baseline／candidate qmllint。staging 的 avatar 原始碼完整比對改釘實際合併基底 f99b4ea，因其已有 statusForeground 對比修正；25c0b72 的 legacy 呈現 fixture 及 approval 比對保留。

首次 checkpoint `b25d865` 刻意在 coherent commit 停止。後續同一 thread 增加 [可重跑的原生錄影](../../../tests/g4/motion/README.md)、靜態 capture 的實際 settle 與 renderer 回讀；完整執行結果、來源／commit 綁定及可播放媒體由 repo 外 `…/evidence/final/manifest.json` 索引。不得將 Qt offscreen 結果當實體動畫或幀預算證明。實體 Wayfire、NFR-05／資源、熱插拔、IME／Orca、使用者測試與 owner 動態核定均未執行。#81 狀態載入正確性不在本 slice 修改。

後續原生樣本發現 Dock show handler 讀取依賴 shown 的衍生旗標時，其通知順序使 reveal 沒有啟動。以實際 revealAnimation.running 與 settle 後像素穩定的 QtTest 先取得 RED，再將啟動條件改為直接讀取最新 shown 意圖；不新增時長、queue 或 completion。初始失敗和探針保存在 repo 外，不以成功 wrapper 隱藏。靜態 capture 保留正常 production motion，等待真實動畫值 settle；錄影另保留實際過渡。

## F1 焦點身分過渡修正（PR #82 repair 1）

確認回饋只編碼**供應者觀測到的 focused window ID 過渡**，不編碼 delegate 建立／重建。首次快照（包含已聚焦視窗）只建立基線；其後 ID 改變且 shown／淺色／motion enabled 時啟動一次。供應者保有一個有限插值，只有代表目標視窗的第一個 tile 讀取它；同身分的重建延續當下值，不重新起跳。觀測基線在隱藏或降低動畫期間仍更新，恢復可見／動畫不重播。這是 Shell 暫態，沒有新的焦點權威、RPC、retry、持久化或排程。

下列測試均在 `tests/g4/motion/tst_dock_focus_identity.qml`；raw reviewer reproducer 僅改 import／staging 路徑後另存 `tst_dock_readback_repro.qml`，原始檔與失敗 log 不修改。

| Row | 觀測／意圖 | 行為 | QtTest 對應（省略 `test_`） |
| --- | --- | --- | --- |
| T01 | 初始空／已聚焦快照 | 建基線，0 次確認 | `T01_initial_observation` |
| T02 | 真正 ID A→B／none→B | 符合偏好時恰一次，只有 B tile 接收 | `T02_T03_real_transition_loss_and_regain` |
| T03 | 失焦／全未聚焦→再聚焦 | 立即停止／settle；再聚焦可一次 | 同上 |
| T04 | 同 ID，title upsert | 0 次新啟動；既有插值不重啟 | `T04_T07_identity_preserving_rebuild(title)`、`T04_T07_rebuild_during_confirmation_continues_without_restart` |
| T05 | 同 ID，x／y／geometry／size 串流 | 0 次新啟動，不持續回彈 | `T04_T07_identity_preserving_rebuild(geometry-size)`；raw reproducer 的 20 次 stream |
| T06 | 無關視窗 open／close | 0 次新啟動 | `T04_T07_identity_preserving_rebuild(unrelated-open/unrelated-close)` |
| T07 | apps reload／reorder、pinned reorder | 0 次新啟動；運行中重建不重啟 | `T04_T07_identity_preserving_rebuild(apps-reload/apps-reorder/pinned-reorder)`、運行中重建測試 |
| T08 | 同 ID hide→show | hide 停止；show 不重播確認（通用 reveal 分開） | `T08_T09_same_id_restore(hidden)` |
| T09 | 運行中 reduced-motion／low-power→恢復 | 停止／settle，不排隊或重播 | `T08_T09_same_id_restore(reduced-motion/low-power)` |
| T10 | hidden 期間 ID 改變→show | 更新基線，0 次啟動；show 不重播 | `T08_T11_T14_eligibility(hidden)` |
| T11 | reduced-motion／low-power 期間 ID 改變→恢復 | 同上 | `T08_T11_T14_eligibility(reduced-motion/low-power)` |
| T12 | 同 app 兩視窗切換；多 alias tile 同窗 | 以 window ID 判斷；每次只有一個目標 tile | `T12_same_app_two_window_identity`、`T12_one_target_when_alias_tiles_share_a_window` |
| T13 | 快速 A→B→A、重複同 ID、再到 C | 每個真正觀測過渡至多一次；只留最新插值，沒有舊 completion 重播 | `T13_rapid_burst_latest_id_only` |
| T14 | legacy 主題，初始／後續回讀 | 不新增確認動態，原靜態指示沿用 | `T01_initial_observation(legacy-focused)`、`T08_T11_T14_eligibility(legacy)` |
| T15 | Dock 先顯示、第一份快照後到；快照先到再載入 Dock | 兩種順序都以第一份快照建基線，0 次確認；其後真正過渡照常 | `T15_dock_shown_before_first_snapshot`、`T15_snapshot_before_dock` |
| T16 | 斷線→重連（焦點不變／離線期間改變／重連後無焦點） | 斷線即停止進行中確認並清基線；重連快照重新建基線，0 次重播 | `T16_reconnect_rebaselines_without_replay`、`T16_disconnect_settles_running_confirmation` |

#84 修正：「第一份快照」以 client `online`（subscribe 回應已套用 snapshot）界定；`online` 之前的空陣列與斷線後的舊清單都不算快照。沒有 `online` 屬性的 fixture client 視為一直持有快照。不新增 RPC、輪詢或持久化；實體 Wayfire 的實際啟動順序未執行。

盤點：DockPill 的 `Repeater(entries)` 曾在 delegate 的 `onCurrentChanged` 啟動確認，因此是新增 F1。DockBottom 的 `Repeater(client.windows)` 同樣會重建互動暫態，但只有靜態 focused 色／字，沒有確認動畫；屬 legacy F3。PanelTop 讀 focused title、Shell 保存 lastFocusedApplication、ChatFocusReturn 以 ID 防止錯誤回焦，均不啟動 tile 確認。TasksPanel 和 launcher 依 task／app model 顯示，不是焦點確認消費者。本修正保留原 array model，**F3 的 hover／press／鍵盤焦點重設留待另案**。

**F2 未驗證**：真實 Quickshell window 隱藏是否同步傳到 child Item.visible，沿用既有 Avatar 慣例；offscreen stub 不證明這件事，交 #47／#68 實體驗證。原 native video 保留為歷史；修正後另錄同一原生樣本，補同 ID 的 title／geometry／無關視窗更新與實際確認啟動次數，放 repo 外 `…/evidence/repair1/media/`。完整 RED→GREEN、gate／來源／blob 綁定由 `…/evidence/repair1/manifest.json` 索引。參數與 instant close 邊界不變，不代表 #66 全部通過。

## F3 Dock tile 互動生命週期（#83）

上段「保留原 array model」記錄的是 PR #82 的修正邊界。#83 改以 provider 內的 `ListModel` 驅動兩個 Dock 的 Repeater；保留原資料來源與 DockPill 的 `entries` 查詢投影。這只是 Shell 呈現暫態，不是第二份 Core／Profile 權威，也沒有新 RPC、輪詢或持久化。

DockPill 以 `app:<pinned appId>` 識別釘選 tile，以 `window:<window id>` 識別其他執行中 tile；DockBottom 直接使用 window id。對照新投影只 remove 真正消失的 key、insert 新 key、move 排序改變的 key，並在資料值變更時 set 單一 `entryData` role。保留完整 entry payload，讓既有 activation、Accessible name、running／current 與 geometry 回讀照常更新；無須逐欄重新定義視窗 schema。兩個 provider 各自保有小型 reconciliation 函式，維持獨立套件，不引入跨 provider／Shell 路徑依賴。`stage-providers.mjs` 只多列 DockBottom，仍僅移除 layer-shell 行。

身分取捨：釘選 app 的視窗關閉／重新開啟仍使用同一 tile；同 app 的非釘選多視窗分別保有 window id。既有 schema 允許重複 pinned appId，diff 依出現順序配對，最後移除多餘列，不改原配置或去重。pin／unpin 會切換 app／window key，視為舊 tile 消失、新 tile 出現，不把已消失身分的 focus／press 偷渡過去。tile 移動後，hover 仍以實際游標位置判定；pointer grab 與鍵盤焦點跟著原物件，不凍結舊 hit region。確認動畫仍由 provider 觀測 focused window id，保留 T01–T16、#84 的快照基線與斷線處理，沒有更改動畫參數。

新增測試在 `tests/g4/motion/tst_dock_tile_lifetime.qml`：

| 驗收 | Provider／測試（省略 `test_`） |
| --- | --- |
| title、geometry、無關 open／close、apps reload／reorder、pinned reorder、真正焦點變更時保留 hover／press／activeFocus；操作使用最新 payload | DockPill：`upsert_preserves_input`（3 種 input × 8 種更新） |
| feedback 插值不中斷，20 次 geometry stream 及 title／apps／pinned／focus 更新不重啟 | DockPill：`feedback_stream_continues_without_restart`（hover／press／focus；實際值與 Animation.started 次數） |
| title、geometry、無關 open／close、window reorder、焦點變更時保留 press／activeFocus | DockBottom：`bottom_preserves_input`（2 × 6）；原來沒有 hover 樣式或確認動畫，不增加新的效果 |
| 排序真的移動 tile，保留 keyboard focus／pointer grab，Tab 依新順序走 | 兩者：`move_keeps_delegate_and_keyboard_order`、`move_pressed_tile` |
| 釘選 app 視窗替換、同 app 多視窗仍分立 | DockPill：`pinned_identity_survives_window_replacement`、`unpinned_window_ids_do_not_collapse_same_app`、`duplicate_pinned_count_reduction_removes_only_retired_tile` |
| 移除無殘影／錯誤 focus／鄰居誤觸，重新出現不繼承舊 press／focus | 兩者：`removed_identity_retires_input` |
| release 隱藏／清 exclusiveZone，destroy 後無 tile，替換後不繼承 input 且單次觸發 | 兩者：`release_and_replacement`；原有 reduced-motion／hidden settle 由 `tst_dock_motion.qml` 回歸 |
| legacy bubble 外觀與靜態效果 | `legacy_keeps_static_style_and_input`，加上 visual suite 的既有 legacy 幾何／像素比較 |

RED 在 main `34dd21c` 與本案基底 `a29bca2` 的真實 DockPill 上各得到 18 項行為失敗（8 passed／18 failed／0 skipped），沒有 compile／undefined 失敗。原始測試與兩版 provider、log、執行方式在 repo 外 `/data/hermes/ditto-runs/g4-impl/fix83/evidence/red/`。首個 checkpoint motion 94／94；補強排序、移除與串流測試後，完整 gates 及 source／head 綁定見同 evidence 目錄的 `manifest.json`。重複 pinned appId 縮減的額外 RED（殘留 4 列，應剩 3 列）另存 `red/duplicate-pinned.log`。開發期間尚未等 layout polish／動畫真正 stopped 就檢查的失敗 log 也保留在 `checkpoint/`，同步點修正為等待實際狀態，沒有改 production 時長或放寬原斷言。

上述均為 Qt 6.10.2 offscreen 開發證據，Core 與 layer-shell 仍為 fixture。實體 Wayfire 鍵盤／hit-region、F2 window 隱藏傳遞、IME／Orca、NFR-05／資源量測與新錄影均**未執行**；#47／#68 的原生驗收與 owner 動態核定仍獨立進行，不以本套測試代替。

本 runner 的 canonical `node scripts/lint-shell-i18n.mjs` 在 Node `spawnSync(lrelease)` 回報 `EPERM`（exit 1），該 gate 記為 BLOCKED，未改 lint 或略過其檢查。直接執行同一 Qt lrelease 的兩語系產物與 repo `.qm` 完全相同，僅作補充證據，不能取代 canonical gate。沒有使用者可見文字變動。
