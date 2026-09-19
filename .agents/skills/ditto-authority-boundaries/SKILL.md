---
name: ditto-authority-boundaries
description: >-
  Decide which Ditto layer owns a piece of state, a write path, or a decision,
  and check the cross-layer prohibitions before writing code. Use when adding
  persistent state, deciding where a setting or session is stored, wiring a
  Cordis desktop plugin to configuration, giving the Agent a new ability,
  introducing a cache or a second copy of data, or reviewing a change that
  touches more than one process.
metadata:
  type: skill
  category: architecture
  status: stable
  language: zh-Hant
  related:
    - ditto-capability-contract
    - ditto-process-budget
    - ditto-permission-and-secrets
---

# Ditto 所有權邊界

> 判定一項狀態、寫入路徑或決策歸誰所有，以及跨層禁則。

## Overview

Ditto 有五個可能持有狀態的地方：Rust Core、Cordis 桌面宿主、Quickshell UI、按需 Agent、合成器。多數難以回復的設計錯誤，都來自把狀態放錯層或開出第二條寫入路徑——例如讓插件自己寫設定檔、讓 Agent 直接改配置、把 Cordis 的 Context 當成跨程序物件傳遞。

這些錯誤在單一程序內看起來都能動，要到熱換、回復、Agent 退出或宿主崩潰時才會爆開，而那時結構已經長成。本 skill 在寫第一行之前把歸屬決定清楚。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §13 組合配置、版本與狀態](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §15.1／§15.5／§15.6 分層、語言中立契約與 Cordis 邊界](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §1 程序與所有權](../../../milestones/01/01-architecture.md)

對應需求：RUN-01、RUN-02、RUN-03、RUN-10、RUN-11、RUN-12、CFG-05、CFG-06、MOD-05、SEC-11

## When to Use

用於：新增任何會存活超過一次呼叫的狀態；決定設定、會話、快取、索引或暫態放哪裡；讓 Cordis 插件讀寫配置；擴充 Agent 的能力；審查跨程序的變更。

不適用：

- 該能力的 schema、錯誤集與版本怎麼定 → `ditto-capability-contract`。
- 這份狀態的更新怎麼交易式套用與回復 → `ditto-changeset-transaction`。
- 要不要為它開新程序、常駐或輪詢 → `ditto-process-budget`。

## Workflow

### 1. 先讀權威

打開上方 `## Authority` 的第三條（`milestones/01/01 §1.2 狀態所有權`）。那張表是裁決依據；本節只給判斷程序。

### 2. 分類這份狀態

依「失去它會怎樣」分類，不依它長得像什麼：

| 問題 | 是 | 否 |
| --- | --- | --- |
| 重新登入後必須還在？ | 往下問 | → **UI 暫態**，歸 Shell |
| 會出現在 Profile 匯出裡？ | → **配置**，歸 Core | 往下問 |
| 使用者刪掉它算刪資料？ | → **插件資料**，歸 Core 的資料區，插件移除時預設保留 | 往下問 |
| 是對話、工具結果或任務紀錄？ | → **會話**，歸 Core 的會話儲存 | 往下問 |
| 是合成器隨時可能改變的事實？ | → **觀測狀態**，不持久化，每次重新查詢 | → 回到第一列重新判斷，多半是遺漏的配置 |

### 3. 套用歸屬

| 歸屬 | 誰能寫 | 存哪裡 | 不得 |
| --- | --- | --- | --- |
| 配置（Profile、布局意圖、快捷鍵） | 只有 Core，經 ChangeSet | SQLite ＋可匯出文字 | 插件或 Agent 直接寫檔；宿主保存第二份 |
| 能力綁定與權限授予 | 只有 Core | SQLite | 以 manifest 自述取得身分或權限 |
| 插件資料 | 擁有該資料的插件，經 Core 的資料介面 | Core 管理的資料區 | 插件自行決定路徑；移除插件時一併刪資料 |
| 會話與任務結果 | Core 的會話儲存服務 | 檔案 ＋SQLite 索引 | 放在 Agent 程序記憶體或 Agent 自己的檔案 |
| 宿主內插件實例與依賴 | Cordis（fiber 生命週期） | 記憶體 | 持久化；由 Core 以外的來源決定條目列表 |
| UI 暫態（焦點、草稿、展開） | Shell | 記憶體，必要時 Core 的 UI 狀態表 | 進入 Profile 匯出 |
| 視窗、工作區、顯示器 | 合成器 | 不持久化 | 把視窗 ID 當作跨登入的永久身分 |
| 秘密 | 系統秘密儲存 | 外部 keyring | 任何形式的值進入 Profile、日誌或匯出 |

### 4. 檢查四條禁則

每條都問一次，答「是」就停下來重做：

1. **這個改動是否讓 Core 以外的東西成為配置的權威寫入者？** 包含：插件寫 YAML／JSON 設定檔、Agent 直接呼叫宿主 API 改組合、UI 把狀態存在自己的檔案再於啟動時回灌。
2. **這個改動是否讓 Cordis 宿主保存一份與 Core 競爭的正式配置？** 宿主可以有記憶體中的條目列表，但它必須是 Core 推送的投影，不是另一份可被獨立編輯的真相。
3. **這個改動是否讓 Agent 擁有桌面服務的存活決策？** Agent 可以請求啟動一項服務，但不能決定宿主何時回收；Agent 退出後，有活動服務的宿主必須繼續運作。
4. **這個改動是否跨程序傳遞了非資料的東西？** Context、函式、類別實例、閉包都不得跨程序。跨程序只傳可序列化資料，且註冊必須附擁有者與租約。

### 5. 驗證

- 新增持久化狀態時，在 `## Authority` 指向的所有權表中能找到它的列；找不到就是分類還沒做完。
- 跨宿主註冊時，確認有 `lease_id` 與撤銷路徑；宿主消失後該註冊必須自動失效。
- 撰寫 `docs/` 或 PR 描述時，明講這份狀態歸誰，不寫「儲存在本地」這種不指定擁有者的說法。

## Calibrated Examples

這些例子設定判斷刻度。表面形狀不是判準，「失去它會怎樣」才是。

**插件想記住使用者上次選的排序方式** → 看它要不要跨 UI 元件替換存活。只在面板開著時有意義 → UI 暫態，歸 Shell。使用者期待換了 Dock 供應者之後排序還在 → 配置，進 Profile，經 ChangeSet 寫入。**兩者都不是「插件自己找個地方存」。**

**Cordis 插件需要一份自己的設定** → 透過 Core 支援的 settings namespace 註冊 schema 並讀取解析值；使用者修改即產生 revision。插件不自行讀寫設定檔，否則第 4 步的禁則 1 與 2 同時觸發。

**Agent 需要記住上次的規劃進度** → 會話儲存，歸 Core。Agent 閒置 5 分鐘會退出，任何只活在它記憶體裡的東西都會消失；而重啟後必須能從已保存會話與 operation_id 恢復，不重播有副作用的工具。

**桌面需要一份已安裝應用的索引** → 這是可重建的觀測資料，不是配置。歸產生它的服務所有，可持久化為快取，但**必須可以在遺失後重建**，且不進 Profile 匯出。判準：使用者換一台機器套用同一份 Profile 時，這份資料應該重新產生而不是被搬過去。

**視窗 ID 想拿來當「上次開在第二工作區的那個終端」的記憶** → 不行。視窗 ID 由合成器管理且不跨登入穩定。要記住布局意圖，記的是規則（哪類應用去哪個工作區），不是特定視窗的身分。

**同程序的可信插件想直接呼叫宿主內部 API** → 可以，但必須如實標示信任等級。同程序不具隔離；不得因為「它在我們的程序裡所以安全」而把它當作已授權——授權仍由 Core 的權限模型決定。

## Related Skills

- `ditto-capability-contract` — 決定歸屬之後，能力的 schema、錯誤集與版本怎麼定（specializes 本 skill）。
- `ditto-process-budget` — 所有權在程序與資源面的展開：要不要開程序、要不要常駐（specializes 本 skill）。
- `ditto-permission-and-secrets` — 授權主體與能力綁定的歸屬源自本 skill 的所有權模型（specializes 本 skill）。
