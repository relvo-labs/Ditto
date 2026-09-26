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

G0 進行中。主要開發機同時是主要[參考機](docs/platform/support-matrix.md) `ditto-ref-ws-rtx4060-01`；其他機器仍可開發，但出口數字不可跨機混算。**合成器是 Wayfire（D-02 已於 2026-09-22 決定方向），Sway 支援已遺棄**——`sway.rs` 與開發容器只保留為決策對照。參考機 runner 已在線；Firefox／foot／Kate 的能力矩陣得到 30 項回讀驗證、40 項讀取、3 項 close request 送達，Shell 重啟 20／20 存活，生產命中遮罩雙向成立，三次精確呈現 p95 約 16.20～16.23 ms 且動畫熱路徑 RPC 為 0。C-09 activation、C-10 最小鎖定與 C-13 XWayland 也已功能探測。**尚未成立**：登入管理器的實體登入與中文輸入（C-08）、三次真正 cold-login PSS／D-06a、變更進版後的連續三晚 nightly、第二人重建與工作流 owner／估算核定；逐項見 [G0 出口預檢](.agents/notes/gate-reviews/G0-exit.md)。Cordis 宿主與 Agent 本來就在 G0 範圍外。前端原型（`apps/desktop-prototype/`）**凍結為互動契約參考，不是實作起點**。

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
