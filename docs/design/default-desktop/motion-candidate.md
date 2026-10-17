# R2 原生動態候選（#66，checkpoint）

狀態：可執行的 S2 候選，基底 `f99b4ea0db5ceff1ef98956b7e32895784746157`。參數尚待原生樣本與 owner 確認；不是 #66 關閉、NFR-05 通過或 final 動態核定。沿用 [設計契約 §4](design-contract.md#4-動態編排提案) 與 [M1／P1](workplan-and-acceptance.md#2-驗收矩陣)。

## 盤點與狀態／過渡表

基底已有 Tokens 的 fast／medium／slow／fade、reducedMotion／reducedTransparency／lowPower；系統 reduced-motion 在 Shell 啟動時讀一次。Material 的局部陰影依 renderer 降級。DockPill 與 AssistantEntry 原本沒有動畫；compact／full chat 依 `chat.open` 與 mode 建立／銷毀。既有 avatar 動作、ChatFocusReturn、ConversationState、approval／preview 不在本 slice 重做。

| 表面／真實狀態 | 本 checkpoint 的過渡／提示 | 中斷、回退與界線 |
| --- | --- | --- |
| 首次呈現 | 淺色 Dock 圖示 0.98→1；助理符號 0.96→1；compact 內容透明度 0.92→1 | 固定背板、幾何與 hit target；沒有開場操作鎖。頂部、桌布、launcher 及 full window 開場未新增動態 |
| hover／鍵盤 focus | Dock 圖示／助理符號縮至 0.96，原有底板／焦點框與標籤保留 | 120 ms；移開／失焦轉向新目標；不重排相鄰按鈕，不縮放 hit target |
| pointer press／release | 同一局部圖示縮至 0.90，再回當下 hover／focus／expanded 目標 | 120 ms；連點不排隊。Enter／Space／Accessible action 立即沿原路操作，以 focus 框提供等價鍵盤提示 |
| Dock launch／focus | 點擊直接發原命令；真實視窗回讀 `focused` 才一次 0.94→1；running 點與 current 長條立即反映真狀態 | 180 ms，沒有樂觀成功或無限彈跳。新視窗未聚焦時只有原 running 點；失敗沿原 notice。`dock_bottom` 與 launcher 維持原樣 |
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

本 checkpoint 刻意在 coherent commit 停止：完整 visual／assistant capture runner、錄影、fresh independent review 留給同一 thread 的後續回合。尚無媒體檔；不得將 Qt offscreen 結果當實體動畫或幀預算證明。實體 Wayfire、NFR-05／資源、熱插拔、IME／Orca、使用者測試與 owner 動態核定均未執行。#81 狀態載入正確性不在本 slice 修改。
