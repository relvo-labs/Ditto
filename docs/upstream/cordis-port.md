# Cordis 移植紀錄（ditto-hostd）

| 欄位 | 內容 |
| --- | --- |
| 狀態 | G1-HOST-01／12 實作中。本文記錄 2026-09-27 工作樹的事實；D-04（取用決定）仍待核定 |
| 權威 | 修改紀錄以 [packages/host-runtime/vendor/README.md](../../packages/host-runtime/vendor/README.md) 為準；本文是 `milestones/01/02 §5` 要求的逐套件移植紀錄與沿用對照 |
| 相關 | [plan/03/03](../../plan/03/03-host-and-cordis.md)、`ditto-upstream-port`、`ditto-cordis-plugin`、D-32 |

## 1. 逐套件移植紀錄

五個套件共用的欄位：

- **upstream_repo／upstream_commit**：先經 DeepSeek Harness（commit `477b4f420553e8a52c2fbccc464d7561b239c443`）的 vendored fork；fork 自己的上游見各列。
- **port_kind**：全部為**直接沿用**。Ditto 修改集為空，需要的行為都以 vendor 目錄之外的薄轉接完成（vendor/README.md §4 的 A1～A5）。
- **host_contract**：只在 `ditto-hostd`（Node 22.23.2，一個程序，`ditto-hostd.scope`）內執行；由 Core 經受控啟動器啟動，不自行讀取任何條目來源。
- **trust_level**：vendored 程式碼本身是 hostd 的一部分。它承載的插件是「可信 TS 桌面服務插件，同宿主、無隔離」；`ctx.isolate` 與 loader 的 `isolate` 選項只是服務可見範圍，**不是**隔離或安全邊界。
- **license**：MIT，Copyright (c) 2021-present Shigma。各目錄保留 `LICENSE`；hostd bundle 與內含 vendored 程式碼的插件 bundle 開頭帶這份授權文字（`packages/host-runtime/scripts/notice.mjs`）。沒有 NOTICE 檔義務。

| package | 上游名稱與版本（harness release） | upstream_commit | modifications | test_matrix（2026-09-27 開發機實際結果） |
| --- | --- | --- | --- | --- |
| `@deepseek-ai/cordis` | `cordis` 4.0.0-rc.7（4.0.4） | cordiverse/cordis `56b3d4f725681cf4556c1a8695a709cc3b6eed74` | harness 修改集第 2、4、6、7、10、15、16、17、21、22 項（逐條見 vendor/README.md §2）；Ditto：無 | 釘選：第 6 項 5 例、第 20 項 1 例、第 22 項 1 例、`FiberState` 鏡像 2 例，全數通過；生命週期 L-01～L-04、L-08 共 13 例通過（兩種候選策略各跑一次） |
| `@deepseek-ai/cordis-plugin-loader` | `@cordisjs/plugin-loader` 1.0.0-rc.5（1.0.5） | cordiverse/cordis `56b3d4f725681cf4556c1a8695a709cc3b6eed74` | 第 2、4、7、8（非交易式的明文）、10、12、15、17、18、19、20、22 項；Ditto：無 | 同上；另有 volatile 熱更新（通知策略服務）與交易層 prepare／commit／abort／rollback 的單元測試 |
| `@deepseek-ai/cordis-plugin-timer` | `@cordisjs/plugin-timer` 1.1.2（1.1.6） | deepseek-harness/cordis `abb0a307cb1d3b0947f455d590cf5ba922d4caa4` | 第 2、17 項；Ditto：無 | 由 hostd 在根 Context 掛上（`ctx.timeout`／`ctx.interval` 是 effect）；L-04 的計時器計數經 `host.entry_state` 回報 |
| `@deepseek-ai/cosmokit` | `cosmokit` 1.8.1（1.8.5） | deepseek-harness/cosmokit `16f6fc058ade66e8ac5da0033d35a8d0f279f544` | 第 2、17、22 項；Ditto：無 | 經 cordis／loader 的測試間接覆蓋；volatile 參照跨 bundle 以 `Symbol.for` 辨識（通知策略服務的 bundle 帶自己的副本仍能熱更新，已測） |
| `@deepseek-ai/schemastery` | `schemastery` 3.18.0（3.18.4） | deepseek-harness/schemastery `e67cee00ad725bd1534aee930a979ea3eec6f698` | 第 2、10、17、22 項；Ditto：無 | 釘選第 22 項；通知策略服務的設定 schema |

`milestones/01/02 §1` 的版本數字（cordis 4.0.2、cosmokit 1.8.1、schemastery 3.18.0）是較早的盤點；harness `477b4f4` 的實際 release 是上表的 4.0.4／1.8.5／3.18.4（cosmokit 與 schemastery 的 1.8.1／3.18.0 是**上游**版本）。本文與 vendor/README.md 以重新核對後的值為準，`milestones/` 的更正留給該文件的 owner。

**沒有取用**：`cordis-plugin-include`（檔案回寫，配置權威在 Core）、`cordis-plugin-hmr`（chokidar／esbuild，不進產品）、`cordis-plugin-logger-console`（hostd 自己輸出 JSON 到 stderr）、`cordis-plugin-group`（D-32 策略 A 不需要）。

## 2. 沿用對照表的更新（對應 milestones/01/02 §2）

下列是以實際實作對照 `milestones/01/02 §2` 四欄的更新內容，附檔案位置。`milestones/` 由該文件 owner 回寫，本文不代改。

### 2.1 直接沿用 Cordis

| 機制 | 實際用在哪裡 |
| --- | --- |
| 物件／函式／`Service` 插件形態 | 插件模組的匯出（`packages/host-sdk/src/index.ts` 的 `defineDittoPlugin` 只是加上 `inject: ['ditto']` 的恆等函式）；`ditto` 服務本身是 `Service`（`packages/host-runtime/src/ditto-service.ts`） |
| `inject` 與依賴追蹤 | 服務消失時消費者轉 `PENDING`、恢復後重新載入（L-01、L-02） |
| `ctx.effect()` 與可逆註冊 | 能力註冊、事件訂閱、撤銷監聽、生命週期鉤子全部是 effect（`ditto-service.ts`）；插件的計時器與 `fs.watch` 同樣（`packages/plugins/svc-tasks/src/index.ts`） |
| Fiber 狀態與 `getEffects()` | `host.entry_state` 的 `fiber_state`、`waiting_for` 與 effect／計時器計數（`packages/host-runtime/src/resources.ts`）；`FiberState` 以鏡像讀取（`src/fiber-state.ts`） |
| `fiber.dispose()` 等所有 disposer 完成（修改集第 6 項） | `participant.abort` 與 commit 的「等清理完成」（`src/loader/transaction.ts` 的 `dispose()`） |
| loader 的 id 鍵條目樹與 `isolate` 條目選項 | 條目 id 由交易層以 Core 的 `entry_id` 衍生；策略 A 的候選以共用 `GlobalRealm` 標籤的 isolate 掛載 |
| volatile config（修改集第 22 項） | 只改 `.volatile()` 欄位的 config 在原 fiber 內提交，不重掛（通知策略服務的規則） |
| `internal/status`、`internal/get` 事件 | 交易層等待 fiber 狀態、`ctx.loader` 絆線（`src/runtime.ts`） |

### 2.2 新增 Ditto 橋接（全部不是 Cordis 既有能力）

| 橋接 | 位置 | 測試 |
| --- | --- | --- |
| 交易層 `ditto-host-loader`（prepare／commit／abort／rollback／state，以 `change_id` 為鍵） | `packages/host-runtime/src/loader/transaction.ts` | `tests/lifecycle/`、`tests/unit/policy-and-bridge.test.ts` |
| 候選策略 A `isolate_rebuild`（預設）／B `in_place`（僅試作） | 同上；D-32 提案 | 兩種策略各跑全套 |
| 模組解析政策（只載入 Core 推送、位於套件庫下的路徑） | `src/loader/module-policy.ts` | `tests/unit/policy-and-bridge.test.ts` |
| `ditto` 根服務（能力、事件、資料區、權限、生命週期、mode） | `src/ditto-service.ts`、`src/api.ts`、`src/data-area.ts` | 同上與兩個服務插件的測試 |
| 能力註冊代理與租約（批次續約、逾期重新註冊、新租約 id） | `src/leases.ts` | `tests/unit/leases.test.ts`（含 L-07 的 hostd 側） |
| 事件橋（每 entry 佇列 256、`latest` 合併、溢位送一次 resync） | `src/events.ts` | `tests/unit/events.test.ts` |
| 健康檢查、drain、export／import 交接 | `src/loader/transaction.ts`（`health`、`handOff`、`bringUp`） | 交接與回復的單元測試；svc-tasks 的受控交接測試 |
| 資源回報（`heap_used`／`external`／`array_buffers` 分列，無每插件記憶體） | `src/resources.ts` | `tests/unit/policy-and-bridge.test.ts` |
| Core 連線（雙向 JSON-RPC、握手、`host.hello`、心跳） | `src/bridge/`、`src/main.ts` | `tests/process/hostd-process.test.ts`（真程序） |
| 測試宿主 `createTestHost()` 與假 Core | `src/testing/`，由 `@ditto/host-sdk/testing` 匯出 | 所有生命週期與插件測試 |

### 2.3 Rust 原生能力（不經 Cordis）

hostd 依賴、但由 Core 持有的：條目表與 `on_behalf_of` 驗證、租約 TTL 與單一供應者、授權（`desktop.permissions.check`；hostd 只把 `effective: allowed` 當成允許）、`files:<grant>` 的路徑（隨條目投影的 `file_grants` 送達，hostd 只放在記憶體、撤銷時先刪除）、資料區路徑分配、事件 broker 與 `seq`、readback、hostd 監督與回收。hostd 端沒有這些狀態的第二份，也不寫進磁碟。

### 2.4 尚未支援（不承諾）

跨程序沙箱、插件逐一記憶體計量（同程序，無法單獨計量）、候選升格（Cordis 沒有這個操作；策略 A 以重建代替，commit 時仍有短暫空窗）、`desktop.events` 的取消訂閱（協定尚無此方法，hostd 只在本地丟棄）。

## 3. 授權清單

### 3.1 vendored 套件

| 套件 | 版本 | 授權 | 版權 |
| --- | --- | --- | --- |
| `@deepseek-ai/cordis` | 4.0.4（上游 4.0.0-rc.7） | MIT | 2021-present Shigma |
| `@deepseek-ai/cordis-plugin-loader` | 1.0.5（上游 1.0.0-rc.5） | MIT | 2021-present Shigma |
| `@deepseek-ai/cordis-plugin-timer` | 1.1.6（上游 1.1.2） | MIT | 2021-present Shigma |
| `@deepseek-ai/cosmokit` | 1.8.5（上游 1.8.1） | MIT | 2021-present Shigma |
| `@deepseek-ai/schemastery` | 3.18.4（上游 3.18.0） | MIT | 2021-present Shigma |

### 3.2 本工作流新增的 npm 依賴

全部鎖定精確版本，並寫入 `pnpm-lock.yaml`。沒有任何一個進入 hostd 或插件的執行期 bundle：hostd bundle 只含 Ditto 程式碼與上表的 vendored 程式碼。

| 套件 | 版本 | 授權 | 用途 | 進入執行期？ |
| --- | --- | --- | --- | --- |
| `tsdown` | 0.22.2 | MIT | hostd、插件與 `ditto-plugin` CLI 的打包（`pack` 在執行期呼叫它，所以是 host-sdk 的 dependency） | 否（建置工具） |
| `rolldown`（tsdown 的依賴） | 1.1.5 | MIT | 同上 | 否 |
| `@standard-schema/spec` | 1.1.0 | MIT | vendored 原始碼與 `api.ts` 的型別匯入 | 否（只有型別） |
| `typescript`、`vitest`、`@types/node` | 5.9.3、3.2.4、22.18.6 | Apache-2.0、MIT、MIT | 與 `@ditto/protocol` 相同版本 | 否 |

`pnpm install` 後整個 workspace 的 npm 套件（含傳遞依賴）共 106 個：MIT 98、ISC 4、Apache-2.0 2、BSD-3-Clause 1、Python-2.0 1，全部是開發期工具。發行時的完整彙整交給 `ditto-release-audit` 與 `licenses.yml`。

## 4. 來源守門

- `scripts/check-vendor-manifest.sh`：`packages/host-runtime/vendor/*/src/` 有變更、而 `packages/host-runtime/vendor/README.md` 沒有變更時失敗。預設比對與 `origin/main` 的 merge base；`--staged` 只看 index；`--working` 另含未暫存與未追蹤檔案。
- `--self-test` 在暫存的 git 倉庫裡重現「只改 vendor 原始碼」被擋下、「同時更新 README」通過、「只暫存 vendor 原始碼」被擋下三種情況；`node.yml` 每次都先跑它，所以 CI 紀錄裡有一次實際擋下的輸出。EX1-14 ③ 要求的「一個故意違規的 PR 被擋下」仍須在 GitHub 上實際開一次，本工作流沒有開 PR。

## 5. hostd 故障注入點（供 Rust 整合測試）

`DITTO_HOST_FAULT=<point>:<action>[:<n>]`（逗號分隔多條）。`point` ∈ `prepare.before`、`prepare.after_mount`、`commit.before`、`commit.after_drain`、`commit.after_dispose`、`abort.before`、`rollback.before`、`lease.renew`、`heartbeat`、`invoke.before`；`action` ∈ `throw`、`hang`、`exit`、`kill`、`delay=<ms>`；`n` 表示只在第 n 次經過時觸發。

- 只有測試建置讀取它：`DITTO_HOST_FAULT_ENABLE=1 pnpm --filter @ditto/host-runtime build` 另外產生 `dist/ditto-hostd-fault.mjs`。
- 正式 bundle 以 `__DITTO_FAULT__=false` 建置，讀取環境變數的模組（`src/fault-enabled.ts`）因此被 tree-shaking 移除；`scripts/build.mjs` 在正式 bundle 仍含 `DITTO_HOST_FAULT`、`DITTO_HOST_STRATEGY` 或 `fault injected` 字串時讓建置失敗。
- 測試建置另接受 `DITTO_HOST_STRATEGY`（D-32 試作用）；正式建置沒有這個開關。
