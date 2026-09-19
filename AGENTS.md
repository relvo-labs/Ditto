# Ditto

以對話驅動的可組合 Linux 桌面系統。桌面的外觀、布局、操作方式與功能由插件組成；LLM 理解需求，透過正式能力介面修改配置與組合，結果可保存、檢查與回復。

本檔只做導覽。**任何需要判斷的規則都屬於某個 skill 或權威文件，這裡不重述。**

## 動手前先讀

| 文件 | 是什麼 | 何時讀 |
| --- | --- | --- |
| [docs/product/Ditto-PRD-v0.4.0.md](docs/product/Ditto-PRD-v0.4.0.md) | 需求權威：26 節、116 項需求、32 組驗收情境 | 任何功能決定之前 |
| [milestones/01/](milestones/01/README.md) | 實作順序權威：G0～G5 分階段計畫、架構、Cordis 沿用、驗收矩陣、風險與決策 | 排序、估算、出口評審之前 |
| [docs/research/RESEARCH-AND-INTERACTION.md](docs/research/RESEARCH-AND-INTERACTION.md) | 互動決策依據與原型邊界 | 設計互動之前 |
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

實作尚未開工。目前只有前端互動原型（`apps/desktop-prototype/`，**凍結為互動契約參考，不是實作起點**）、PRD 與實作計畫。Rust Core、Cordis 桌面宿主、QML Shell 與 Agent 皆待 G0 開始。

## 目錄

```
docs/          PRD、研究、後續的架構與契約文件
milestones/01/ 分階段實作計畫
plan/01/       .agents skill 集合的建置計畫
.agents/       skill 集合與決策紀錄
apps/          前端原型（凍結）
scripts/       倉庫工具（目前：skill lint）
```
