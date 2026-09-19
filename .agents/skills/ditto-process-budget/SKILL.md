---
name: ditto-process-budget
description: >-
  Decide whether Ditto work needs a new process, a resident service, polling, or
  a place on the frame-rate hot path, and account for its memory honestly. Use
  when adding a plugin, service, worker, or background job, choosing between
  events and polling, moving work off the UI thread, adding animation or drag
  interaction, or reporting per-process memory and CPU.
metadata:
  type: skill
  category: architecture
  status: stable
  language: zh-Hant
  related:
    - ditto-authority-boundaries
    - ditto-verification-evidence
    - ditto-qml-shell
---

# Ditto 程序與資源預算

> 程序數、常駐決策、熱路徑與資源計費。

## Overview

Ditto 的資源目標不是事後優化的項目，而是設計約束：全桌面在 Agent 退出時 ≤600 MiB、Agent 暖態 ≤750 MiB，且**預設 Profile 不得為每個 UI 插件建立 Node 程序或 Worker**。一個桌面若每加一個面板就多一個程序，這些數字在十個插件之內就會破掉，而那時要改的是插件模型本身。

同樣是設計約束的還有熱路徑：拖曳、動畫與角色眨眼留在 QML 與合成器，不得逐幀經過 Node、LLM 或 Rust RPC。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §15.3 程序邊界／§15.4 宿主與 Agent 生命週期](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §19.1 記憶體預算與驗證方法](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §6 效能與資源的架構性約束](../../../milestones/01/01-architecture.md)

對應需求：RUN-02、RUN-03、RUN-05、RUN-07、RUN-08、NFR-05、NFR-06、NFR-13、NFR-14、NFR-15

## When to Use

用於：新增插件、服務、worker 或背景工作；在事件與輪詢之間選擇；把工作移出 UI 執行緒；加入動畫或拖曳互動；回報逐程序的記憶體與 CPU。

不適用：

- 這份狀態歸誰所有 → `ditto-authority-boundaries`。
- 量測怎麼跑、報告怎麼寫、未達標怎麼辦 → `ditto-verification-evidence`。
- QML 元件本身怎麼寫 → `ditto-qml-shell`。

## Workflow

### 1. 要不要開新程序

依序問，第一個「是」就停：

1. **它需要獨立的 OS 隔離邊界嗎？**（未信任程式碼、生成候選、外部工具）→ 獨立程序 ＋cgroup ＋沙箱。
2. **它是 Agent 嗎？** → 按需 Agent 程序，最多一個活動實例。
3. **它是重型且可能長時間佔用 CPU 嗎？**（建置、索引、解析大檔）→ 送進工作池，**不是新常駐程序**。預設最多 2 個重型工作並行，超出排隊。
4. 以上皆否 → **放進既有宿主**。可信 TS 服務進 Cordis 桌面宿主；UI 進 Quickshell；權威狀態進 Core。

**「這個插件比較重要所以給它自己的程序」不是理由。** 程序數是預算，不是設計自由度。

### 2. 要不要常駐

| 對象 | 常駐條件 | 回收條件 |
| --- | --- | --- |
| Cordis 桌面宿主 | Profile 需要其中任一服務 | **只有**在無啟用服務、無訂閱、無排程、無有效租約後才可回收 |
| 按需 Agent | 有活動任務、待確認、建置或未移交的長任務 | 上述皆無時，閒置 5 分鐘落盤退出，10 秒內釋放資源 |
| 重型工具 | 工作進行中 | 工作結束即終止 |

兩條容易搞混的規則：

- **Agent 的閒置退出規則不適用於 Cordis 宿主。** 宿主有活動服務時必須繼續運作，即使 Agent 已經退出。
- **關閉對話面板不是取消任務。** UI 可見性與任務存活無關。

### 3. 事件還是輪詢

預設訂閱事件。只有在來源沒有事件 API 時才輪詢，且必須：

- 有界（明確的間隔與上限，不是 `setInterval` 放著跑），
- **在程式碼註解或 PR 描述中記錄為何只能輪詢**，
- 元件隱藏時停止。

隱藏的元件停止非必要渲染與輪詢，這條同時影響 NFR-05 與 NFR-06。

### 4. 這條路徑在熱路徑上嗎

熱路徑＝每幀或接近每幀執行的路徑：拖曳中的視窗位置、動畫插值、角色眨眼與注視、捲動。

熱路徑上**不得出現**：跨程序 RPC、Node 回呼、模型呼叫、資料庫寫入。

正確做法是分層：語意狀態與有界增量經 RPC 發布，逐幀插值留在 QML。使用者拖曳時關閉位置過渡動畫，讓元件直接跟隨指標。

### 5. 誠實計費

- 以 PSS 計費（來源 `/proc/<pid>/smaps_rollup`）。**PSS 已按共享頁面分攤，不得再與 RSS 相加。**
- 同程序插件**不得**把堆積估算冒充為精確的獨立 RSS。同程序就是同程序，回報時說清楚它與宿主共用。
- Node 側另報 `heapUsed`、`external`、`arrayBuffers`，且**不得把三者相加當作程序記憶體**。
- 報告必須附完整程序清單與排除清單；Ditto 新增的背景服務不得被移進排除清單。

### 6. 驗證

- 啟動預設 Profile 並列出程序清單：確認插件數量增加時程序數不變。
- 對新增的服務做 A/B：加入前後的穩態 PSS 差異，10 個簡單插件的合計增量目標 ≤50 MiB。
- 幀時取樣：指定操作期間至少 95% 的幀 ≤16.7 ms。
- 隱藏元件後確認輪詢與渲染確實停止。
- 詳細量測流程見 `ditto-verification-evidence`。

## Calibrated Examples

**新增一個天氣元件** → 不開程序。它是宣告式面板加一個資料服務；資料服務進 Cordis 宿主，與其他服務共用。若它需要定時更新，用宿主的排程服務，不是自己的 `setInterval` 常駐。

**索引使用者的十萬個檔案** → 重型工作池，受並行上限與取消控制。**不是**常駐索引程序，也**不是**在 Core 裡同步跑（會阻塞權威狀態服務）。索引結果是可重建的快取，歸產生它的服務所有。

**角色要跟隨游標移動** → 完全在 QML 內。指標事件到位置更新不經任何 IPC。若「跟隨」需要全域游標位置（超出角色互動區），那是合成器能力問題，不是靠提高 RPC 頻率解決——合成器不支援就限定在互動區內，並如實說明。

**插件想每秒查詢一次視窗列表** → 先找事件。視窗狀態有事件來源，訂閱它。若某項狀態確實只有輪詢可取得，設定有界間隔、記錄理由、隱藏時停止，並在插件中心顯示這項活動，讓資源成本可見。

**Agent 完成任務後，使用者關閉對話面板** → Agent 不因面板關閉而終止，也不因此永久常駐。它依「無活動任務」進入閒置計時，5 分鐘後落盤退出。若此時仍有 Cordis 服務在跑（例如通知策略服務），宿主**不受影響**。

**「先常駐著，之後再優化」** → 反例。冷啟動達不到 2 秒的正確處理是量測、按需載入依賴、UI 先顯示啟動狀態；**不是**用永久常駐掩蓋。掩蓋會讓 NFR-13 永遠無法被誠實量測，而待機資源預算同時被吃掉。

## Related Skills

- `ditto-authority-boundaries` — 上游總則：先確定這份工作與狀態歸誰（specializes 它）。
- `ditto-verification-evidence` — 量測流程、報告格式與未達標的處理（consumes 本 skill 的預算定義）。
- `ditto-qml-shell` — 熱路徑禁令與隱藏時停止渲染由兩者共同落實（complements）。
