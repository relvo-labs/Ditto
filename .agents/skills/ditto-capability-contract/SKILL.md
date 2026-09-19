---
name: ditto-capability-contract
description: >-
  Design or change a Ditto desktop.* capability contract: the seam triangle,
  descriptor fields, closed error set, readback path, cancellation, idempotency,
  contract versioning, and the Rust-first type generation pipeline. Use when
  adding a capability, exposing a plugin service across processes, defining an
  RPC method or event, giving the Agent a new tool, or reviewing a schema change.
metadata:
  type: skill
  category: architecture
  status: stable
  language: zh-Hant
  related:
    - ditto-authority-boundaries
    - ditto-changeset-transaction
---

# Ditto 能力契約

> 新增或修改 `desktop.*` 能力時的契約設計與型別產生。

## Overview

能力是 Ditto 唯一的跨層互動方式：UI、Agent 與插件都只透過能力目錄發現與呼叫功能。契約沒設計好，錯誤會擴散到三個方向——Agent 會憑空宣稱成功、變更無法判定是否真的生效、換供應者時消費者跟著壞掉。

本 skill 管的是契約本身：有哪些角色、描述子要填什麼、錯誤怎麼封閉、成功怎麼證明。

## Authority

權威來源（本 skill 不複製其內容，有疑義以來源為準）：

- [PRD v0.4.0 §15.2 建議能力目錄](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [PRD v0.4.0 §15.5 語言中立契約與所有權](../../../docs/product/Ditto-PRD-v0.4.0.md)
- [milestones/01/01 §2 契約與型別產生](../../../milestones/01/01-architecture.md)

對應需求：CON-03、CON-07、MOD-07、DES-03、CHG-01、CHG-07、AT-27

## When to Use

用於：新增 `desktop.*` 或 `agent.*` 能力；把宿主內服務發布為跨宿主能力；定義 RPC 方法或事件；為 Agent 新增工具；審查 schema 變更或協定版本變動。

不適用：

- 這份狀態該歸誰、能不能有第二條寫入路徑 → `ditto-authority-boundaries`。
- 呼叫這項能力時的交易流程與回復 → `ditto-changeset-transaction`。
- 這項能力在宿主內怎麼註冊與清理 → `ditto-cordis-plugin`。

## Workflow

### 1. 先讀權威

打開 `milestones/01/01 §2.3 能力目錄`，確認描述子欄位清單的當前版本；本節只給填寫判準。

### 2. 確認 seam 三角都有著落

一項能力有三個角色：宣告介面的 **Definition**、實作的 **Provider**、使用的 **Consumer**。**三者缺一，這項能力就不算完成**，不得合併。

常見的不完整形態：

- 只有 Definition → 沒有人實作的 schema，Agent 會看到能力目錄裡有它卻叫不動。
- 只有 Provider → 綁死單一實作，替換供應者時消費者跟著改，違反可組合性。
- 沒有 Consumer → 沒有任何路徑證明它能用；至少要有一個 UI 入口或 Agent 工具。

### 3. 填描述子

| 欄位 | 判準 |
| --- | --- |
| `capability_id` | 動詞在最後（`desktop.windows.move`）。命名描述**做什麼**，不描述由誰實作 |
| `version` | 契約版本，與套件版本無關。欄位語意變更即升版，新增選用欄位不升 |
| `input_schema`／`output_schema` | 只放跨程序需要的資料。不得出現函式、Context、實例引用 |
| `errors` | **封閉集合**，且必須包含 `unsupported` |
| `resource_scope` | 呼叫需要的權限與資源。空值代表「任何已授權主體皆可呼叫」，要刻意寫下而不是漏填 |
| `cancellable` | 長於 1 秒的操作一律 `true`，並定義取消後的狀態 |
| `idempotency` | `none`／`key-based`／`natural`。判準見第 5 步 |
| `timeout_ms` | 預設與上限。沒有上限的操作不得跨程序暴露 |
| `readback` | 讀回這項操作真實結果的能力 id。判準見第 4 步 |

### 4. 決定 `readback`

**沒有回讀路徑的能力，不得被 ChangeSet 用於宣稱成功。** 三個選項，依序嘗試：

1. **指向既有查詢能力**（最常見）：`desktop.windows.move` 的回讀是 `desktop.windows.get`，比對目標矩形。
2. **同時新增查詢能力**：若狀態目前讀不回來，把查詢能力一起設計進這次變更。
3. **標記為不可回讀**：只有在物理上無法觀測時才用（例如送出一則系統通知）。此時該能力**只能回報「已送出」，不得回報「已完成」**，且不得作為 ChangeSet 的成功判準。

### 5. 決定冪等性

| 值 | 用於 | 例 |
| --- | --- | --- |
| `natural` | 重複執行結果相同的宣告式操作 | 設定 Dock 位置為左側 |
| `key-based` | 有副作用且不可自然去重，呼叫方提供冪等鍵 | 安裝套件、建立 Profile |
| `none` | 只讀操作 | 列舉視窗 |

有外部副作用且標成 `natural` 是最危險的組合：中斷重試時會重複執行。若不確定，選 `key-based`。

### 6. 封閉錯誤集與 `unsupported`

合成器或平台不支援的操作**必須回傳 `unsupported`**，不得靜默成功、不得回傳空成功、不得以「已排程」代替。這條直接對應 DES-03：能力表要反映現實能力，不反映期望。

錯誤集封閉的意思是：消費者可以窮舉處理所有分支。新增錯誤值即契約版本變更。

### 7. 產生型別

Rust 是單一事實來源，管線方向固定：

```
crates/ditto-protocol/src/*.rs   （schemars derive）
      → schema/*.json            （進版控）
      → packages/protocol/src/generated/  （進版控）
```

變更契約後必須重新產生並提交產物；CI 以「重新產生後無差異」驗證。手改產生物、或在 TS 側另寫一份型別，都會在下次產生時被覆蓋且先前已造成漂移。

### 8. 協定版本

呼叫攜帶 `protocol_version`。版本不相容時**明確拒絕**，不降級猜測、不忽略未知欄位後照常執行。事件攜帶 `seq` 與 `revision`；訂閱方重連先取快照再補事件，佇列溢位回報「需要重新快照」而非靜默丟失。

### 9. 驗證

- `node`／`cargo` 產生管線跑過且 `git diff` 為空。
- 跨語言契約測試涵蓋：正常編解碼、錯版拒絕、亂序事件、重連補事件（AT-27）。
- 新能力在能力目錄中可被列舉，且至少一個 Consumer 實際呼叫過。

## Calibrated Examples

**`desktop.windows.move`** — Definition 在協定層；Provider 是合成器轉接；Consumer 是布局策略與 Agent 工具。`readback` = `desktop.windows.get`。合成器不支援移動時回 `unsupported`，**不是回成功後讓使用者自己發現沒動**。`idempotency: natural`（移到同一位置兩次結果相同）。

**`desktop.notifications.suppress`** — `idempotency: natural`，`readback` = `desktop.notifications.policy.get`。看似瑣碎，但沒有 readback 就無法在 ChangeSet 裡證明「勿擾已生效」，AT-02 的回讀一致性就過不了。

**`desktop.plugins.install`** — 有外部副作用（下載、寫磁碟），必須 `key-based`：中斷重連時以冪等鍵查詢既有 operation，不得重跑。`readback` = `desktop.plugins.get`，比對版本與雜湊。安裝與啟用是**兩項能力**，不是一項的兩個參數——PRD 要求兩者分開記錄。

**「送一封 email」型的工具** — 反例。它不屬於 `desktop.*` 配置層；外部副作用不可逆，撤銷桌面配置的語意不適用於它。這類能力走受控外部工具路徑，並在文案上明確與桌面配置區分。

**只加一個查詢方法，要不要升契約版本？** 新增能力不升既有能力的版本。但若在既有 `output_schema` 增加**必要**欄位，舊消費者會解析失敗——那是破壞性變更，必須升版並保留過渡。新增**選用**欄位不升版。

## Related Skills

- `ditto-authority-boundaries` — 契約設計的上游：先確定這份狀態歸誰（specializes 它）。
- `ditto-changeset-transaction` — 交易層取用本契約的 `readback`、`idempotency` 與取消語意（consumes 本 skill）。
