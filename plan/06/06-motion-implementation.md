# G4 R2 動態實作計畫

狀態：實作計畫，不代表動態參數已由 owner 核定或 NFR 已通過。主責 #66；設計上層 #64，聯合證據 #68。基底 main `f99b4ea0db5ceff1ef98956b7e32895784746157`，PR #80 已合併。

## Design Read 與界線

沿用淺色柔光原生 QML 元件、現有語意 token、字型、圖示及助理標籤；不是品牌或構圖重設計。動態低強度、短且可中斷，只改善真實操作回饋；靜態原圖不證明動態。hover／pressed／focus 不挪動其他 hit target，焦點與可操作性不等待視覺 settle。參數是待核定的原生樣本，不冒充 final。

## 交付順序

1. 讀取 project skills 與 PRD／設計契約；盤點目前 Dock、助理、聊天面板的動畫、偏好、顯示器重定位及 effect 存活路徑，補一份精簡 state／transition 表與候選參數。
2. 測試先覆蓋 latest-intent、反向／連點、失焦／隱藏、運行中切偏好與終態停止。共用最小本機 motion policy；接既有 Dock 與助理，保留 legacy 呈現與單一 ConversationState。動態只用 QML，本 slice 不新增 RPC／程序／輪詢或 Core 持久化契約。
3. 正常、reduced-motion、reduced-transparency、low-power／software 路徑保持同內容與操作；工作 cue 只依真實階段，取消與終態立即停止，unknown／partial 不演成成功。分清 QML 局部 effect、compositor backdrop、整窗 wobble；不啟用未支援能力、不換 compositor。
4. 首個 coherent implementation commit 後即保存遠端 Draft checkpoint；之後完成 QtTest、中斷／隱藏清理測試、既有 visual／assistant 回歸、i18n 與逐檔 qmllint 差異。產出可重跑的原生 QML 動態樣本／錄影與 renderer provenance，原始媒體放 repo 外。
5. coordinator 凍結 exact head、執行必要 affected-surface gates 並派 fresh independent review；修正後再判 Ready。合併、發布與人類驗收另外授權。

## 寫入範圍與隔離

唯一 writer 擁有 `shell/jelly/` 的 motion policy／tokens、`shell/providers/dock_pill/`、必要的 `dock_bottom/`、`shell/assistant/`、`shell/chat/` 的呈現動畫、`shell/shell.qml` 的純呈現接線、相關 g4 測試／runner，以及本計畫和精簡動態契約文件。共享檔案無第二 writer。

不改 Core／Profile／schema、會話與授權語意、approval／preview 預設、legacy avatar 位置能力、素材散布、host runtime、workflow／runner 基礎設施。#81 狀態讀取 follow-up 不併入本 slice；有實際依賴時先停在精確邊界。

## 證據與未執行項

Qt 離屏或本機測試只證明其執行範圍；實體 Wayfire、移屏／熱插拔、IME／Orca、原 NFR-05 指定操作 95% 幀 ≤16.7ms 及資源三次重複仍由 #47／#49／#52／#53／#68 接手。沒有實際資料就標示未執行，不改門檻。桌面初次呈現、hover／press、展開／收合、working／cancelling／終態各列 implemented／verified／pending。

回退：回復此 PR 的 Shell 與測試變更，不涉及 store migration、設定覆寫或正式資料。

## 首次 checkpoint 實作邊界

狀態／過渡與候選參數見 [R2 原生動態候選](../../docs/design/default-desktop/motion-candidate.md)。已接淺色 Dock 圖示、助理符號與 compact 內容；working cue 依同一 ConversationState 投影，在 cancelling／終態／斷線／隱藏立即停止。close 與 compact／full 切換保留立即銷毀，退場動畫延後，不讓 focus／input 租用跟著視覺停留。

首次 checkpoint 的 focused motion QtTest 為 31 passed／0 failed（含各 TestCase setup／cleanup）；既有 Dock 9、assistant unit 27、assistant flow 12 通過。shell i18n 575 字串／181 Core keys／2 語言通過；7 個變動 QML 的 qmllint 無新增診斷，既有 16 個 metadata 警告保留。完整 runner／媒體／獨立審查尚未執行，不能將本 checkpoint 當 Ready 或驗收完成。原始證據在 `/data/hermes/ditto-runs/g4-impl/r2-motion/evidence/checkpoint/`；最終 SHA 由 checkpoint handoff 回報，不在 commit 內自我引用。
