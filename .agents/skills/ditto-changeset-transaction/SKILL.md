---
name: ditto-changeset-transaction
description: >-
  Apply the Ditto ChangeSet transaction model to any operation that changes
  desktop state: preflight, prepare, apply by hot-swap level, read back, then
  commit or roll back. Use when implementing or reviewing configuration changes,
  plugin replacement, profile switching, undo, cancellation, concurrent edits,
  or deciding whether an outcome is success, partial, failure, or unknown.
metadata:
  type: skill
  category: runtime
  status: stable
  language: zh-Hant
  related:
    - ditto-capability-contract
    - ditto-verification-evidence
    - ditto-cordis-plugin
    - ditto-failure-and-rescue
    - ditto-agent-changeset
---

# Ditto 變更交易

> 任何會改變桌面狀態的操作的交易流程：預檢、準備、套用、回讀、提交或回復。

## Overview

Ditto 對使用者的承諾是「改造過程保留現有工作，失敗有明確結果與回復入口」。那個承諾由一條固定流程兌現：模型與 GUI 都不直接改狀態，而是產生 ChangeSet，經確定性驗證、準備候選、依熱換等級套用、**讀回真實結果**，才提交或回復。

最常見的實作錯誤是跳過回讀：呼叫成功就回報完成。這在插件替換與合成器操作上幾乎必然出錯，而且錯得無聲。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §14 變更交易、熱換與回復](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §8 三條桌面改造路徑](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §3 變更交易模型](../../../milestones/01/01-architecture.md)

對應需求：CHG-01、CHG-02、CHG-03、CHG-04、CHG-05、CHG-06、CHG-07、CHG-08、CHG-09、CFG-02、CFG-05、CFG-06、MOD-02、CON-06、CON-07

## When to Use

用於：實作任何寫入配置或改變桌面外觀／行為的路徑；插件安裝、啟用、替換、回退；Profile 切換與撤銷；取消處理；併發修改；判定一次操作的結果類別。

不適用：

- 這項能力的 schema、錯誤集與 `readback` 怎麼定 → `ditto-capability-contract`。
- 崩潰後的救援與監督 → `ditto-failure-and-rescue`。
- 這次結果能不能宣稱「需求已完成」 → `ditto-verification-evidence`。

## Workflow

### 1. 先讀權威

打開 `milestones/01/01 §3`，確認狀態機與七條規則的當前版本。本節只給每個轉換的前置條件與判準。

### 2. 走完狀態機，不得抄捷徑

```
draft → validated → prepared → applying → verifying → committed
                        ↓          ↓           ↓
                     aborted   rolling_back → rolled_back | partially_applied
```

| 轉換 | 前置條件（全部成立才可進入） |
| --- | --- |
| → `validated` | schema、依賴、衝突、循環、單一供應者、版本相容、權限、基底 revision 全部確定性檢查通過。**此階段不呼叫模型** |
| → `prepared` | 已保存配置與必要狀態快照；候選已健康檢查；候選**尚未取得正式獨占資源**（快捷鍵、命令、單一供應者能力） |
| → `applying` | 已選定熱換等級（第 3 步）；同一配置的提交已序列化 |
| → `verifying` | 套用步驟已回報；準備讀回 |
| → `committed` | 每項變更都經 `readback` 讀回且與目標一致；產生不可變 revision，並記錄由哪段對話或哪次 GUI 操作造成（CFG-02） |
| → `rolling_back` | 回讀不一致，或任一必要步驟失敗 |

跳過 `prepared` 直接套用，是無法回復的主因：沒有快照就沒有回復計畫。

### 3. 選熱換等級

| 等級 | 何時選 | 必須做的事 |
| --- | --- | --- |
| 即時替換 | 無狀態供應者、一般面板、啟動器 | 失敗即切回舊供應者 |
| 受控交接 | 視窗策略、索引、長任務服務 | 舊供應者先停止收新工作 → 排空／取消／交接 → 才切換路由 |
| 宿主重啟 | 無法卸載的原生依賴 | 顯示受影響範圍；原生應用必須持續執行 |
| 工作階段重啟 | 合成器與關鍵登入元件 | 排程待套用，先提示保存工作，不得無預警執行 |

判準：**這次替換會不會讓進行中的工作失去歸屬？** 會 → 至少受控交接。不確定時選更高一級。

切換路由前確認舊供應者已停止註冊，否則會出現重複快捷鍵與重複命令——這是 AT-04 直接檢查的項目。

### 4. 回讀，然後才宣稱成功

套用後呼叫每項能力的 `readback` 並比對目標。回讀不一致 → 進 `rolling_back`，**不得因為「呼叫沒報錯」就提交**。

沒有 `readback` 的能力不能作為成功判準；若這次變更依賴這種能力，先回 `ditto-capability-contract` 補齊。

### 5. 判定結果類別

四選一，不得含糊：

| 類別 | 判準 |
| --- | --- |
| **成功** | 所有步驟回讀一致 |
| **失敗** | 任一必要步驟失敗，且回復完成，系統回到基底 revision |
| **部分完成** | 有已提交且不可回復的副作用，或回復本身部分失敗。**必須逐項列出哪些已生效、哪些未回復** |
| **結果未知** | 送出後失去回應，且以 `operation_id` 查詢不到紀錄 |

「結果未知」是合法且必要的類別。把它報成失敗會誘發重試，而重試有副作用的操作正是 CHG-07 禁止的。

### 6. 處理併發與中斷

- **基底 revision 過期**（使用者在準備期間手動改了同一項）→ 拒絕本次變更，要求重新規劃或詢問，**不得覆寫**。
- **取消** → 停止新增操作；已完成的副作用與可回復範圍**分開回報**。取消不等於沒發生過。
- **連線中斷** → 以 `operation_id` 查詢真實結果再決定；不得盲目重試。
- **顯示與主要輸入變更** → 套用後啟動限時回復倒數，使用者未確認可用即自動回復。

### 7. 驗證

- 故障注入：在 `prepared`、`applying`、`verifying` 三個階段各終止一次程序，確認重啟後能定位未完成變更且最近可用版本未被破壞。
- 併發測試：準備期間修改同一項配置，確認被拒而非覆寫。
- 清理測試：同一變更重複套用與回復 100 次，確認無殘留註冊。
- 對照 `milestones/01/04` 的 AT-09、AT-10、AT-11、AT-20 檢查項。

## Calibrated Examples

結果類別的刻度——這是最常判錯的地方。

**切換 Dock 供應者，新供應者啟動成功，舊供應者的清理逾時** → **部分完成**。新 Dock 可用，但舊註冊可能殘留。回報必須寫出「舊供應者未完成清理，可能出現重複快捷鍵」，並提供重試清理的入口。報成「成功」會讓使用者在下一次替換時遇到無法解釋的衝突。

**套用主題，能力回傳 ok，回讀顯示仍是舊主題** → **失敗**，且必須回復。呼叫成功不是成功。常見原因是 UI 快取或供應者未實際生效，這正是回讀要抓的情形。

**送出安裝命令後 socket 斷線，重連後以 `operation_id` 查不到紀錄** → **結果未知**。不得重試（可能已下載並寫入），不得報失敗（可能已成功）。正確行為是查詢實際狀態（套件是否存在、雜湊是否相符）後再決定，並在對話中如實說明目前不確定。

**使用者在 Agent 準備變更時，自己把 Dock 拖到左邊** → 基底 revision 過期。**不是衝突合併，是拒絕**。Agent 重新讀取目前狀態後再規劃；若原需求仍成立，產生新的 ChangeSet。靜默覆寫使用者剛做的調整是 CFG-06 直接禁止的行為。

**只是改一個布林設定，需要走完整個狀態機嗎？** 需要。狀態機的成本主要在 `prepared` 的快照，對宣告式配置而言很小。真正該避免的是相反的事：為了省事而讓某些路徑跳過驗證與回讀，於是系統裡出現兩種可靠性等級的變更，而使用者分不出來自己踩到哪一種。

**撤銷一個布局變更，但其中一個視窗已經被使用者關掉了** → **部分完成**。還原能還原的部分，明確說明哪一項因視窗不存在而未還原。不得重建不存在的應用狀態，也不得因此整筆放棄還原。

## Related Skills

- `ditto-capability-contract` — 交易依賴能力描述子的 `readback`、`idempotency` 與取消語意（consumes 它）。
- `ditto-verification-evidence` — 對「完成」宣稱設下證據門檻（reviews 本 skill 的產出）。
- `ditto-cordis-plugin` — 宿主內的插件生命週期與本 skill 的兩階段交易必須一併成立（complements）。
- `ditto-failure-and-rescue` — 元件與系統性故障的處理，是交易的另一半（complements）。
- `ditto-agent-changeset` — Agent 的產出交由本 skill 驗證與執行（consumes 本 skill）。
