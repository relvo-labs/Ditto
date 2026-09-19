# G0 執行計畫（plan/02）

| 文件屬性 | 內容 |
| --- | --- |
| 文件編號 | DITTO-PLAN-002 |
| 版本 | 1.0.0 |
| 日期 | 2026-09-19 |
| 狀態 | 待評審；工期為建議值，增補項與加嚴項須經決策程序核定 |
| 上位文件 | [milestones/01](../../milestones/01/README.md)（實作順序權威）、[PRD v0.4.0](../../docs/product/Ditto-PRD-v0.4.0.md)（需求權威） |
| 範圍 | 僅 G0。G1～G5 不在本計畫內 |

本目錄把 [milestones/01/03 的 G0 階段](../../milestones/01/03-phases.md#g0原生可行性)從 17 行工作分解，細化成可以直接開工的執行計畫：每個工作包做什麼、做完怎麼證明、卡住退到哪裡、哪一天必須做出決策。

## 這份計畫的定位

**權威順序：PRD > `milestones/01` > 本計畫。** 本計畫不新增需求、不改變階段邊界、不重述已有內容；它只回答「G0 這 6–8 週要怎麼執行」。

與 `milestones/01` 不一致的地方只有三種，全部逐條登記於下方 [§4](#4-對-milestones01-的增補與加嚴登記)：

| 種類 | 允許嗎 | 處理 |
| --- | --- | --- |
| **增補**（新增工作項） | 允許 | 登記理由與人週成本，納入估算修正提案 |
| **加嚴**（把門檻寫得更嚴、更可判定） | 允許 | 登記原門檻與加嚴後判準 |
| **放寬**（降低門檻、縮小範圍） | **不允許** | 走 `ditto-decision-record`，附數據提案，不得在本計畫內自行裁決 |

## 1. 現況盤點

開工前這個倉庫實際擁有的東西：

| 資產 | 狀態 | 對 G0 的意義 |
| --- | --- | --- |
| PRD v0.4.0 | 完整，116 項需求、32 組驗收情境 | 需求來源；G0 只觸及其中的 DES-01～04／07～09、AVA-01～05、NFR-05／06／09／15、SEC-11 |
| `milestones/01` | 完整，G0～G5 分階段 | 本計畫的上位文件 |
| `.agents/skills` ×15 | 4 項 `draft`（對應子系統未落地） | 每個工作包開工前要讀的判斷程序；G0 會讓 `ditto-qml-shell` 具備轉 `stable` 的條件 |
| `apps/desktop-prototype/` | 凍結 | 互動契約與角色素材來源；**零行程式碼沿用** |
| `deepseek-harness`（本機 `../deepseek-harness`） | 可讀 | G0 只取用兩樣：`packages/sdk/protocol` 的換行分幀 JSON-RPC 形狀、`native/system` 的 Landlock 事實。**G0 不引入 Cordis** |
| 實作程式碼 | **不存在** | `crates/`、`shell/`、`packages/`、`schema/`、`tools/` 都由 G0 首次建立 |

推論：G0 的第一週不是寫程式，是**取得參考硬體與凍結平台**——後面每一項量測的有效性都建立在那上面（[04-verification §4](../../milestones/01/04-verification.md) 要求效能與動畫必須在實體參考機量測）。

## 2. G0 的一句話目標

**在一台凍結的機器上，證明 Quickshell＋Rust＋Wayland 能真的管理原生 Linux 應用，量到第一組誠實的資源數字，並把後續四個階段依賴的技術基線釘死。**

成立條件有三個，缺一不可：原生應用真的可控、合成器缺口有書面結論與決策、量測工具產出的數字符合 19.1 的報告規則。

## 3. 文件導讀

| 文件 | 內容 | 誰要讀 |
| --- | --- | --- |
| [01-scope-and-exit-criteria.md](01-scope-and-exit-criteria.md) | G0 範圍界線、**九項可判定的出口門檻**、G0 能主張與不能主張什麼 | 全體，開工前 |
| [02-platform-and-compositor.md](02-platform-and-compositor.md) | 參考平台與工具鏈凍結、合成器探針套件、能力差異表、**D-02 的預先承諾判準** | PLAT |
| [03-core-and-contracts.md](03-core-and-contracts.md) | 倉庫骨架、契約型別管線、G0 能力目錄與描述子、IPC 協定細節、身分綁定、合成器轉接 | CORE |
| [04-shell-and-avatar.md](04-shell-and-avatar.md) | Quickshell 工作階段、角色層與命中區、狀態訂閱、熱路徑的機械化驗證 | SHELL |
| [05-measurement-and-verification.md](05-measurement-and-verification.md) | 量測工具規格與報告格式、驗證腳本、配額基線、CI 分層 | QA |
| [06-workplan.md](06-workplan.md) | 19 個工作包的逐包執行細節、週序、關鍵路徑、人力與估算 | 全體 |
| [07-decisions-and-risks.md](07-decisions-and-risks.md) | G0 既有的 9 項決策或管理確認、另提 4 項待決策提案，以及 G0 專屬風險與備案 | 產品、管理 |
| [08-exit-review-and-handoff.md](08-exit-review-and-handoff.md) | 出口評審程序與範本、交付物清單、G1 開工前置條件 | 全體，收尾 |

建議閱讀順序：`01`（要做到什麼）→ `06`（誰在哪一週做什麼）→ 各工作流的 `02`／`03`／`04`／`05` → `07`（什麼時候要決定）→ `08`（怎麼結案）。

## 4. 對 milestones/01 的增補與加嚴登記

### 4.1 增補的工作項（＋3 人週）

| ID | 工作項 | 為什麼 milestones/01 沒有它不行 | 人週 |
| --- | --- | --- | --- |
| G0-PLAT-05 | 真機 runner 建置與 nightly 工作流 | `milestones/01/04 §4` 要求效能與動畫必須在實體參考機量測，`05` 把它列為 R-19／D-19，但 `03` 的 G0 工作分解沒有對應工作項。沒有 runner，出口門檻第 4、5 項的數字不具效力 | 1 |
| G0-CORE-06 | `dittoctl probe` 診斷 CLI | `ditto-capability-contract` 要求每項能力都有 Consumer。G0 若只有 QML 一個消費者，IPC 無法在無圖形環境下測試，契約測試也進不了 PR 快檢 | 1 |
| G0-QA-04 | 幀時與熱路徑驗證腳本 | G0-SHELL-04 只說「驗證逐幀更新不經 IPC」。要讓它在 CI 上可重複，需要取樣器與 RPC 計數器兩件產出，且與 SHELL 的實作分屬不同工作流 | 1 |

`dittoctl probe` **不是救援 CLI**。救援模式（REC-03、AT-23）是 G1-PLAT-03／04 的交付物；G0 交付的只是同一個執行檔骨架下的診斷子命令，文件與 PR 描述都不得宣稱救援能力已開始。

### 4.2 加嚴的門檻（＋2 人週，計入 CORE）

| 原門檻（milestones/01） | 加嚴後 | 成本落在 |
| --- | --- | --- |
| 「契約型別產生管線在 CI 上驗證通過」 | 另加**能力目錄一致性 gate**：目錄中每項能力都必須有已註冊 handler、至少一個標記過的 Consumer，且無 `readback` 者不得標記為可宣稱成功 | G0-CORE-02 |
| G0-CORE-04「身分綁定原型」 | 升為出口門檻 EX-07，並要求負例測試（偽造 `plugin_id`、未經啟動器的連線）實際通過 | G0-CORE-04 |
| 「不支援的操作明確回傳 `unsupported`」 | 加上**回讀比對**：宣稱成功的操作必須以 `readback` 驗證真實狀態，「回成功但沒動」與回傳 `unsupported` 同列為不通過 | G0-CORE-05 |

加嚴不需要新的決策核定，但估算修正需要——見 [06 §5](06-workplan.md#5-估算與差異說明)。

### 4.3 估算

| | milestones/01 | 本計畫 | 差 |
| --- | --- | --- | --- |
| PLAT | 6 | 8 | ＋2（PLAT-05 ＋1，合成器探針套件 ＋1） |
| CORE | 8 | 10 | ＋2（CORE-06 ＋1，兩項加嚴 ＋1） |
| SHELL | 8 | 8 | — |
| QA | 4 | 5 | ＋1（QA-04） |
| **合計** | **26** | **31** | **＋5** |

曆時仍為 6–8 週（並行度見 [06 §3](06-workplan.md#3-關鍵路徑與並行)）。本表是**提案**，依 `ditto-decision-record` 於 G0 啟動評審時核定，核定結果回寫 `milestones/01/05 §3.3`。

## 5. 開工前的 skill 對應

每個工作包的第一步都是讀對應 skill，不是打開編輯器：

| 工作包群 | 必讀 | 併讀 |
| --- | --- | --- |
| G0-PLAT-01～05 | `ditto-verification-evidence` | `ditto-decision-record` |
| G0-CORE-01～03、06 | `ditto-capability-contract` | `ditto-authority-boundaries` |
| G0-CORE-04 | `ditto-permission-and-secrets` | `ditto-authority-boundaries` |
| G0-CORE-05 | `ditto-capability-contract` | `ditto-failure-and-rescue` |
| G0-SHELL-01～04 | `ditto-qml-shell` | `ditto-process-budget` |
| G0-QA-01～04 | `ditto-verification-evidence` | `ditto-process-budget` |
| 任何文件與 PR 描述 | `ditto-prose-standard` | — |
| 取用 harness／Cordis 任何一行 | `ditto-upstream-port` | — |

## 6. 維護規則

1. 工作包狀態只在 [06-workplan.md](06-workplan.md) 更新，不散落在各文件。
2. 量測數字只寫進出口評審紀錄（`.agents/notes/gate-reviews/G0-exit.md`）與 `milestones/01/04`，本計畫不保存第二份數字。
3. 決策落定時寫 `.agents/notes/decisions/`，並回寫 `milestones/01/05` 的對應列；只做其中一邊不算完成。
4. 本計畫的任何門檻都不得因為做不到而改寫。做不到的正確處理是附數據提案，見 [07 §4](07-decisions-and-risks.md#4-決策程序)。
