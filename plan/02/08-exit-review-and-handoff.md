# 08｜出口評審與 G1 交接

> 對應 `milestones/01/03` 的階段出口評審檢查表與 `ditto-decision-record` 第 4 步。

## 1. 評審程序

| 時點 | 動作 |
| --- | --- |
| W7 | 凍結功能變更；只修缺口與補證據。量測第 1、2 次完成 |
| W8 前半 | 量測第 3 次；產生所有報告；逐項預檢九個門檻 |
| W8 後半 | 評審會議；逐項裁決；寫 `.agents/notes/gate-reviews/G0-exit.md` |
| W8 結束 | 回寫 `milestones/01/03`（門檻結果）、`04`（量測數字）、`05`（決策與新風險） |

評審不是簡報，是逐項核對證據檔案。**門檻結果只寫「通過」而沒有量測條件與原始資料位置的，視為未完成核對。**

## 2. 評審紀錄範本

`.agents/notes/gate-reviews/G0-exit.md` 的固定結構：

```markdown
# G0 出口評審

| 欄位 | 內容 |
| --- | --- |
| 評審日期 | YYYY-MM-DD |
| 版本指紋 | 核心／Qt／Quickshell／合成器／Rust／Node／Ditto commit |
| 參考機 | 硬體識別 |
| 出席 | 角色 |

## 1. 門檻逐項結果

| 門檻 | 結果 | 證據 | 備註 |
| --- | --- | --- | --- |
| EX-01 原生應用可控 | 通過 ｜ 未通過 ｜ 條件通過（附條件） | artifacts 路徑 | |
| EX-02 合成器缺口與 D-02 | | | |
| EX-03 Shell 重啟存活 | | | |
| EX-04 幀時與熱路徑 | | | |
| EX-05 資源預算與配額核定 | | | |
| EX-06 契約管線與目錄一致性 | | | |
| EX-07 身分無法自述 | | | |
| EX-08 中文輸入鏈路 | | | |
| EX-09 真機 runner nightly | | | |

（不得只寫整體結論。「條件通過」必須寫出條件與其解除時點；任何一項仍為條件通過時，G0 出口尚未通過，除非範圍或門檻變更已依決策程序核定並回寫上位文件。）

## 2. 量測數字與條件

（分層表、3 次重複的個別結果、完整程序清單、排除清單、採樣期間、PID 與 cgroup 對應。）

## 3. 未達標項目

（每項：實際數據、原因分析、調整提案。不得只寫「稍後處理」。）

## 4. 本階段產生的新風險與新決策

（回寫 milestones/01/05 的清單，列出對應列。）

## 5. 下一階段的估算修正

（G1 的人週修正與理由，特別是合成器決策帶來的轉接成本。）
```

## 3. 交付物清單

出口評審時逐項確認存在且可開啟：

| # | 交付物 | 位置 |
| --- | --- | --- |
| 1 | 支援矩陣與平台事實 | `docs/platform/support-matrix.md` |
| 2 | 可重建的參考環境 | `packaging/reference-image/` |
| 3 | 合成器能力差異表 | `docs/platform/compositor-capability-matrix.md` |
| 4 | 合成器探針套件 | `tools/compositor-probe/` |
| 5 | 輸入法報告 | `docs/platform/input-method-report.md` |
| 6 | 工具配額基線 | `docs/platform/resource-quota-baseline.md` |
| 7 | 契約產物與能力目錄 | `schema/`、`packages/protocol/src/generated/` |
| 8 | `ditto-core` 最小服務與 TS client | `crates/ditto-core/`、`packages/protocol/` |
| 9 | 合成器轉接 | `crates/ditto-compositor/` |
| 10 | `dittoctl probe` | `crates/dittoctl/` |
| 11 | Quickshell 工作階段與角色 | `shell/` |
| 12 | 量測工具與報告產生器 | `crates/ditto-measure/` |
| 13 | G0 驗證腳本 | `tests/g0/` |
| 14 | 資源報告（3 次重複） | `artifacts/g0/resource-report-*.md` |
| 15 | 幀時與 RPC 計數報告 | `artifacts/g0/frametime-*`、`hotpath-*` |
| 16 | 視窗能力矩陣結果 | `artifacts/g0/window-matrix-*.jsonl` |
| 17 | 決策紀錄（D-01／02／03／06a／06b／13／14 ＋新增項） | `.agents/notes/decisions/` |
| 18 | 出口評審紀錄 | `.agents/notes/gate-reviews/G0-exit.md` |
| 19 | 授權與依賴清單（起始版） | CI 產出 ＋ `docs/` |

## 4. G1 開工的前置條件

G1 的第一個工作項是 `ditto-host-loader` 交易層（`milestones/01` 的 R2 推論：交易層先於任何桌面服務插件）。它依賴 G0 交出以下六件事；任一缺失，G1 的對應工作只能延後而不能繞過：

| G1 需要 | 來自 G0 | 缺失的後果 |
| --- | --- | --- |
| 能力描述子的完整欄位集與目錄一致性 gate | CORE-02 | G1 的每個 `desktop.*` 能力都會缺欄位，且 seam 三角規則退回人工審查 |
| 事件流的 `seq`／快照／背壓語意 | CORE-03 | 事件橋（G1-HOST-04）沒有可對接的語意 |
| 封閉錯誤集與 `unsupported` 的處理慣例 | CORE-03／05 | ChangeSet 的失敗分支無法窮舉 |
| 回讀比對的實作慣例（`readback_verified`） | CORE-05 | CHG-04「成功才提交」沒有基礎 |
| 呼叫身分綁定 | CORE-04 | G1 的權限模型會建在自述身分上，之後要重做 |
| 合成器能力差異表與 D-02 | PLAT-03 | G1 的能力實作無法判斷哪些會回 `unsupported`，估算失準 |

另外三件不是硬前置，但缺了會讓 G1 很貴：量測工具（否則 G1 的 Cordis 分項預算無從量起）、真機 runner（否則 NFR-04 的 p95 沒有有效量測環境）、`dittoctl probe`（否則 G1 的能力仍然只有 QML 一個消費者）。

## 5. 未解決事項的攜帶方式

G0 結束時一定會有沒解決的事。處理規則：

| 種類 | 怎麼帶走 |
| --- | --- |
| 已知缺口（例如某項能力回 `unsupported`） | 寫進能力差異表與能力目錄的 `availability`，**不是**寫進 TODO 註解 |
| 條件通過的門檻 | 在評審紀錄寫明條件與解除時點，並在 G1 的第一次週檢查點複查 |
| 未達標的指標 | 附數據的調整提案進入決策程序；在提案被核定前，`milestones/01` 的原始門檻仍然有效 |
| 新發現的風險 | 回寫 `milestones/01/05` 的風險登記，附徵兆與處理 |
| 對權威文件的回饋 | 記入 `plan/01/05` 的回饋清單，由產品裁決 |
| `draft` skill 的核對結果 | `ditto-qml-shell` 依 G0 的實際做法核對第 4 步，提出轉 `stable` 或維持 `draft` 的判定 |

**不接受的攜帶方式**：把未解決的事寫成「已完成但有小問題」、把門檻改寫成當前狀態、或把某項能力從範圍中靜默移除。
