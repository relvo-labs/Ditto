# Ditto

以對話驅動的可組合 Linux 桌面系統。桌面的外觀、布局、操作方式與功能由插件組成；LLM 理解需求，透過正式能力介面修改配置與組合，結果可保存、檢查與回復。本檔只做導覽。**任何需要判斷的規則都屬於某個 skill 或權威文件，這裡不重述。** 衝突時以權威文件為準，skill 次之，本檔最後。

## 動手前先讀

| 文件 | 是什麼 | 何時讀 |
| --- | --- | --- |
| [docs/product/Ditto-PRD-v0.4.0.md](docs/product/Ditto-PRD-v0.4.0.md) | 需求權威：26 節、116 項需求、32 組驗收情境 | 任何功能決定之前 |
| [milestones/01/](milestones/01/README.md) | 實作順序權威：G0～G5 分階段計畫、架構、Cordis 沿用、驗收矩陣、風險與決策 | 排序、估算、出口評審之前 |
| [docs/research/RESEARCH-AND-INTERACTION.md](docs/research/RESEARCH-AND-INTERACTION.md) | 互動決策依據與原型邊界 | 設計互動之前 |
| [plan/02/](plan/02/README.md)、[plan/03/](plan/03/README.md)、[plan/04/](plan/04/README.md) | G0／G1／G2 執行計畫：範圍、出口、工作包、依賴與決策；G2 含 Codex 訂閱＋app-server，44 包／十九項出口，選型與估算待核定 | 該階段動手之前 |
| [.agents/skills/](.agents/skills/README.md) | 把上述原則轉成可觸發判斷程序的 skill 集合 | 見下方觸發速查 |

G3 計畫與獨立基礎設施見 [plan/05](plan/05/README.md)，主追蹤為 issue #34。依 [D-45](.agents/notes/decisions/2026-10-13-d45-g3-independent-foundation.md)，在 `codex/g3-restricted-generation` 疊在 G2 的 `a88bce8` 上開始；起始接線等待條件已由 D-46 取代，G2 PR #13 已合併；G2／G3 證據不得混用。

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

逐情境的觸發速查（「我正在新增一項能力…」）、完整索引、分類與關聯地圖見 [.agents/skills/README.md](.agents/skills/README.md)；觸發表由 lint 從計畫產生，不在此重複維護。標示 `draft` 的 skill 描述的是尚未實作的契約，對應子系統落地後須回頭核對。

## 專案現況

**G0、G1 已完成（2026-10-07 owner 實際使用裁定 [D-38](.agents/notes/decisions/2026-10-07-d38-g0-g1-owner-acceptance.md)），G2 功能由 owner 依 [D-46](.agents/notes/decisions/2026-10-13-d46-g2-functional-acceptance-and-g3-integration.md) 接受，G3 依 [D-47](.agents/notes/decisions/2026-10-17-d47-g3-exit-vm-evidence.md) 接受出口，PR #40 已合併；G4 規劃見 [plan/06](plan/06/README.md)、[#42](https://github.com/relvo-labs/Ditto/issues/42)。** 原生 Core、交易與儲存、Cordis hostd、可替換 QML 供應者、管理中心、救援與鎖定均已落地。G2 在分支 `codex/g2-agent-foundation`：Agent 與 `ditto-confine` 內的 Codex app-server、對話、approval、context、工作池、區域布局與語意任務集已有開發證據；真實訂閱、語意集及參考機冷登入量測已有證據，D-44 後端先採 1G 寬鬆上限；剩餘項目由 #35～#39 追蹤，逐項見 [G2 評審紀錄](.agents/notes/gate-reviews/G2-exit.md)。

G3 分支 `codex/g3-restricted-generation` 已接正式生成能力、隔離原生驗證／預覽、固定模板 Shell 解譯、啟用與資料回退；實體座位的真模型、鍵盤取消、資料回退、逐關故障、OS 超限存活及三態信任矩陣已有證據，並修正逾時關卡遺失與失敗文案。見 [實體驗收](.agents/notes/gate-reviews/G3-reference-seat-2026-10-14.md) 與 [G3 評審紀錄](.agents/notes/gate-reviews/G3-exit.md)；G3 出口依 D-47 通過，未涵蓋部分交接 G4。

主要開發機同時是主要[參考機](docs/platform/support-matrix.md) `ditto-ref-ws-rtx4060-01`；其他機器仍可開發，效能數字不可跨機混算。**合成器是 Wayfire（D-02 已於 2026-09-22 決定方向），Sway 支援已遺棄**——`sway.rs` 與開發容器保留為決策對照。參考機 runner、原生應用回讀、Shell 重啟存活、身分負例與三次冷登入資源量測已有紀錄。

階段接受後，實體鍵盤中文輸入證據、D-06a 預算核定、第二人重建、人工錄影、實體雙螢幕、五晚 nightly、桌面基本面、內建套件升版與呈現時間交叉量測警訊繼續依 D-38 追蹤。逐項證據見 [G0 評審](.agents/notes/gate-reviews/G0-exit.md)、[G1 評審](.agents/notes/gate-reviews/G1-exit.md)。前端原型（`apps/desktop-prototype/`）**凍結為互動契約參考，不是實作起點**。

## 目錄

```
docs/          PRD、研究、後續的架構與契約文件
milestones/01/ 分階段實作計畫
plan/          skill 建置計畫與 G0／G1／G2 執行計畫
.agents/       skill 集合與決策紀錄
apps/          前端原型（凍結）
crates/        Rust 契約、Core、儲存、系統轉接、監督、CLI 與量測工具
packages/、schema/ Cordis 宿主、SDK、服務插件、TS 契約與 Rust 匯出的 schema
shell/         Quickshell／QML 桌面、管理中心、供應者、救援與鎖定
tools/、tests/g0/、tests/g1/、scripts/ 平台工具、驗證夾具與 CI／skill lint
```
