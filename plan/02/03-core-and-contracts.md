# 03｜Core、契約與合成器轉接

> 對應工作包：G0-CORE-01～06。本文給的是 G0 要建立的倉庫骨架、契約型別管線、能力目錄的實際清單與描述子、IPC 協定細節、身分綁定與合成器轉接的設計判準。

開工前讀 `ditto-capability-contract` 與 `ditto-authority-boundaries`；身分綁定另讀 `ditto-permission-and-secrets`。

## 1. 倉庫骨架（G0-CORE-01）

`milestones/01/01 §4` 定義了完整的目標結構。**G0 只建立其中的子集**，其餘目錄等到對應階段再建——空目錄會讓人誤以為那部分已經開始。

```
Ditto/
├─ crates/
│  ├─ ditto-protocol/        契約型別與 schema 匯出（schemars）
│  ├─ ditto-core/            最小服務：IPC、能力路由、事件流
│  ├─ ditto-compositor/      Wayland 轉接
│  ├─ ditto-measure/         PSS／CPU 取樣與報告產生
│  └─ dittoctl/              診斷 CLI（G0 只有 probe 子命令）
├─ shell/                    Quickshell／QML（見 04）
├─ packages/
│  └─ protocol/              產生的 TS 型別 ＋ JSON-RPC client
├─ schema/                   契約產物（進版控）
├─ tools/
│  └─ compositor-probe/      合成器探針套件
├─ tests/g0/                 G0 驗證腳本
├─ artifacts/                量測與驗證輸出（**不進版控**，路徑固定）
├─ packaging/reference-image/
└─ docs/platform/            支援矩陣、能力差異表、輸入法報告
```

G0 **不建立**：`crates/ditto-store`、`crates/ditto-supervisor`、`packages/host-runtime`、`packages/host-sdk`、`packages/plugins`、`packages/agent-*`、`packages/generation`、`profiles/`。

### 1.1 CI 骨架

| 工作流 | 觸發 | 內容 | 阻擋合併 |
| --- | --- | --- | --- |
| `contracts.yml` | PR、push | schema 新鮮度、能力目錄一致性、跨語言契約測試 | 是 |
| `rust.yml` | PR、push | `cargo fmt --check`、`clippy -D warnings`、`cargo test` | 是 |
| `node.yml` | PR、push | lint、型別檢查、Vitest | 是 |
| `licenses.yml` | PR、push | 依賴授權掃描，輸出清單 | 否（產出報告；出口評審檢查） |
| `nightly-refmachine.yml` | 每夜，`ditto-refmachine` | EX-01／03／04 腳本＋ artifacts | 否 |
| `weekly-measure.yml` | 每週，`ditto-refmachine` | 完整量測流程 | 否 |

既有的 `skills.yml` 不動。授權掃描從第一天就跑，理由見 `ditto-release-audit`：發行前才盤點會變成考古。

## 2. 契約型別管線（G0-CORE-02）

### 2.1 方向固定

```
crates/ditto-protocol/src/*.rs      Rust 權威型別（serde ＋ schemars derive）
        │  cargo run -p ditto-protocol --bin export-schema
        ▼
schema/*.json                       JSON Schema ＋ 能力目錄（進版控）
        │  pnpm --filter @ditto/protocol run generate
        ▼
packages/protocol/src/generated/    TS 型別（進版控）
```

TS 側**不得**手寫第二份型別。手改產生物會在下次產生時被覆蓋，而在那之前已經造成漂移。

### 2.2 能力目錄是資料，不是文件

這是 G0 最值得投資的一個設計決定：把能力描述子寫成 Rust 的資料結構，而不是散落在文件與程式碼註解裡。

```
crates/ditto-protocol/src/catalog.rs   → 每項能力的描述子（見 §3）
        ↓ export-schema
schema/catalog.json                    → 目錄產物
        ↓
ditto-core 啟動時載入，供 desktop.capabilities.list 回覆
```

好處是一致性可以被機械檢查，而不是靠 review。`contracts.yml` 的能力目錄一致性 gate 檢查四件事：

| 檢查 | 失敗代表 |
| --- | --- |
| 目錄中每項能力都有已註冊的 handler | 有 Definition 沒有 Provider——Agent 未來會看到叫不動的能力 |
| 每項能力都有至少一個標記過的 Consumer（測試或 UI 路徑） | 沒有任何路徑證明它能用 |
| `readback` 指向的能力存在於目錄中 | 回讀路徑斷掉，成功判定不成立 |
| 無 `readback` 的能力被標記為 `claimable: false`，且測試驗證它無法作為成功判準 | 會出現「宣稱成功但無法證明」的操作 |

本計畫提案四項任一失敗即擋下合併，須在 CORE-02 開工前完成 D-23 核定。這把 `ditto-capability-contract` 的 seam 三角規則從人工審查變成 CI 規則。

### 2.3 契約版本

- 能力描述子的 `version` 是**契約版本**，與套件版本無關。
- 新增選用欄位不升版；新增必要欄位或改變既有欄位語意即破壞性變更，升版並保留過渡。
- 協定層另有 `protocol_version`，涵蓋框架、握手與錯誤集。G0 從 `0.1.0` 開始。

## 3. G0 能力目錄

G0 交付以下 13 項能力。每項都必須湊齊 seam 三角：Definition 在 `ditto-protocol`，Provider 在 `ditto-compositor` 或 `ditto-core`，Consumer 至少一個（QML Shell 或 `dittoctl probe`）。

| capability_id | 種類 | idempotency | cancellable | readback | 備註 |
| --- | --- | --- | --- | --- | --- |
| `desktop.capabilities.list` | 讀 | none | false | — | 回傳目錄本身；`claimable: false` |
| `desktop.outputs.list` | 讀 | none | false | — | 名稱、解析度、縮放、位置、啟用狀態 |
| `desktop.workspaces.list` | 讀 | none | false | — | — |
| `desktop.workspaces.get` | 讀 | none | false | — | — |
| `desktop.workspaces.activate` | 寫 | natural | false | `desktop.workspaces.get` | 合成器不支援時回 `unsupported` |
| `desktop.windows.list` | 讀 | none | false | — | — |
| `desktop.windows.get` | 讀 | none | false | — | 多數寫操作的回讀目標 |
| `desktop.windows.focus` | 寫 | natural | false | `desktop.windows.get` | 回讀比對 `focused` |
| `desktop.windows.move` | 寫 | natural | false | `desktop.windows.get` | **最可能回 `unsupported`**（見 [02 §4.3](02-platform-and-compositor.md#43-協定與能力清單) 的 C-04） |
| `desktop.windows.resize` | 寫 | natural | false | `desktop.windows.get` | 同上 |
| `desktop.windows.set_state` | 寫 | natural | false | `desktop.windows.get` | minimize／maximize／fullscreen／restore |
| `desktop.windows.close_request` | 寫 | key-based | false | `desktop.windows.list` | 見下方說明 |
| `desktop.events.subscribe` | 訂閱 | none | true | — | 回傳快照＋起始 `seq` |

### 3.1 `close_request` 的語意要寫對

關閉不是同步保證：應用可以拒絕、可以彈出「未儲存」對話框。依 `ditto-capability-contract` 的判準，它只能回報「已送出」，不能回報「已完成」：

- 回應內容是 `{ accepted: true, operation_id }`，語意是「請求已送達合成器」。
- 真正的結果由 `desktop.events` 的視窗消失事件確認，或由 `desktop.windows.list` 回讀確認。
- `idempotency: key-based`：中斷重連時以冪等鍵查詢既有 operation，不重送。
- **命名也要對**：叫 `close_request` 而不是 `close`，讓消費者從名字就知道它不保證結果。

### 3.2 描述子欄位

每項能力在 `catalog.rs` 中填滿以下欄位，缺一不可：

```
capability_id     desktop.windows.move
version           1.0.0
input_schema      JSON Schema（由 schemars 產生）
output_schema     JSON Schema
errors            封閉集合，必含 unsupported
resource_scope    G0 一律為空集合，且要刻意寫下（代表任何已授權主體可呼叫）
cancellable       true | false
idempotency       none | key-based | natural
timeout_ms        預設與上限；無上限者不得跨程序暴露
readback          回讀能力 id，或明確的 None
claimable         有 readback 為 true；無者為 false
provider          提供者標識（G0：core 內建或 compositor-adapter）
availability      always | depends_on_compositor（附差異表列的引用）
```

`resource_scope` 在 G0 為空並不是漏填——G0 沒有權限模型。**要刻意寫下空集合**，讓 G1 加入權限時一眼看出哪些能力還沒分級。

### 3.3 `unsupported` 的處理

合成器不支援的操作，三件事同時成立：

1. 呼叫回傳封閉錯誤集中的 `unsupported`，不回成功、不回空成功、不以「已排程」代替。
2. `desktop.capabilities.list` 回覆中該能力的 `availability` 標記為不可用，並附原因。
3. Shell 據此不顯示會失敗的按鈕（見 [04 §8](04-shell-and-avatar.md#8-合成器能力要誠實)）。

第 2 點容易漏：如果只有呼叫時才回 `unsupported`，消費者必須先失敗一次才知道。能力目錄要能**事前**回答可用性。

## 4. IPC 協定（G0-CORE-03）

### 4.1 傳輸與框架

| 項目 | 值 |
| --- | --- |
| 傳輸 | Unix domain socket，`$XDG_RUNTIME_DIR/ditto/core.sock`，權限 0600 |
| 框架 | 換行分幀，一行一個 JSON-RPC 2.0 訊息；格式錯誤的行忽略並計數 |
| 形狀來源 | 沿用 harness `packages/sdk/protocol` 的換行分幀作法（見 `ditto-upstream-port`：這是**薄轉接**，形狀沿用、程式碼不複製；仍要留移植紀錄） |
| 編碼 | UTF-8；單行上限（預設 1 MiB）超出即斷線並回報 |

### 4.2 信封欄位

JSON-RPC 2.0 沒有為自訂中繼資料保留位置。為了保持訊息合規，Ditto 的信封欄位放在 `params._meta` 與 `result._meta`：

```jsonc
// 請求
{ "jsonrpc": "2.0", "id": "req-17", "method": "desktop.windows.focus",
  "params": { "window_id": "w-3",
              "_meta": { "protocol_version": "0.1.0",
                         "operation_id": "op-8f2a",   // 有副作用者必填
                         "deadline_ms": 2000 } } }

// 回應
{ "jsonrpc": "2.0", "id": "req-17",
  "result": { "focused": true,
              "_meta": { "revision": 41, "readback_verified": true } } }
```

`readback_verified` 是 G0 就要建立的習慣：寫操作的回應要說明它是否已經回讀確認。G1 的 ChangeSet 直接消費這個欄位。

### 4.3 握手與版本協商

1. 連線後的第一個訊息必須是 `core.handshake`，帶 `protocol_version`、`client`（kind／version）、`auth`（見 §5）。
2. 版本相容 → 回覆協商後的版本、能力目錄 revision、伺服端資訊。
3. **版本不相容 → 明確拒絕並關閉連線**，不降級、不忽略未知欄位後照常執行。
4. 握手完成前的任何其他方法一律拒絕。

### 4.4 錯誤集

封閉集合，對應到 JSON-RPC 的應用錯誤碼區間：

| code | 名稱 | 用於 |
| --- | --- | --- |
| -32000 | `unsupported` | 合成器或平台不支援此操作 |
| -32001 | `invalid_params` | schema 驗證失敗 |
| -32002 | `not_found` | 目標不存在（視窗已關閉、工作區已移除） |
| -32003 | `permission_denied` | G0 保留，尚無權限模型 |
| -32004 | `timeout` | 超過 `deadline_ms` 或能力上限 |
| -32005 | `cancelled` | 呼叫方取消 |
| -32006 | `conflict` | 狀態已變（G1 的基底 revision 檢查會用到） |
| -32007 | `unavailable` | 提供者暫時不可用（轉接未就緒、合成器連線中斷） |
| -32008 | `protocol_version_unsupported` | 握手拒絕 |
| -32009 | `identity_rejected` | 身分無法建立或自述身分被拒（見 §5） |
| -32099 | `internal` | 未分類錯誤；**訊息不得包含敏感內容** |

新增錯誤值即契約版本變更。消費者必須能窮舉處理所有分支——TS 端以聯集型別產生，Rust 端以 enum，兩邊由同一份 schema 產生。

### 4.5 事件流、快照與重連

| 規則 | 內容 |
| --- | --- |
| 訂閱 | `desktop.events.subscribe` 回傳 `{ subscription_id, snapshot, seq }`。**先給快照再給事件**，消費者不需自己拼湊初始狀態 |
| 事件 | 通知 `desktop.events`，帶 `subscription_id`、`seq`（單調遞增）、`revision`、`payload` |
| 佇列 | 每個訂閱有上限（預設 1024 則）。滿了**不靜默丟棄** |
| 溢位 | 送出 `{ reason: "resync_required" }` 後停止該訂閱；消費者必須重新訂閱取得新快照 |
| 重連 | 客戶端重連後重新訂閱；若帶上次的 `seq` 且仍在佇列範圍內，補送其後事件，否則回 `resync_required` |
| 來源 | 事件來自合成器的協定事件。**沒有事件來源的狀態才允許有界輪詢**，並在程式碼註解記錄理由（RUN-07） |

不得依賴未持久化的事件推導唯一真相：任何消費者都必須能只靠「快照＋後續事件」重建狀態。

### 4.6 取消與逾時

- 取消：JSON-RPC 通知 `$/cancel`，帶目標 `id`。伺服端對已取消的請求回 `cancelled` 錯誤。
- `cancellable: false` 的能力收到取消請求時回 `not_cancellable`（歸在 `invalid_params` 之下並附原因），**不假裝取消成功**。
- 逾時：以 `deadline_ms` 與能力的 `timeout_ms` 上限取小者。逾時後伺服端停止等待並回 `timeout`；若操作可能已在合成器端生效，回應中標記 `outcome: "unknown"`——這是 CON-07「結果未知」在 G0 的最小形式。

## 5. 呼叫身分綁定（G0-CORE-04）

SEC-11 的骨架。規則來自 `ditto-permission-and-secrets` 第 6 步：**身分不可自述**。

| 機制 | 做法 |
| --- | --- |
| 程序身分 | socket 的 peer credential（uid／pid）；非同一 uid 一律拒絕 |
| 呼叫身分 | 受控啟動器在啟動客戶端時發放一次性 token（經環境變數或已開啟的 fd 傳遞，不落盤於可讀路徑），客戶端在握手時提交 |
| 綁定 | Core 將 token 對應到啟動時登記的身分（kind、版本、預期路徑），連線期間不可變更 |
| 拒絕 | 訊息中自填的 `plugin_id`／`client_id` 一律**忽略**；若其與綁定身分衝突，回 `identity_rejected` |
| 降級禁止 | 沒有有效 token 的連線**不得**降級為匿名後繼續服務；直接拒絕 |

G0 的負例測試（EX-07）：

1. 合法連線後在請求中自填高權限 `plugin_id` → 該欄位被忽略，且衝突時回 `identity_rejected`。
2. 未經啟動器、直接連 socket 的程序 → 握手被拒。
3. 同 uid 的另一個程序拿到過期或他人的 token → 被拒。

**G0 不做**權限授予、撤銷或分項授權。這裡只確立「身分從哪裡來」，避免 G1 在既有的自述身分上疊加權限模型。

## 6. 合成器轉接（G0-CORE-05）

### 6.1 位置與所有權

`crates/ditto-compositor` 是 Provider，`ditto-core` 是路由。依 `ditto-authority-boundaries` 的所有權表：**視窗、工作區、輸出是合成器擁有的觀測狀態，不持久化**。

三條禁則：

1. 不建立視窗狀態的持久化快取。記憶體投影可以有（供事件與回讀），但重連後一律重新查詢。
2. **視窗 ID 不作為跨登入身分。** G0 的視窗 ID 只在本次工作階段內有效，型別上就標明這件事（型別名稱與文件都要說清楚）。
3. 不重做第二套逐幀視窗管理器。轉接只翻譯協定，不維護自己的布局狀態。

### 6.2 能力 → 協定映射

實作時每項能力都要標註它依賴哪一列差異表：

| 能力 | 依賴 | 缺口時的行為 |
| --- | --- | --- |
| `windows.list`／`get` | C-02 | 阻斷級，缺則 G0 無法成立 |
| `windows.focus`／`set_state`／`close_request` | C-03 | 同上 |
| `windows.move`／`resize` | C-04 | 若只能經專屬 IPC：實作之，並在 `availability` 標記綁定；若無路徑：回 `unsupported` |
| `workspaces.*` | C-05 | 同 C-04 |
| `outputs.list` | C-06 | 阻斷級 |
| `events.subscribe` | C-02／C-05／C-06 的事件 | 沒有事件來源的子集以有界輪詢補，並記錄理由 |

### 6.3 連線中斷

合成器連線中斷時（合成器重啟、協定錯誤）：

- 受影響能力**立即**標記為 `unavailable`，不是等到下次呼叫才失敗。
- 進行中的請求回 `unavailable`；有副作用者標記 `outcome: "unknown"`。
- 所有訂閱送出 `resync_required`。
- 重連後重新列舉並重建投影，**不重播事件**。

這段邏輯在 G0 就要寫對，因為 G1 的租約與變更協調會直接建在它上面（見 `ditto-failure-and-rescue` 第 3 步的能力表）。

## 7. `dittoctl probe`（G0-CORE-06）

診斷 CLI，G0 只有 `probe` 子命令群。它的存在有三個理由：滿足每項能力至少一個 Consumer 的規則、讓 IPC 能在無圖形環境測試、讓契約測試進得了 PR 快檢。

| 子命令 | 作用 |
| --- | --- |
| `dittoctl probe handshake` | 連線、握手、印出協商結果與目錄 revision |
| `dittoctl probe capabilities` | 列出能力目錄，含 `availability` 與 `claimable` |
| `dittoctl probe windows [--json]` | 列舉視窗 |
| `dittoctl probe window <id> --focus\|--move\|--state` | 執行一次寫操作並**自動回讀比對**，輸出比對結果 |
| `dittoctl probe workspaces` | 列舉與切換 |
| `dittoctl probe events --for 10s` | 訂閱事件並印出快照與後續事件的 `seq` |

`--json` 輸出是 EX-01 矩陣腳本的資料來源。

**邊界**：G0 的 `dittoctl` 不是救援 CLI。它需要 Core 在跑才有用；救援模式要求的「不依賴 Node 與主 Shell」在 G0 只是碰巧成立的副產品，不得宣稱 REC-03 已開始。

## 8. G0 的禁則

寫程式時每一條都會有誘因違反：

1. **不建立任何持久化配置。** 沒有 SQLite、沒有設定檔、沒有 `$XDG_CONFIG_HOME` 寫入。需要參數就用命令列參數或編譯期常數。
2. **不在 Core 內做重工作。** 轉接、解析、量測都不得阻塞 IPC 服務迴圈。
3. **不讓 QML 直接碰合成器。** 唯一的路徑是能力呼叫。
4. **不跨程序傳遞非資料。** 只傳可序列化資料。
5. **不為了介面完整而讓能力假裝成功。** 沒有 Provider 的能力不進目錄；不支援的操作回 `unsupported`。
6. **不引入 Node 執行期到桌面工作階段。**

## 9. 測試

| 層 | 內容 | 跑在哪 |
| --- | --- | --- |
| 單元（Rust） | schema 編解碼、錯誤映射、事件序號、佇列溢位 | VM／容器 |
| 單元（TS） | client 的框架處理、重連、取消 | VM／容器 |
| 契約（跨語言） | 同一組測試向量在 Rust 與 TS 兩側編解碼一致；錯版拒絕；亂序事件；重連補事件 | VM／容器 |
| 目錄一致性 | §2.2 的四項檢查 | VM／容器 |
| 身分負例 | §5 的三項 | VM／容器 |
| 轉接整合 | 能力 × 參考應用矩陣（EX-01） | **實體參考機** |

前五層進 PR 快檢，轉接整合進 nightly。這條分界線的判準很單純：**需要真實合成器與真實應用的，就不能進 PR 快檢**。
