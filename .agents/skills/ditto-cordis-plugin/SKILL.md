---
name: ditto-cordis-plugin
description: >-
  Write or review a plugin in the Ditto Cordis desktop service host: declare
  dependencies with inject, make every registration reversible, respect fiber
  states, attach leases to cross-host registrations, and follow the event
  dispatch contract. Use when adding a desktop service plugin, consuming or
  replacing a service, registering listeners or timers, debugging a plugin stuck
  in PENDING, or reviewing plugin teardown and cleanup.
metadata:
  type: skill
  category: runtime
  status: draft
  language: zh-Hant
  related:
    - ditto-changeset-transaction
    - ditto-upstream-port
---

# Ditto Cordis 插件

> 在 Cordis 桌面宿主內撰寫或審查插件：依賴、可逆註冊、fiber 生命週期與跨宿主租約。

> **status: draft** — 本 skill 描述的宿主契約來自 [milestones/01/02](../../../milestones/01/02-cordis-adoption.md) 的設計，`ditto-host-loader` 與租約協定實作完成後（G1-HOST-02／03）須回頭核對實際 API 並改為 stable。

## Overview

Cordis 是 Ditto 的桌面服務宿主，不是 Agent 的內部實作。它給的東西很具體：插件以 `inject` 宣告依賴而不是靠載入順序、註冊是會自動撤銷的副作用、依賴消失時消費者跟著卸載並在恢復後重新載入。

用錯的代價集中在卸載路徑。一個在 `apply()` 裡直接 `setInterval` 而沒有包進 `ctx.effect()` 的插件，平常完全正常，只有在熱換、依賴替換或宿主回收時才會留下跑著的計時器——而那正是 Ditto 每次變更都會走的路徑。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [milestones/01/02 Cordis 沿用範圍、橋接設計與契約測試](../../../milestones/01/02-cordis-adoption.md)
- [PRD v0.4.0 §15.6 Cordis 的沿用範圍與跨宿主橋接](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §12 插件中心與 SDK](../../../docs/product/Ditto-PRD-v0.4.0.md)

對應需求：RUN-10、RUN-11、RUN-12、RUN-07、MOD-05、MOD-07、MOD-08、AT-30、AT-31

## When to Use

用於：新增桌面服務插件；消費或替換服務；註冊監聽器、計時器、訂閱或外部資源；插件卡在 PENDING 的排查；審查插件的卸載與清理。

不適用：

- 跨程序的 schema、錯誤集與版本 → `ditto-capability-contract`。
- 兩階段準備／提交／回復的協調 → `ditto-changeset-transaction`。
- 這份狀態該不該由插件持有 → `ditto-authority-boundaries`。
- 從上游取用 Cordis 套件的紀錄義務 → `ditto-upstream-port`。

## Workflow

### 1. 先讀契約

打開 `milestones/01/02 §2 沿用對照表` 與 `§3 ditto-host-loader 設計`。那裡定義了哪些是直接沿用 Cordis、哪些是 Ditto 新增的橋接；本節只給撰寫判準。

### 2. 用 `inject` 宣告依賴，不要自己排順序

```ts
export const name = 'ditto-svc-tasks'
export const inject = ['ditto', 'tasksStore']

export function apply(ctx: Context) {
  // 進到這裡時，inject 列出的服務保證已就緒
}
```

- 條目在配置中的位置**不決定**載入順序，依賴才決定。
- `inject` 不是一次性啟動檢查：服務在執行期消失（供應者被卸載或熱換）時，消費者會一併卸載，並在服務恢復後重新載入。
- 軟依賴不寫進 `inject`，改在使用處探測並準備好「沒有它也能跑」的路徑。

### 3. 每個註冊都要有 disposer

Cordis 管理的 API 本身就是 effect，不需要手動清理：`ctx.on()`、`ctx.plugin()`、服務註冊、以及 Ditto SDK 的能力註冊。

**Cordis 不知道的資源一律包進 `ctx.effect()` 並回傳 disposer**：計時器、連線、watcher、外部訂閱、暫存檔。

```ts
ctx.effect(() => {
  const timer = setInterval(poll, 5_000)
  return () => clearInterval(timer)
})
```

兩條容易踩的規則：

- **disposer 依註冊逆序啟動，但多個非同步 disposer 併發執行。** 需要固定順序的拆解，寫在**同一個** effect 的 disposer 內依序 await，不要拆成多個 effect 靠順序碰運氣。
- `UNLOADING` 期間不得建立新 effect。清理時想「順便註冊一個補償動作」會被拒絕；補償屬於變更層的責任，見 `ditto-changeset-transaction`。

### 4. 讀懂 fiber 狀態

```
PENDING → LOADING → ACTIVE → UNLOADING → DISPOSED
                 ↘ FAILED
```

| 狀態 | 意義 | 排查方向 |
| --- | --- | --- |
| `PENDING` | **合法狀態**，不是錯誤：所需服務尚未就緒 | 檢查 `inject` 的每個名稱是否真有供應者。插件「沒有任何輸出也沒有報錯」的答案幾乎都在這裡 |
| `FAILED` | `apply` 或設定驗證拋出 | 看設定 schema 與 `apply` 的第一段 |
| `ACTIVE` | 正常運作 | — |

插件中心的宿主診斷直接讀這些狀態（MOD-01、REC-07）。回報時**不得**把 `PENDING` 顯示成錯誤，也不得把它含糊成「載入中」——它是「等待某項服務」，而那項服務的名稱是可以說出來的。

### 5. 跨宿主註冊要附租約

宿主內的 effect 清理只在宿主內有效。發布給 Core 的能力註冊必須：

- 取得 `lease_id` 並定期續約；
- 插件卸載時，本地 disposer 連帶通知 Core 撤銷；
- 宿主崩潰或租約逾期時，Core 立即把該能力標示不可用；
- 重連後重建依賴與代理，**不得重播已完成的外部副作用**。

**釋放註冊不等於撤銷已發生的外部副作用。** 插件卸載會撤掉它的能力綁定，但它先前造成的檔案寫入、通知送出或外部呼叫不會因此回復。

### 6. 遵守事件分發契約

分發模式是事件契約的一部分，宣告什麼就只能用什麼分發：`emit`（同步廣播）、`parallel`（並發等待）、`serial`（依序、首個非空值勝出）、`bail`（serial 的同步版）、`waterfall`（環繞中介軟體）。

**waterfall 的紀律只有一條，但很容易違反：只做觀察或標註的監聽器必須呼叫 `next()`。** 不呼叫 `next()` 就直接返回等於有意短路，會靜默吞掉所有下游的預設行為。一個忘了 `next()` 的日誌監聽器，可以讓整條策略鏈不再執行且完全沒有錯誤訊息。

### 7. 訂閱優先於輪詢

優先訂閱事件。只有在來源沒有事件 API 時才輪詢，且必須有界、記錄理由、在元件隱藏時停止。詳見 `ditto-process-budget`。

### 8. 命名與隔離

- 服務名稱共用一個扁平命名空間。Ditto 自有服務一律加 `ditto` 前綴或命名空間，不佔用通用名稱。
- `ctx.isolate` 可以讓不同區段看到各自的服務實例，**但它不是安全邊界**。未信任的程式碼需要程序隔離，見 `ditto-generation-safety`。

### 9. 驗證

對照 `milestones/01/02 §4` 的生命週期契約測試 L-01～L-10，新插件至少要通過：

- L-01 依賴消失：卸載供應者後，本插件自動卸載並釋放註冊，供應者恢復後重新載入。
- L-03 重複註冊：候選與現役不得同時發布同一單一供應者能力。
- L-04 Context 撤除：反覆掛載與撤除 100 次，無殘留註冊、無殘留訂閱。
- L-08 非同步 disposer 未完成即再次掛載：第二次掛載等待前次清理完成。

整合層另由 AT-30（終止 Agent 後服務與事件仍有效）與 AT-31（無孤兒註冊與舊租約）驗收。

## Calibrated Examples

**插件要每 5 秒抓一次外部資料** → 計時器包進 `ctx.effect()`；但先問有沒有事件來源。若確實只能輪詢，記錄理由，並在插件中心顯示這項活動讓成本可見。裸 `setInterval` 在卸載後會繼續跑，這是 L-04 直接會抓到的殘留。

**插件想在卸載時把狀態寫回資料庫** → 可以，寫在 disposer 內。但若這個寫入必須發生在另一項清理**之後**，兩者要放在同一個 effect 的 disposer 裡依序 await——放在兩個 effect 只保證逆序啟動，不保證完成順序。

**兩個插件都想提供 `dock` 服務** → 這是單一供應者約束，由 Core 在預檢時擋下，不是靠插件自律。候選在 `commit` 前不得發布正式能力；同時發布會產生重複快捷鍵與重複命令，正是 AT-04 檢查的項目。

**插件卡在 PENDING，沒有任何輸出** → 不是錯誤，是依賴沒滿足。列出 `inject` 的每個名稱，確認各有供應者。若供應者存在但也是 PENDING，順著它的 `inject` 往下查。**不要**用「等一下再試」或加延遲來繞過。

**一個只想記錄工具呼叫的 waterfall 監聽器** → 必須 `return next()`。寫成 `ctx.on('x', async (a) => { log(a) })` 會短路整條鏈；這個錯誤不會拋例外，只會讓下游行為安靜消失。

**插件想在卸載時撤銷它剛才送出的通知** → 做不到，也不該試。effect 清理撤銷的是**註冊**，不是已發生的外部副作用。要補償就走變更層的補償路徑，並在結果回報中如實列為「已發生且不可回復」。

## Related Skills

- `ditto-changeset-transaction` — 宿主內生命週期與跨宿主的兩階段交易必須一併成立（complements）。
- `ditto-upstream-port` — 移植的 Cordis 套件同時受兩者約束（complements）。
