# G3 功能補齊與逐 issue 完成狀態

2026-10-14，對應使用者「總規劃跟每個 issues 都做完了嗎？功能要確實做完」。基底 `830281c23324b3e5564e11a39552b3b525855feb`；[#34](https://github.com/relvo-labs/Ditto/issues/34) 與 #15～#33、PR #40、PRD、plan/05 與相關 skills 已逐項對照。**不是所有 issue／G3 出口都完成**；以下區分本次補齊的功能、已執行驗證及仍需實體座位／owner 的出口。[證據索引](G3-functional-completion-evidence-2026-10-14.json) 保存 54 檔實作指紋及 282 份原始檔 hash。前一輪原始數字保留於 [followup](G3-followup-2026-10-14.md)，不套用到新版程式。

## 實際功能修正

1. **升版不能只回讀 entry id。** 原固定模板升版保持 entry id，舊版仍掛載時可能被當成新版成功。Shell 現在從實際物件回報 artifact id；Core 的交易回讀及 `plugins.list` 都核對。缺 id／舊 id 不會通過，既有補償路徑回復舊 revision、面板及資料。Rust-first 選用欄位、三個共用向量及配對 build／舊 Shell 的相容規則記在 `docs/contracts/agent-0.3.md` §5。
2. **排隊後仍要有授權。** 生成寫入及啟用在 coordinator 接受點重查 grant／工作階段鎖定；撤權後不得沿用排隊前的檢查。同次真正 consumed approval 由 Core 內部 receipt 保留，不是 caller 欄位、不建立永久 grant。釘選 app-server 實際完成一次性啟用，另回讀確認沒有永久 data grant。
3. **管理中心可接回工作。** 重開時讀 Core 產物／工作，外部 Agent 新工作及關卡事件會出現；兩個預覽各自有鍵盤取消入口。正常畫面顯示逐關通過／失敗／未執行、排隊及清理，診斷收在展開區。同時間戳的晚到快照不能蓋掉新事件；不新增持久清單或背景輪詢。
4. **補齊失敗與資料矩陣。** 五個 Core 測試涵蓋 load／health／錯版本回讀、資料快照 commit 失敗、兩次升版回第一版、不可逆／損壞快照拒絕及撤權。交易 fixture 明確標示 forged full 只作測試 setup；OS full 另由 native／VM 驗證。
5. **安全矩陣實際執行。** 固定 Qt runner 有控制組、五個逐關失敗及非法 import 七案例；每案回讀 cgroup 限制、confine、未執行關卡及整組清理。真 archive 的任意 QML／Node／原生 ELF 分別在 full、舊 ABI partial 與缺 bus unavailable 跑九格負例，保存 Core 拒絕紀錄、revision 與 QML／Node 執行見證；原生 host kind 在安裝即拒絕。

CI 證據副本權限、無進展修復預算、逐關實測時間等前一輪修正仍包含於此交付。未開放自由 QML／JS／native 或通用遷移腳本，沒有增加常駐程序。

## 驗證與版本界線

| 類別 | 已執行結果 |
| --- | --- |
| Rust／Node | workspace **254／184** 項通過；Node 另 2 項既有 trial 略過；typecheck 通過 |
| 格式／契約 | workspace fmt／clippy、fault clippy、Rust schema／TS／固定模板新鮮度、7 個新增共用向量通過 |
| 正式 QML | 固定模板 QtTest 5 項；管理中心 QtTest **6 項**，涵蓋重開、雙預覽鍵盤取消、逐關失敗、同時間戳晚到快照、外部新工作；lint 無錯誤 |
| 故障／release | 真 binary persistence_faults 3 項通過；fault build 陽性控制被 guard 拒絕；正式 Core／dittoctl／supervisor release 無 fault points |
| G2 受影響回歸 | loopback app-server 工具 40、撤權競爭 7、注入拒絕 18；真 Shell 聊天／approval **19 項通過**。只證明共用路徑未破壞，不更新 G2 資源或 owner 裁定 |
| full VM | 最終 `2026-10-14T06-46-20Z-9e6e37d`：**14 步通過**；Core 37、unavailable 14、桌面 45、Agent 17、重啟 8、原生逐關負例 7、OS 10、QtTest 5＋6。前兩輪 `06-26-51Z-830281c`／`06-37-47Z-830281c` 的 14 步也保留，不用它們代替最後 UI 補強 |
| partial VM | `2026-10-14T06-29-03Z-830281c`：7 步通過；Core partial 25、unavailable 14；候選執行明確 not_run，退出 2。原生 runner 沒有執行候選／發布 |
| 上游／文案 | 9 檔 upstream hash、vendor 修改 0；569 字串／181 keys／雙語通過；skills 0 error、1 個既有 AGENTS 長度警訊 |

full／partial 與真模型在最後 UI 補強前的共同來源樹為 `d1aea05a287985f8126e42e56008a2b085690753d43beaf1d5d5e65082fdf157`。原始完整來源與 native hash 各自保留，不用一個 HEAD 代表所有 dirty run。後續文件、管理中心及 CI 版本分列；原始失敗不刪除。證據路徑與檔案 hash 另存同名 evidence JSON。

最終完整 VM 的實作 commit 為 `9e6e37d9fb007d811121e15a9b8da3653bace4c9`，來源樹 SHA256 `50dc9421750fffa7f9dfd909d5ca30040c5efb6d3a3b7421d83eb2deed8d2f9e`；dirty 部分僅後續計畫／證據文件。核心 `7.0.0-38-generic`、native runner SHA256 `8896ba87d173aea182f5aaaa1833c45f4e4c2d04bb8b9a83888773b3d993930c`。本機與真模型核心為 `6.17.0-40-generic`；不能混算效能或宣稱實體座位。

## 已授權真實模型

延用使用者明確授權「使用既有登入執行真模型測試」，於私有開發 store 執行，沒有複製／輸出憑證。`artifacts/g3/real-model-20261014T062738Z.json`：**19 項通過、四回合 succeeded、restore_errors=[]**；模型 `gpt-6.1-sol`、effort low、釘選 Codex 0.160.0。

| 回合 | 耗時／工具數 |
| --- | --- |
| 新建待辦摘要 | 59.2 秒／11 |
| 新建工作區面板 | 90.8 秒／12 |
| 修改待辦摘要 | 48.7 秒／8 |
| 修改工作區面板 | 39.6 秒／8 |

新 Core 完成兩類新 artifact、五關 full、真預覽及啟用；後續修改未擅改其他欄位。實際掛載面板、待辦服務、按鈕點擊與 Core 工作區狀態相符。原組合 digest／設定與本次 grant 撤銷均經回讀確認。總回合時間包含模型與本機工具，不冒充純模型延遲；未取得 token／金額資料，不推估為零。此為 headless 真模型開發證據，最後管理中心 UI 改動另行測試，不聲稱真模型操作了該頁面。

## 尚未完成與出口

逐 issue 的實作位置、開發證據與剩餘條件見 [plan/05/07](../../../plan/05/07-completion-audit.md)。查詢時 #15～#34 全部 OPEN；不以已有程式碼或開發測試替 owner 關閉。

五出口仍依 G3-exit：AT-06 有真模型 19 項開發證據、AT-07 有逐關 native／交易／OS 故障、AT-22 有三種資料政策與舊版實讀、隔離有 full／partial／unavailable 九格矩陣，**均待 plan/05/04 指定的實體參考座位確認**；AT-18 的三類來源文件與運行已備，待 owner 文件審查。D-17 選型及五出口裁定仍歸 owner。

實體失敗卡片／下一步、Shell／hostd 同 PID、可見預覽與鍵盤操作，不能以離屏或巢狀桌面代替。三次冷登入四態、PSS／CPU／呈現時間、中文／雙螢幕、nightly 等依原計畫及 D-38／D-46 繼續追蹤，不提高門檻、不刪除程序。此次沒有接管、登出或故障注入使用者正在操作的實體桌面。

## 提交與遠端 CI

實作提交 `9e6e37d`，證據另作文件提交，一起更新既有 PR #40；沒有合併 PR 或自動關閉 issue。遠端結果以 PR 的當前 commit／GitHub checks 為準；本檔記錄提交前的本機及 VM 驗證，不能用這些成功覆蓋原 HEAD 的 checkout 失敗，也不預告 CI 成功。

PR 推送後的實際 CI 差異另記於 [CI 增補](G3-ci-followup-2026-10-14.md)：lifecycle 通過；G3 的長 checkout 診斷 socket／早期 Report 形狀已修正，管理中心產物清單亂序保護補至 7 項 QtTest。上方完整 VM 的 6 項與來源指紋仍是該輪實測，不回填為後續版本。
