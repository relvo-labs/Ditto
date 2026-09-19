---
name: ditto-verification-evidence
description: >-
  Establish the evidence required before claiming a Ditto requirement is done,
  and run measurements the way the acceptance matrix demands. Use when saying a
  requirement or acceptance scenario passes, writing tests for one, running
  memory, latency, or frame-time measurements, preparing a phase exit review, or
  handling a target that was not met.
metadata:
  type: skill
  category: quality
  status: stable
  language: zh-Hant
  related:
    - ditto-changeset-transaction
    - ditto-process-budget
    - ditto-prose-standard
    - ditto-decision-record
---

# Ditto 驗收證據

> 任何「完成」宣稱所需的證據，以及量測怎麼跑、報告怎麼寫。

## Overview

Ditto 的驗收有兩條不能讓步的規則：**功能測試必須檢查實際狀態，不能只檢查 Agent 說了什麼**；**未達標時提出數據與調整提案，不得靜默改變程序範圍或調高門檻**。

這兩條之所以要寫成 skill，是因為違反它們的當下都很合理：測試通過了、數字差一點點、把某個程序移出統計範圍就達標了。等到發布前才發現指標其實從未成立，已經沒有時間。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §19 非功能需求與量測基線／§19.1 記憶體預算與驗證方法](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §21 驗收情境與需求追溯](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/04 驗收矩陣、量測方法與測試基礎設施](../../../milestones/01/04-verification.md)

對應需求：NFR-06、NFR-07、NFR-12、NFR-15、AT-19、AT-25、CON-07

## When to Use

用於：宣稱某項需求或驗收情境通過；為某項需求寫測試；跑記憶體、延遲或幀時量測；準備階段出口評審；處理未達標的指標。

不適用：

- 單次操作的成功／失敗／部分完成怎麼判 → `ditto-changeset-transaction`。
- 預算本身怎麼定、程序該不該開 → `ditto-process-budget`。
- 決策落定的紀錄格式 → `ditto-decision-record`。
- 報告的措辭與誠實語氣 → `ditto-prose-standard`。

## Workflow

### 1. 先查對應

打開 `milestones/01/04`，找出這項工作對應的 AT 情境與 NFR 指標。**沒有對應項的「完成」不是完成**——若確實找不到，那是矩陣缺漏，記入 `ditto-decision-record` 的回饋而不是跳過。

### 2. 檢查證據種類是否正確

| 宣稱 | 不接受 | 接受 |
| --- | --- | --- |
| 某項對話任務成功 | Agent 回覆「已完成」 | 回讀桌面實際狀態並與目標比對 |
| 插件替換成功 | 新供應者已載入 | 舊註冊已清除、無重複快捷鍵、視窗存活 |
| 回復成功 | 回復函式已呼叫 | 狀態回到基底 revision，不可回復項已逐項列出 |
| 資源達標 | 單次採樣 | 依第 3 步的完整流程，3 次重複的 p95 |
| 清理無殘留 | 沒看到錯誤 | 100 次啟停後註冊表快照比對 ＋PSS 中位數增幅 ≤10% 且非單調成長 |

### 3. 跑量測

固定流程，缺一項就不是有效量測：

1. 冷登入 → 暖機 5 分鐘 → 採樣 10 分鐘。
2. 報穩態中位數、p95 與峰值；**穩態門檻以 p95 判定**。
3. 至少重複 3 次。
4. 固定變因：桌面元件、背景、角色素材、插件資料集、索引、對話長度。
5. 記錄版本、OS 與硬體、PID 與 cgroup 對應。
6. PSS 取自 `/proc/<pid>/smaps_rollup`；**不得與 RSS 相加**。
7. 模型延遲與本機套用延遲**分開記錄**；模型首字、規劃、工具、下載、建置耗時分開呈現。

效能與動畫指標必須在實體參考機量測，虛擬機只能跑非圖形測試。

### 4. 寫報告

報告必須分列四種狀態，不得混為一談：

- 無 Node 救援模式
- 完整桌面（Cordis 常駐、Agent 已退出）
- Agent 暖態
- 活動工作中

另附**完整程序清單**與**排除清單**。排除清單可以包含使用者自己開的瀏覽器與編輯器、既有 OS 服務、本機模型權重；**不得**包含 Ditto 新增的任何背景服務。以救援模式的數字代表完整桌面成本，是本專案明確禁止的報告方式。

### 5. 語意任務集的額外規則

- 固定測試集 ＋**不同措辭的保留集**，兩者分開計分。
- 記錄模型版本與任務集版本。
- 保留集分數明顯低於固定集時視為過擬合，**不計入達標**。
- 不得靠硬編碼同句通過——同一意圖換句話說仍須成立。

### 6. 未達標的處理

只有一條路：

1. 記錄實際數據與量測條件。
2. 分析原因（是實作問題、量測方法問題，還是目標本身不合理）。
3. 提出調整提案，附數據。
4. 交由決策程序核定，並依 `ditto-decision-record` 留下紀錄。

**不得做的三件事**：把某個程序移出統計範圍；改變暖機或採樣條件直到數字好看；直接把門檻改成目前的數字然後標記通過。

### 7. 階段出口評審

每個階段結束時逐項記錄於 `milestones/01`：

1. 出口門檻逐項結果（通過／未通過／條件通過＋條件）。
2. 量測數字與量測條件。
3. 未達標項目的數據與調整提案。
4. 新風險與新決策，回寫 `milestones/01/05`。
5. 下一階段的估算修正。

### 8. 驗證

- 每項門檻結果附量測條件與原始資料位置，不得只寫「通過」。
- 失敗必須有可追溯結果（`session_id`／`change_id`／`operation_id`），不得以「偶發」結案。
- 測試斷言檢查的是狀態查詢結果，不是日誌字串或回覆文字。

## Calibrated Examples

**「50 項任務集跑出 92%，可以說 NFR-12 達標嗎？」** → 先看保留集。固定集 92%、保留集 74% → **不達標**，是過擬合。固定集 92%、保留集 89% → 可宣稱達標，但報告須同時列出兩個數字與模型版本。

**「待機 PSS 量到 612 MiB，目標是 600。」** → 差 2% 不是「大致達標」。正確處理是記錄數據、找出超出的來源（哪個程序、什麼時候長上去的）、提出提案：要嘛改實作，要嘛附數據申請調整門檻。**不接受**的處理是把合成器移出統計範圍——合成器在這個範圍內是刻意的。

**「AT-04 的自動化測試通過了。」** → 看它斷言什麼。若只斷言「新 Dock 供應者已載入」，不算通過：AT-04 同時要求舊註冊已清除、無重複快捷鍵、原生視窗存活。三者缺一，這項情境仍是未通過。

**「這個 bug 只出現過一次，重跑就好了。」** → 不接受。失敗必須有可追溯結果。若日誌沒有串聯欄位可以定位，那本身是 REC-06 的缺口，應該先補上，而不是把這次失敗歸為偶發。

**「量測機器換了，數字比上次好很多。」** → 兩次量測不可比。參考機是固定變因之一；換機器後的數字只能與同機器的後續量測比較，且必須在報告中標示硬體變更。

**「這項需求 PRD 沒有對應的 AT，但功能做完了。」** → 這是矩陣缺漏，不是驗收豁免。記入回饋清單，補上對應情境或說明為何不需要，再談完成。

## Related Skills

- `ditto-changeset-transaction` — 本 skill 對其「完成」宣稱設下證據門檻（reviews 它）。
- `ditto-process-budget` — 預算定義的來源，本 skill 負責量測與報告（consumes 它）。
- `ditto-decision-record` — 未達標的調整與階段出口結果需留下決策紀錄（complements）。
- `ditto-prose-standard` — 報告與對外說明的誠實語氣（complements）。
