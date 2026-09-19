# Ditto

以對話驅動的可組合 Linux 桌面系統。桌面的外觀、布局、操作方式與功能由插件組成；LLM 理解需求，透過正式能力介面修改配置與組合，結果可保存、檢查與回復。

本檔只做導覽。**任何需要判斷的規則都屬於某個 skill 或權威文件，這裡不重述。**

## 動手前先讀

| 文件 | 是什麼 | 何時讀 |
| --- | --- | --- |
| [docs/product/Ditto-PRD-v0.4.0.md](docs/product/Ditto-PRD-v0.4.0.md) | 需求權威：26 節、116 項需求、32 組驗收情境 | 任何功能決定之前 |
| [milestones/01/](milestones/01/README.md) | 實作順序權威：G0～G5 分階段計畫、架構、Cordis 沿用、驗收矩陣、風險與決策 | 排序、估算、出口評審之前 |
| [docs/research/RESEARCH-AND-INTERACTION.md](docs/research/RESEARCH-AND-INTERACTION.md) | 互動決策依據與原型邊界 | 設計互動之前 |
| [plan/02/](plan/02/README.md) | G0 執行計畫：範圍界線、九項出口門檻、19 個工作包、週序與決策時點 | G0 期間動手之前 |
| [.agents/skills/](.agents/skills/README.md) | 把上述原則轉成可觸發判斷程序的 skill 集合 | 見下方觸發速查 |

衝突時以權威文件為準，skill 次之，本檔最後。

## 五條不可違反原則

出處：[milestones/01/README.md](milestones/01/README.md)。違反任一條的變更不予合併。

1. **權威只有一份。** Rust Core 持有配置 revision、權限授予與能力綁定的權威寫入；Cordis 宿主不保存第二份正式 Profile；Agent 只提出計畫。
2. **Agent 退出不得中斷桌面。** Cordis 桌面服務的存活由 Profile 與服務需求決定，不套用 Agent 的閒置退出規則。
3. **模型輸出不是配置。** 自然語言與模型輸出一律先成為結構化 ChangeSet，經確定性驗證後才執行；完成判斷以系統回讀為準。
4. **可生成不等於可執行。** 生成物先在隔離測試宿主驗證；隔離未就緒前只允許受限宣告式模板輸出。
5. **量測不得自我放寬。** 資源與效能門檻以實測核定；達不到時提出數據與調整提案，不得靜默改變程序範圍或調高門檻。

## 觸發速查

| 主題 | skill |
| --- | --- |
| 所有權與契約 | `ditto-authority-boundaries`、`ditto-capability-contract` |
| 執行期與故障 | `ditto-changeset-transaction`、`ditto-cordis-plugin`、`ditto-failure-and-rescue` |
| 資源與權限 | `ditto-process-budget`、`ditto-permission-and-secrets` |
| Agent 與生成 | `ditto-agent-changeset`、`ditto-generation-safety` |
| 介面與文案 | `ditto-qml-shell`、`ditto-prose-standard` |
| 品質與流程 | `ditto-verification-evidence`、`ditto-decision-record`、`ditto-upstream-port`、`ditto-release-audit` |

逐情境的觸發速查（「我正在新增一項能力…」）見 skill 索引；那份表由 lint 從計畫產生，不在此重複維護。

完整索引、分類與關聯地圖見 [.agents/skills/README.md](.agents/skills/README.md)。標示 `draft` 的 skill 描述的是尚未實作的契約，對應子系統落地後須回頭核對。

## 專案現況

G0 進行中。開發容器內可啟動 Quickshell 工作階段：面板、Dock 與角色層由 Core 的 13 項 `desktop.*` 能力驅動，狀態來自快照與事件，寫操作回讀比對後才算成功，合成器做不到的操作回 `unsupported`；客戶端身分由受控啟動器綁定。**尚未成立**：實體參考機與真機 runner、D-02 合成器決策、輸入法、點擊穿透驗證、有效的幀時與 PSS 數字、登入管理器工作階段、Cordis 宿主與 Agent。容器與開發 VM 的結果都是開發證據，不是出口判定；逐項現況見[進度紀錄](plan/02/06-workplan.md#7-進度紀錄)。前端原型（`apps/desktop-prototype/`）**凍結為互動契約參考，不是實作起點**。

## 目錄

```
docs/          PRD、研究、後續的架構與契約文件
milestones/01/ 分階段實作計畫
plan/          skill 建置計畫與 G0 執行計畫
.agents/       skill 集合與決策紀錄
apps/          前端原型（凍結）
crates/        G0 Rust 契約、Core、診斷 CLI 與量測工具
packages/、schema/ 產生的 TS 契約與 Rust 匯出的 schema
tools/、tests/g0/、scripts/ Wayland 工具、合成器探針、驗證輸入與 skill lint
```
