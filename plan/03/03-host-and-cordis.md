# 03｜Cordis 宿主、交易層與服務插件

> 對應工作包：G1-HOST-01～12。本文的 harness 事實以盤點時的 HEAD `477b4f4`（2026-09-24）為準，D-04 定案時重新核對。
>
> 開工前讀 `ditto-cordis-plugin`（draft，本階段會讓它具備轉 stable 的條件）與 `ditto-upstream-port`；交易層另讀 `ditto-changeset-transaction`。

## 1. 目錄與套件

```
packages/
├─ protocol/                 （既有）協定 0.2 型別 ＋ client；新增 server 端（hostd 需要回應 Core 的請求）
├─ host-runtime/             ditto-hostd
│   ├─ vendor/               vendored Cordis（見 §2）
│   ├─ src/
│   │   ├─ main.ts           啟動：讀 token fd、握手、建立根 Context
│   │   ├─ bridge/           Core 連線、participant 方法、host.* 方法
│   │   ├─ loader/           ditto-host-loader：交易層（§4）
│   │   ├─ ditto-service.ts  根層級的 `ditto` 服務：capabilities／data／permissions／events／lifecycle
│   │   ├─ leases.ts         租約表與批次續約
│   │   └─ resources.ts      Node 記憶體欄位回報
│   └─ tests/lifecycle/      L-01～L-10
├─ host-sdk/                 插件作者 SDK（§8）
├─ plugins/
│   ├─ svc-tasks/            服務插件 ①（§6）
│   └─ svc-notification-policy/  服務插件 ②（§7）
└─ plugin-fixtures/          10 個簡單插件（D-34）與故障夾具（拋錯、永不就緒、拒絕清理）
```

## 2. Cordis 取用（G1-HOST-01）

### 2.1 取用範圍

| 套件 | 取用 | 理由 |
| --- | --- | --- |
| `@deepseek-ai/cordis` | **是** | 核心：Context、inject、effect、fiber、事件 |
| `@deepseek-ai/cosmokit` | 是 | cordis 的執行期依賴 |
| `@deepseek-ai/schemastery` | 是 | 插件設定 schema 與預設值補齊；Cordis 原生接受 |
| `@deepseek-ai/cordis-plugin-loader` | **是** | 以 id 為鍵的條目樹；`class Loader extends EntryTree` 在記憶體中運作、`write()` 是 no-op |
| `@deepseek-ai/cordis-plugin-timer` | 是 | 插件的計時器需求走受管理的服務，而不是裸 `setInterval` |
| `@deepseek-ai/cordis-plugin-group` | 視 D-32 | 策略 A 可能用群組承載候選子樹；策略 B 不需要 |
| `@deepseek-ai/cordis-plugin-include` | **否** | 檔案回寫路徑；配置權威在 Core（`milestones/01/02 §1`） |
| `@deepseek-ai/cordis-plugin-hmr` | **否**（產品）｜開發期另議 | 依賴 chokidar 與 esbuild，不進產品執行期 |
| `@deepseek-ai/cordis-plugin-logger-console` | 否 | hostd 以自己的 exporter 輸出結構化 JSON 到 stderr，由 journald 收取 |

### 2.2 鎖定

| 項目 | 盤點值（D-04 定案時重新核對） |
| --- | --- |
| harness commit | `477b4f420553e8a52c2fbccc464d7561b239c443` |
| `@deepseek-ai/cordis` | release 4.0.4；上游 `cordis` 4.0.0-rc.7，`cordiverse/cordis` commit `56b3d4f725681cf4556c1a8695a709cc3b6eed74` |
| loader | release 1.0.5；上游 1.0.0-rc.5，同一上游 commit |
| timer／group | release 1.1.6／1.0.4；上游為 deepseek-harness/cordis fork `abb0a307cb1d3b0947f455d590cf5ba922d4caa4` |
| cosmokit／schemastery | release 1.8.5／3.18.4 |
| harness 本地修改集 | **22 項**（`vendor/README.md`）。Ditto 直接依賴的是第 6（fiber 生命週期強化）、8（loader 非交易式的明文）、15（lazy config）、18（`disabled` 每次掛載重新求值）、20（entry 保存真實 fiber）、21（logger exporter disposal）、22（volatile config）項 |
| Node | Ditto 凍結 22.23.2；harness 根 `engines` 為 `^22.19.0 \|\| >=24.0.0`，相容。vendored 套件本身沒有宣告 `engines` |
| pnpm | Ditto 10.11.0；harness 11.7.0。vendored 套件的 `workspace:~` 在 pnpm 10 可用；同步時不得引入 pnpm 11 專屬語法 |

### 2.3 取用方式

- 複製 `src/`、`LICENSE`、`README.md`、`package.json` 到 `packages/host-runtime/vendor/<name>/`，**保留 `@deepseek-ai/*` 套件名**（私有 workspace 套件，不發布）。改名會新增一項修改，且讓之後與 harness 的差異比對變困難。
- 保留 harness 的修改集原文，並另起 **Ditto 修改集**（編號 `D1`、`D2`…），寫在 `packages/host-runtime/vendor/README.md`。
- hostd 以 tsdown 打包成單一 ESM 檔。理由：模組檔案數直接影響 Node 啟動時間與常駐記憶體，而 hostd 有 100 MiB 的 PSS 預算。打包工具的版本鎖定在 D-04 的紀錄中一併核定。
- `FiberState` 在上游是 `const enum`，執行期讀不到；沿用 harness `plugin-inventory` 的做法，在 `host-runtime` 內鏡像一份，並以測試比對兩者數值一致。

## 3. hostd 架構

### 3.1 啟動與身分

1. Core 經受控啟動器啟動 hostd（kind `hostd`），token 經 fd 3 交付，放進 `ditto-hostd.scope`（D-06b 的服務配額）。
2. hostd 以協定 0.2 握手，並在 `host.hello` 回報 hostd 版本、Cordis 版本、Node 版本與 vendored 指紋。
3. hostd 建立根 `Context`、掛上 `Loader` 與根層級的 `ditto` 服務，然後**什麼都不載入**，等 Core 推送條目。
4. Core 以一個 `participant.prepare`／`commit`（`origin=host_boot`）推送目前 revision 中所有 `host: cordis` 的條目。hostd 重啟時走同一條路，所以「開機」和「重建」是同一段程式碼。

**hostd 沒有任何磁碟上的條目來源。** 它重啟時條目列表是空的，這是刻意的：唯一的真相在 Core（原則 1、`ditto-authority-boundaries` 禁則 2）。

### 3.2 模組解析

Loader 以 `tree.import(name)` 載入插件模組。hostd 覆寫解析規則：

- 只接受 Core 在推送條目時一併提供的 `package → 套件庫路徑` 對應，路徑必須位於 `$XDG_DATA_HOME/ditto/packages/sha256/` 之下。
- 不從 `node_modules`、相對路徑或任意絕對路徑載入。
- 這不是安全邊界（同程序 Node 仍能 `import()` 任何東西），只是讓「載入的是哪個版本」可驗證。信任等級如實標示為「可信 TS 桌面服務插件，同宿主、無隔離」（12.1 節）。

### 3.3 根層級的 `ditto` 服務

插件以 `inject: ['ditto']` 取得 Ditto 橋接。**Context 不跨程序**；`ctx.ditto` 是 hostd 內的服務，它把呼叫轉成協定訊息：

| 介面 | 作用 | 對應 Core 方法 |
| --- | --- | --- |
| `ctx.ditto.capabilities.register(def)` | 發布能力；本身是 effect，卸載即撤銷 | `host.capability.register`／`revoke` |
| `ctx.ditto.capabilities.call(id, input)` | 呼叫其他能力，身分為 `host:<entry_id>` | 一般能力呼叫 |
| `ctx.ditto.events.emit(name, payload)` | 發布跨程序事件 | `host.event` |
| `ctx.ditto.events.subscribe(id, handler)` | 訂閱 Core 事件（需授權） | `desktop.events.subscribe` |
| `ctx.ditto.data` | 讀寫插件資料區（`plugin-data/<plugin_id>/`） | Core 分配路徑；hostd 只在該目錄內操作 |
| `ctx.ditto.permissions` | 查詢授予；監聽撤銷 | `desktop.permissions.check`、撤銷事件 |
| `ctx.ditto.lifecycle` | `onDrain`、`exportState`、`importState`、`health` | 交接協定（§5） |
| `ctx.ditto.mode` | `'candidate' \| 'active'` | 由交易層設定 |

## 4. 交易層 `ditto-host-loader`（G1-HOST-02）

### 4.1 問題

harness loader 的條目樹變更是 eager、非交易式的（修改集第 8 項明文）：

- `EntryGroup.update` 以 `Promise.all` 立即且並發地建立或移除，錯誤只記錄。
- `Entry.update` 先改 `this.options` 再執行。
- 插件失敗後 fiber 停在 `FAILED`，先前的 options 與插件**不會恢復**。

所以交易層的第一條規則是：**hostd 內除了交易層，沒有任何程式碼可以呼叫 `ctx.loader.create/update/remove`。** 交易層以自己的狀態包住 loader，loader 只是執行工具。

### 4.2 候選策略（D-32）

候選與現役要如何並存、commit 時如何交棒，有兩個可行策略。F-4 說明了為什麼不能照 `milestones/01/02 §3.2` 的原文直接做：isolate realm 內的服務對主 realm 不可見，Cordis 也沒有升格操作。

| | 策略 A：isolate 候選＋升格重建 | 策略 B：就地替換＋重掛回復 |
| --- | --- | --- |
| prepare | 在 `ctx.isolate(<候選提供的服務名>)` 的子 realm 掛載候選；其餘依賴照常從主 realm 解析；執行健康檢查 | 只做靜態檢查（模組可載入、設定 schema 通過、`inject` 名稱在主 realm 有供應者）；**不實際掛載** |
| commit | 舊實例 drain／handoff → dispose 舊實例（等所有 disposer）→ dispose 候選 → 在主 realm 以相同設定重建 → 第二次健康檢查 | 舊實例 drain／handoff → dispose → 在主 realm 掛載新實例 → 健康檢查 |
| commit 後失敗 | 在主 realm 重掛舊實例（舊設定保存在交易層） | 同左 |
| 優點 | 大多數失敗（模組錯誤、設定錯誤、依賴未就緒、健康檢查失敗）在 prepare 就被擋下，**現役完全不受影響** | 簡單；只有一次掛載；切換延遲低 |
| 缺點 | 兩次掛載，切換較慢；候選的健康結果不等於重建後實例的健康結果 | 健康檢查失敗發生在舊實例已卸下之後，回復靠重掛，中間有服務空窗 |
| 對 AT-09 的意義 | 「候選失敗 → 現役不受影響」直接成立 | 「候選失敗 → 回復到舊實例」成立，但有空窗，需在結果中如實說明 |

**預先承諾的判準**（必須在試作**之前**寫進 D-32 的依據欄，不得事後調整）：

1. 預設採用策略 A。
2. 策略 A 試作（預備期或 W2–W3）須同時滿足：① L-03、L-04、L-08 以策略 A 通過；② Cordis 服務插件替換的 `prepared`→`committed` p95 ≤2 秒（100 次，參考機或開發 VM 先估）；③ 100 次無故障注入的替換中，候選健康而重建後不健康的次數為 0。
3. 任一條不成立 → 採用策略 B，並在 `docs/contracts/host-protocol.md` 與使用者可見的結果中如實說明服務空窗；**不得**把策略 B 的空窗描述成即時替換。
4. 兩個策略**不混用**：同一版本的 hostd 只有一種交易語意，避免測試矩陣倍增。

QML 供應者的候選不受 D-32 影響：Shell 的候選是隱藏的 `Loader`，現役與候選天然並存（見 [04 §2](04-shell-and-surfaces.md#2-ui-供應者裝載與交易參與g1-shell-13)）。

### 4.3 獨占資源延後取得

候選在 commit 前**不得**取得正式獨占資源（CHG-02、AT-31）：

- `ctx.ditto.mode === 'candidate'` 時，`ctx.ditto.capabilities.register` 只在本地記錄，不送出 `host.capability.register`；commit 時一次送出。
- 若候選在 candidate 模式嘗試以其他方式取得獨占資源（例如直接呼叫 `desktop.shortcuts` 的綁定能力），Core 以 `conflict` 拒絕（原因 `candidate_cannot_claim`）。這是 L-03 的故障注入負例。
- Cordis 自己的 `reflect.provide()` 在同一 isolate key 重名時拋錯，天然防止同 realm 內重複提供；跨 realm 的唯一性由 Core 的 slot 表保證。

### 4.4 其他規則

- **abort 必須等整棵候選 dispose 完成**（含非同步 disposer）才回報，利用 harness fork 的 `fiber.dispose()` 語意（修改集第 6 項）。
- **需要順序的拆解放在同一個 effect 內**：交接步驟（drain → export → dispose）寫成單一 effect 的內部序列，因為多個非同步 disposer 會併發執行。
- `pending(missing_service)` 在 prepare 等同未就緒；交易層有界等待（預設 3 秒）後回報 `failed(dependency_not_ready: <服務名>)`，不無限等待。
- 條目 `id` 由 Core 產生，hostd 不自行生成（`milestones/01/02 §3.2`）。
- 交易層以 `change_id` 為鍵保存每個交易的狀態，`participant.state` 據此回答 Core 的崩潰恢復查詢；hostd 重啟後這份狀態消失，Core 會把「參與者不記得」視為「未生效」再以 readback 驗證。

## 5. 健康檢查與交接（G1-HOST-05）

| 契約 | 形狀 | 預設 |
| --- | --- | --- |
| 健康檢查 | `ctx.ditto.lifecycle.health(async (signal) => HealthReport)`；未宣告者以「fiber 進入 `ACTIVE` 且 `apply` 未拋錯」判定 | 逾時 2 秒 |
| drain | `ctx.ditto.lifecycle.onDrain(async (signal) => void)`：停止接受新工作並等候進行中的工作 | 上限 3 秒，逾時進入 cancel |
| export／import | `exportState(): Json` 與 `importState(state: Json)`；只傳資料，大小上限 1 MiB | 未宣告者視為無狀態 |
| 熱換等級 | 由 manifest 的 `hot_swap` 宣告，Core 取「宣告值」與「變更類型推導值」的較高者 | — |

交接只傳資料。舊實例的 Context、閉包與物件都不交給新實例（C11）。

## 6. 服務插件 ①：任務／待辦資料服務（G1-HOST-06）

`milestones/01/03` 的備案要求這兩個插件「不能是示範玩具」。本計畫把那條要求寫成可檢查的條件：

| 條件 | 做法 |
| --- | --- |
| 真實資料來源 | 使用者經插件中心選擇一個 `todo.txt` 格式的檔案，產生 `files:<grant>` 授予；插件只能讀寫這個檔案。另有插件自己的清單，存在 `ctx.ditto.data` |
| 真實事件 | 檔案以 `fs.watch` 監看（包在 `ctx.effect()` 內）；外部編輯器修改檔案後 2 秒內發出 `tasks/changed` 事件 |
| 有消費者 | Shell 的 `tasks_panel` QML 供應者；`dittoctl tasks list`（第二個 Consumer） |
| 不依賴任何客戶端 | Agent 替身、Shell 都可以死掉，監看與事件照常；重新連上的 Shell 從快照取得最新狀態 |
| 沒授權時誠實 | 沒有檔案授予時只顯示插件自己的清單；若要展示範例資料，UI **明示「示範資料」**（5.4 節：不能冒充真實進度） |
| 撤銷 | 撤銷檔案授予 → 插件停止監看、清空該來源的項目、面板顯示「檔案存取已撤銷」 |

能力：`desktop.tasks.list`、`add`、`complete`、`subscribe`；readback 為 `desktop.tasks.list`。熱換等級為**受控交接**：替換時 drain 寫入佇列，以 export／import 交接未寫出的變更。

## 7. 服務插件 ②：通知策略服務（G1-HOST-07）

| 條件 | 做法 |
| --- | --- |
| 真實輸入 | Core 的 `ditto-system` 接收真實的 `org.freedesktop.Notifications` 呼叫，詢問 `svc.notification_policy` slot 的供應者（[02 §16](02-core-state-and-transactions.md#16-ditto-systemg1-core-17)） |
| 規則 | ① 專注模式（只放行名單內的應用）；② 同一應用 60 秒內超過 3 則即合併；③ 安靜時段（以 IANA 時區保存）；④ 緊急程度 `critical` 一律放行 |
| 設定走配置 | 規則是 Profile 中該 entry 的 `config`；使用者在個人化設定修改 → ChangeSet → hostd 經 loader 的 volatile 路徑熱更新（harness 修改集第 22 項），不重掛插件 |
| 決策有紀錄 | 每個決定（顯示／合併／靜默）寫入計數與最近 100 筆的環形紀錄，`desktop.notifications.policy_status` 可查 |
| 不依賴任何客戶端 | Agent 替身、Shell 死掉時照常決策；Shell 重連後看到期間累積的通知 |
| 失敗時 | 逾時或宿主不可用 → Core 照常顯示並標示「通知規則暫不可用」（見 02 §16 的理由） |

能力：`desktop.notifications.policy.decide`（僅供 Core 內部呼叫，`resource_scope` 限 `core`）、`policy.get`。熱換等級為**受控交接**。

## 8. `host-sdk`（G1-HOST-08）

MOD-08 要求：manifest 驗證、服務範例、QML 掛載、命令、測試宿主與救援 CLI。

| 交付 | 內容 |
| --- | --- |
| 型別與 helper | `defineDittoPlugin`、`ctx.ditto.*` 的型別、能力定義 helper（schema 由 schemastery 或 Standard Schema 提供，**但跨程序契約以 manifest 宣告並由 Core 驗證**） |
| manifest 驗證 | `ditto-plugin validate`：依 `schema/manifest.json` 驗證；檢查 `provides` 中每項能力都有 handler、每個跨程序事件都有 schema |
| 打包 | `ditto-plugin pack`：tsdown 單檔 bundle → `.dittopkg`，輸出 sha256 |
| 測試宿主 | `createTestHost()`：程序內的 Cordis ＋ 假 Core（實作 participant 方法、租約、授權表），可注入斷線、逾時、拒絕。L-01～L-10 與插件作者的測試都用它 |
| 範例 | 一個最小服務插件（計數器服務＋事件）與一個 QML 供應者範本 |
| 命令 | 插件以 manifest 宣告命令，Core 統一註冊到 `desktop.commands`，衝突在預檢擋下 |
| 救援接點 | manifest 可宣告 `rescue.disable_safe`；`dittoctl rescue disable <entry>` 只處理 Profile，不需要插件程式碼參與 |

## 9. Manifest 完整語意（G1-HOST-09）

PRD 12 節列出的必要語意逐項落地。**「強制」**表示 Core 在預檢或執行期依它做決定；**「記錄」**表示 G1 只保存與顯示，決策在後續階段。

| 欄位 | G1 | 說明 |
| --- | --- | --- |
| `id`、`version`、`name`、`author`、`license`、`source` | 強制／記錄 | 插件中心顯示（MOD-01）；契約獨立於顯示名稱與翻譯 |
| `plugin_kind` | 強制 | `service` \| `qml_provider` \| `declarative_bundle` |
| `host_kind` | 強制 | `cordis` \| `qml` \| `core_builtin`；與 `plugin_kind` 不相容時拒絕 |
| `trust_level` | 強制（上限由政策決定） | 宣告只是請求；G1 只接受內建目錄的 `trusted` 套件 |
| `runtime`（Node／Qt 範圍）、`platform` | 強制 | 不相容即 `protocol_incompatible`／`precondition_failed` |
| `required_protocol_version` | 強制 | EX1-02 的負例之一 |
| `provides`／`requires`／`optional`／`conflicts` | 強制 | 預檢 5～9 |
| `entry`、`qml_entry` | 強制 | 相對於套件根 |
| `config_schema`、`data_schema` | 強制／記錄 | `data_schema` 的遷移在 G3 使用 |
| `commands`、`shortcuts`、`events` | 強制 | 衝突在預檢擋下；跨程序事件必須有 schema 與 `coalesce` 政策 |
| `permissions` | 強制（請求） | 對應 `resource_scope`；最終由政策與授予決定 |
| `hot_swap` | 強制 | 四等級之一 |
| `health`、`cleanup` | 強制 | 健康檢查逾時、清理逾時 |
| `migrations` | 記錄 | G3 使用 |
| `activation_events` | 記錄 | G1 一律在啟用時載入；延遲載入於 G4 依量測決定 |
| `idle_policy` | 強制 | `resident` \| `on_demand`；**與 Agent 的 5 分鐘規則無關** |
| `resource_budget` | 記錄＋比對 | 宣告只是請求；超過政策上限在預檢擋下 |

## 10. 資源回報（G1-HOST-10）

RUN-08：插件中心顯示宿主、啟動原因、活動工作與資源；**同程序插件不得冒充精確獨立 RSS**。harness 沒有這項能力，要自建：

| 層級 | 數字 | 來源 |
| --- | --- | --- |
| hostd 程序 | PSS、RSS、CPU、執行緒、fd | Core 讀 `/proc/<pid>/`（不信任 hostd 自報） |
| Node 堆積 | `heapUsed`、`external`、`arrayBuffers` | hostd 以 `process.memoryUsage()` 經 `host.resources` 回報；**三者分列、不相加、不與 PSS 相加**（NFR-15） |
| 每個 entry | fiber 狀態、`EffectMeta` 標籤數、活躍計時器數、訂閱數、已註冊能力數、啟動原因 | hostd 由 `fiber.getEffects()` 與交易層狀態彙整 |
| 每個 entry 的記憶體 | **不提供數字**；插件中心顯示「與 N 個插件共用宿主，無法單獨計量」 | RUN-08 |

## 11. 回收政策（G1-HOST-11）

hostd 只有在以下四件事**同時**成立時才由 Core 回收：沒有啟用中的 `host: cordis` 條目、沒有活躍訂閱、沒有排程工作、沒有有效租約。**hostd 自己從不因閒置而退出**；Agent 的 5 分鐘閒置規則不適用於它（RUN-03 註、原則 2）。

G1 的預設 Profile 有兩個常駐服務，所以 hostd 在正常桌面中不會被回收。回收路徑仍要實作並測試（停用兩個服務後 hostd 在 30 秒內被回收；重新啟用後重建），因為 G4 的資源報告要能分列「沒有啟用服務」的狀態。

## 12. vendor 同步守門與移植紀錄（G1-HOST-12）

- `scripts/check-vendor-manifest.sh`：比照 harness 同名腳本。`packages/host-runtime/vendor/*/src/` 有變更而 `vendor/README.md` 沒有變更時失敗。在 `node.yml` 執行。
- `docs/upstream/cordis-port.md`：`milestones/01/02 §5` 的七欄移植紀錄，每個 vendored 套件一節；`port_kind` 全部為「直接沿用」或「修改移植」（有 Ditto 修改集者）。
- 同步程序比照 harness：記錄上游 commit → 複製 `src/` → 重新套用或放棄本地修改並更新紀錄 → 更新鎖定表 → 跑 L-01～L-10 與全部 host-runtime 測試。
- G1 期間**不主動同步**上游。只有在修復阻斷缺陷時同步，並走 `ditto-upstream-port`。

## 13. G1 的禁則

1. hostd 不保存任何條目、設定或 Profile 到磁碟。
2. 交易層以外的程式碼不呼叫 `ctx.loader.create/update/remove`。
3. 候選不取得正式獨占資源。
4. 不把 `ctx.isolate` 描述成隔離或安全邊界。
5. 不為任何插件開新的 Node 程序或 Worker（RUN-02、NFR-14）。
6. 不在文件中把交易、租約、回復描述成 Cordis 既有能力（`milestones/01/02 §2.4`）。

## 14. 測試

| 層 | 內容 | 跑在哪 |
| --- | --- | --- |
| 單元 | 租約表、事件佇列與合併、模組解析拒絕、manifest 驗證 | PR 快檢 |
| 生命週期契約 | L-01～L-10，以 `createTestHost()` 與故障注入層 | PR 快檢＋nightly |
| Cordis 行為釘選 | 對 Ditto 依賴的修改集第 6／20／22 項各寫一個釘選測試，參考 harness `packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts` 的案例 | PR 快檢；同步上游時必跑 |
| 服務插件 | 檔案監看、授予撤銷、規則計算、volatile 熱更新 | PR 快檢 |
| 整合 | 真 Core、真 hostd、真 Shell | 參考機 nightly |
