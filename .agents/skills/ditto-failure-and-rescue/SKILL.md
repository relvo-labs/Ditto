---
name: ditto-failure-and-rescue
description: >-
  Design and review Ditto failure paths: supervision, restart storms, the
  no-Node rescue mode, partial-completion reporting, correlated logs, and
  recovery after a crash or a full disk. Use when adding supervision or health
  checks, handling a timeout or a dead process, writing rescue CLI behaviour,
  deciding what stays available when a host dies, or reviewing what happens
  after an interrupted commit.
metadata:
  type: skill
  category: runtime
  status: draft
  language: zh-Hant
  related:
    - ditto-changeset-transaction
---

# Ditto 故障與救援

> 故障路徑、監督、救援模式與可觀測性。

> **status: draft** — 監督範圍與 `dittoctl` 的實際能力界線在 G1-PLAT-03／04 才確定，屆時須回頭核對第 3 步的能力表並改為 stable。

## Overview

Ditto 的正常路徑有交易保護，但使用者遇到的最壞情況不在正常路徑上：Shell 沒反應、宿主崩潰、提交到一半斷電、磁碟寫滿。這些時刻的承諾很具體——**原生應用不能被連帶終止，最近可用的組合不能被破壞，而且一定要有一條不依賴角色、聊天與主 Shell 的操作入口**。

最容易被忽略的是最後一項。救援若建立在「Shell 還活著」或「Node 還在跑」的假設上，它就只能救那些本來也不太嚴重的故障。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §18 故障恢復與可觀測性](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §15.4 宿主與 Agent 生命週期](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/03 G1-PLAT-03／04 救援交付項](../../../milestones/01/03-phases.md)

對應需求：REC-01、REC-02、REC-03、REC-04、REC-05、REC-06、REC-07、RUN-01、RUN-06、RUN-12、CFG-07、NFR-08、NFR-09

## When to Use

用於：新增監督或健康檢查；處理逾時、無回應或程序死亡；撰寫救援 CLI 行為；決定某個宿主死掉時還剩什麼可用；審查提交中斷後的恢復。

不適用：

- 正常路徑的準備、套用與回復步驟 → `ditto-changeset-transaction`。
- 這次故障的結果怎麼寫給使用者看 → `ditto-prose-standard`。
- 資源超限導致的終止策略 → `ditto-process-budget` 與 `ditto-generation-safety`。

## Workflow

### 1. 先讀權威

打開 PRD §18 與 `milestones/01/03` 的 G1-PLAT-03／04。本節只給設計判準。

### 2. 分清楚三種「壞掉」

| 種類 | 徵兆 | 責任方 |
| --- | --- | --- |
| 操作失敗 | 單次呼叫回錯誤或回讀不一致 | 變更層回復，見 `ditto-changeset-transaction` |
| 元件故障 | 程序退出、無回應、重啟風暴 | 監督：隔離、停用、重建 |
| 系統性故障 | Core 掛掉、磁碟寫滿、資料庫寫入失敗 | 救援：保住可用版本與基本操作 |

把元件故障當成操作失敗處理（例如一直重試那個呼叫），會把單點問題變成重啟風暴。

### 3. 決定故障時還剩什麼

每次新增元件都要回答：**它死掉時，哪些能力必須仍然成立？**

| 死掉的元件 | 必須仍然成立 |
| --- | --- |
| Agent | 手動桌面完整可用；已受理的變更由 Core 完成或回復；Cordis 服務不受影響 |
| Cordis 桌面宿主 | 合成器與原生應用持續運作；該宿主的能力**即時標示不可用**；進行中的變更停止或補償；救援可用 |
| Quickshell Shell | 原生應用零非預期終止、未儲存內容保留；**10 秒內**提供可操作介面 |
| Core | 停止新變更；保留合成器、既有應用與本地可用的基本操作；監督啟動救援 |
| Node 完全不可用 | 原生應用基本操作、讀取歷史、切回最近可用配置。依賴 Cordis 的功能**明確標示暫不可用**，不是靜默消失 |

最後一列是 RUN-01 的界線：無 Node 救援模式**只保證這三件事**。不要在文件或 UI 上暗示它等同完整桌面，也不要為了讓它看起來更完整而把 Node 依賴偷偷帶進救援路徑。

### 4. 監督的判準

- 監督必須**獨立於被監督者**：不依賴 Shell、不依賴 Node、不隨一般插件更新被替換。
- 偵測三件事：退出、無回應、重啟風暴。
- **連續失敗後停用故障插件**，而不是無限重啟。停用要留下可查的原因與恢復入口。
- 重啟有退避；沒有退避的自動重啟是把故障放大的最快方式。

### 5. 崩潰後的恢復

重啟後**比對持久操作紀錄與實際狀態**，處理未完成的提交：

1. 找出狀態停在 `applying` 或 `verifying` 的 operation。
2. 以回讀判斷它實際上做到哪裡，**不要依賴當時的記憶體狀態或樂觀假設**。
3. 依判斷結果完成或回復，並產生明確結果。
4. 若無法判斷 → 結果未知，如實回報，不重試有副作用的操作。

受保護的最近可用組合在任何情況下都不得被覆寫。磁碟不足、套件下載失敗、資料庫寫入失敗都必須在**破壞它之前**失敗。

保留策略同樣是恢復能力的一部分：至少保留最近 20 個配置修訂與一份受保護的最近可用版本；清理時先保護被引用的套件（CFG-07）。

### 6. 日誌與診斷

- 以 `session_id`、`change_id`、`operation_id` 串聯，任何失敗都要能從結果回溯到日誌。
- **預設遮蔽敏感內容**：視窗標題、文件內容、剪貼簿、對話、秘密。遙測預設不傳送這些，且需要範圍可見的選擇加入。
- 診斷要能顯示依賴鏈、供應者、版本、活躍註冊、最後健康檢查與回復結果——這是插件中心排查的最小集合。

### 7. 驗證

故障注入是唯一有效的驗證方式：

- 在 `prepared`、`applying`、`verifying` 各終止一次程序，確認可定位未完成變更且最近可用版本完好。
- 終止 Cordis 宿主（含準備階段與交接階段各一次），確認能力即時不可用、變更有明確結果、恢復後不重播副作用。
- 停止 Node 全部程序，確認救援模式的三項能力成立，且不可用的功能有標示。
- 讓 Shell 無回應，量測到可操作介面的時間（NFR-08：10 秒內）。
- 填滿磁碟後執行一次變更，確認最近可用版本未被破壞。

對應 `milestones/01/04` 的 AT-16、AT-20、AT-23、AT-28、AT-32。

## Calibrated Examples

**Cordis 宿主在交接階段崩潰** → 能力**立即**標示不可用（不是等租約逾期），進行中的變更走補償或回復並產生明確結果。宿主重啟後重建依賴與代理，但**不重播已完成的外部副作用**。合成器與救援全程不受影響。

**插件連續崩潰五次** → 停用它，不要繼續重啟。停用必須留下原因、最後一次診斷與重新啟用的入口。「一直重啟希望它自己好」會吃掉 CPU 預算並把日誌淹掉，讓真正的原因更難找。

**提交途中拔電，重開機後** → 掃描持久操作紀錄，找出停在 `applying` 的 operation，**用回讀決定它實際做到哪裡**。不要假設「應該沒寫成功」而直接回復，也不要假設「應該成功了」而直接提交。

**磁碟寫滿，配置寫入失敗** → 失敗必須發生在受保護的最近可用版本被覆寫**之前**。先寫新版本再切換指標；不要原地覆寫。使用者看到的是「空間不足，設定未變更」，不是一個半寫入的配置。

**「救援模式也能改主題」** → 反例，而且是危險的那種。為了讓救援看起來更有用而擴充它的能力，會把依賴帶回救援路徑，於是救援在真正需要時也一起壞掉。救援的能力清單是刻意最小的，要改就走決策程序，見 `ditto-decision-record`。

**Agent 在變更受理後崩潰** → 已受理的變更由 Core 協調完成或回復，與 Agent 存活無關。使用者重新開啟對話時，看到的是該變更的**真實結果**，不是「上次沒說完的話」。未受理的則不執行。

## Related Skills

- `ditto-changeset-transaction` — 失敗路徑是交易的另一半：正常路徑的回復在那裡，元件與系統性故障在這裡（complements）。
