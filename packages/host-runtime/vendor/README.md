# Vendored Cordis（ditto-hostd）

這個目錄是 `ditto-hostd` 使用的 Cordis 原始碼副本，取自 DeepSeek Harness 的 `vendor/`。取用範圍、理由與宿主契約見 [plan/03/03 §2](../../../plan/03/03-host-and-cordis.md#2-cordis-取用g1-host-01)，逐套件的移植紀錄見 [docs/upstream/cordis-port.md](../../../docs/upstream/cordis-port.md)。

**本檔是修改紀錄的權威。** `packages/host-runtime/vendor/*/src/` 的任何變更都必須在同一個變更中更新本檔（`scripts/check-vendor-manifest.sh` 在 CI 擋下沒有更新本檔的變更）。

## 1. 鎖定表

來源：`deepseek-harness`，commit `477b4f420553e8a52c2fbccc464d7561b239c443`（2026-09-24）。下表的每一格在 2026-09-27 對該 commit 的 `vendor/*/package.json` 與 `vendor/README.md` 逐一重新核對。

| 目錄 | 套件名（保留） | harness release | 上游名稱與版本 | 上游倉庫 | 上游 commit |
| --- | --- | --- | --- | --- | --- |
| `cordis/` | `@deepseek-ai/cordis` | 4.0.4 | `cordis` 4.0.0-rc.7 | https://github.com/cordiverse/cordis（`packages/core`） | `56b3d4f725681cf4556c1a8695a709cc3b6eed74` |
| `loader/` | `@deepseek-ai/cordis-plugin-loader` | 1.0.5 | `@cordisjs/plugin-loader` 1.0.0-rc.5 | https://github.com/cordiverse/cordis（`packages/loader`） | `56b3d4f725681cf4556c1a8695a709cc3b6eed74` |
| `timer/` | `@deepseek-ai/cordis-plugin-timer` | 1.1.6 | `@cordisjs/plugin-timer` 1.1.2 | https://github.com/deepseek-harness/cordis（`packages/timer`） | `abb0a307cb1d3b0947f455d590cf5ba922d4caa4` |
| `cosmokit/` | `@deepseek-ai/cosmokit` | 1.8.5 | `cosmokit` 1.8.1 | https://github.com/deepseek-harness/cosmokit | `16f6fc058ade66e8ac5da0033d35a8d0f279f544` |
| `schemastery/` | `@deepseek-ai/schemastery` | 3.18.4 | `schemastery` 3.18.0 | https://github.com/deepseek-harness/schemastery（`packages/core`） | `e67cee00ad725bd1534aee930a979ea3eec6f698` |

每個目錄只複製 `src/`、`LICENSE`、`README.md`、`package.json`，內容與 harness 該 commit 逐位元相同（複製後以 `diff -r` 比對）。**沒有**複製：`tsconfig.json`（指向 harness 根目錄的 `tsconfig.base.json`）、`tsdown.config.ts`（harness 自己的建置外形，修改集第 5 項）、`cordis/bin.js`（CLI，hostd 不用）。

**不取用**：`cordis-plugin-include`（檔案回寫路徑；配置權威在 Core）、`cordis-plugin-hmr`（依賴 chokidar／esbuild，不進產品執行期）、`cordis-plugin-logger-console`（hostd 以自己的 exporter 輸出 JSON）、`cordis-plugin-group`（D-32 策略 A 用 loader 的 `isolate` 條目選項承載候選，不需要群組）。

vendored 原始碼唯一的第三方依賴是 `@standard-schema/spec` 1.1.0，而且只有型別匯入（`import type`），執行期不存在；它列在 `@ditto/host-runtime` 的 devDependencies。

### 工具鏈鎖定（與 vendored 原始碼一起核定）

| 項目 | 版本 | 用途 |
| --- | --- | --- |
| Node | 22.23.2 | Ditto 凍結版本（D-03）；harness 根 `engines` 為 `^22.19.0 \|\| >=24.0.0`，相容 |
| pnpm | 10.11.0 | Ditto 凍結版本；harness 用 11.7.0，本目錄沒有引入 pnpm 11 專屬語法 |
| tsdown | 0.22.2（解析到 rolldown 1.1.5） | 把 hostd 打包成單一 ESM 檔 `dist/ditto-hostd.mjs`；與 harness 鎖定的版本相同 |
| TypeScript | 5.9.3 | 型別檢查；vendored 原始碼以 `tsconfig.vendor.json` 只輸出宣告檔（見 §3） |
| Vitest | 3.2.4 | 測試；與 `@ditto/protocol` 相同 |

## 2. harness 修改集（22 項，照錄摘要）

原文在 harness `vendor/README.md` 的 “Local modifications”（commit `477b4f4`）；以下逐項摘要，並標出**在本副本中是否存在**。本副本沒有撤銷或改寫其中任何一項。「Ditto 直接依賴」一欄取自 plan/03/03 §2.2。

| # | 內容摘要 | 本副本 | Ditto 直接依賴 |
| --- | --- | --- | --- |
| 1 | `hmr/src/index.ts` 移除 YAML locale 匯入與 `.i18n()` | 不存在（未取用 hmr） | |
| 2 | 所有 `package.json` 為 harness 發布重新產生（範圍名、release 版本、`workspace:~`、files 清單） | 存在（`package.json` 照抄，但**不是** Ditto workspace 成員，見 §3） | |
| 3 | 所有 `tsconfig.json` 改為延伸 harness 根設定 | 不存在（未複製 tsconfig） | |
| 4 | vendored 原始碼的相對匯入改成明確的 `.ts` 規格 | 存在 | |
| 5 | `schemastery`／`logger-console` 的 `tsdown.config.ts` | 不存在（未複製） | |
| 6 | `cordis/src/fiber.ts` 生命週期強化：effect 擁有者包裝先於 setup 註冊、同步 setup 失敗回滾、`UNLOADING` 期間拒絕新 effect、子 fiber 發布前取得父擁有的 disposer、teardown 通知失敗逐觀察者隔離 | 存在 | **是**（釘選：`tests/pinning/cordis-modifications.test.ts`） |
| 7 | Cordis 與 Loader 的 JSDoc 補充（只改註解） | 存在 | |
| 8 | `include/src/index.ts` 檔案刷新；**明文記載 loader 的條目／群組／樹變更是 eager、非交易式，失敗不還原** | include 不存在；該行為在 loader 中存在 | **是**（交易層存在的理由，plan/03/03 §4.1） |
| 9 | `hmr` 監看就緒與原生路徑 | 不存在 | |
| 10 | 標明型別匯入，讓 Node 原生 TS 轉換不要求型別匯出；schemastery 為 ESM | 存在（cordis、loader、schemastery 部分） | |
| 11 | `include` 的 patch 語意抽成 `applyEntryPatches` | 不存在 | |
| 12 | `loader/src/config/entry.ts` 啟用觀察者處理兩種結果、fiber 保留啟用錯誤 | 存在 | |
| 13 | `include` 的 `writeTask` 型別 | 不存在 | |
| 14 | `include` 的持久化寫入 | 不存在 | |
| 15 | Lazy config 解析（移植 cordiverse/cordis#41）：注入就緒後才解析 raw config；替換供應者時重新解析 | 存在（cordis、loader 部分） | **是** |
| 16 | `cordis/package.json` 發布 `src` | 存在 | |
| 17 | `@deepseek-ai` 改名 | 存在（套件名保留，見 plan/03/03 §2.3） | |
| 18 | 條目 `disabled` 在每次掛載時重新求值（可為 `!!js`） | 存在；Ditto 只推送布林值 | **是** |
| 19 | `loader/src/internal.ts` 依 API 形狀而非 Node 主版本判斷內部 loader | 存在；hostd 另以模組政策取代 `loader.internal`（§4 A2） | |
| 20 | `loader/src/config/entry.ts` 保存真實 fiber（不是 PromiseLike 包裝），同時更新供應者與消費者時消費者不會卡在 PENDING | 存在 | **是**（釘選） |
| 21 | `cordis/src/logger.ts` exporter disposal 以註冊 id 移除 | 存在 | **是** |
| 22 | Volatile config（cosmokit／schemastery／cordis／loader）：`.volatile()`、只改 volatile 欄位時不重掛、發出 `loader/volatile-update` | 存在 | **是**（釘選；通知策略服務的熱更新） |

## 3. 取用方式（不改 vendor 的轉接）

- **以原始碼取用，不作為 workspace 套件。** vendored `package.json` 的 exports 指向未建置的 `lib/`，而且 `cordis` 對 `cordis-plugin-include` 有 `workspace:~` 的選用 peer 依賴；把它們列為 pnpm 10 workspace 成員會因找不到 include 而安裝失敗。改 `package.json` 會新增一項 Ditto 修改，所以不改：Vitest 與 tsdown 以 `vendor-alias.mjs` 把 `@deepseek-ai/*` 對應到 `src/index.ts`。
- **型別檢查分兩層。** vendored 原始碼沿用上游的寬鬆旗標（harness vendor tsconfig 的 `noImplicitAny: false` 等），由 `tsconfig.vendor.json` 只輸出宣告檔到 `vendor-types/`（不進版控）；Ditto 自己的程式碼在完整 strict 下，經 `tsconfig.host-base.json` 的 `paths` 讀那些宣告檔。
- **打包**：`scripts/build.mjs` 以 tsdown 0.22.2 把 `src/main.ts` 與 vendored 原始碼打成單一 ESM 檔，並把 vendored `src/` 的 sha256 指紋寫進 bundle，hostd 在 `host.hello.vendor_fingerprint` 回報。

## 4. Ditto 修改集

**目前為空：vendored 原始碼沒有任何 Ditto 修改。** 需要的行為全部以 vendor 目錄之外的薄轉接完成，逐項列在下面，讓同步上游時知道哪些假設要重新確認。新增真正的修改時從 `D1` 起編號，每條寫明檔案、理由與退場條件。

| 轉接 | 位置 | 依賴的 vendored 行為 | 同步時要確認 |
| --- | --- | --- | --- |
| A1 原始碼別名與宣告檔 | `vendor-alias.mjs`、`tsconfig.vendor.json`、`tsconfig.host-base.json` | 各套件 `src/index.ts` 為入口；loader 的 `src/config/diff.ts` 匯出 `equalExceptVolatile`（loader 的 index 沒有再匯出它，交易層以別名 `@deepseek-ai/cordis-plugin-loader/diff` 取用，確保與 `Entry.update` 用同一個函式） | 入口檔名與 `equalExceptVolatile` 仍在 |
| A2 模組解析政策 | `src/runtime.ts`（`root.loader.internal = { import }`）、`src/loader/module-policy.ts` | `EntryTree.import()` 在 `loader.internal` 存在時只經它匯入 | `EntryTree.import` 的分派順序 |
| A3 `ctx.loader` 絆線 | `src/runtime.ts` 的 `internal/get` 監聽 | Context proxy 對未 inject 的服務走 `internal/get` waterfall | waterfall 名稱與參數 |
| A4 `FiberState` 鏡像 | `src/fiber-state.ts`、`tests/pinning/fiber-state.test.ts` | `FiberState` 的六個數值 | 釘選測試 |
| A5 交易層 | `src/loader/transaction.ts` | `EntryTree.create` 接受呼叫方給的 `id`；`fiber.dispose()` 第一次呼叫回傳等到所有 disposer 完成的 promise（修改集第 6 項）；條目 `isolate` 選項以 `GlobalRealm` 標籤共用 realm | L-01～L-04、L-08 全部 |

## 5. 同步程序

G1 期間**不主動同步**；只有在修復阻斷缺陷時同步，並走 `ditto-upstream-port`。

1. 在 harness 記下新的 commit；逐套件記下新的 release 版本與上游 commit。
2. 複製該套件的 `src/`（以及有變更時的 `LICENSE`、`README.md`、`package.json`）覆蓋本目錄。
3. 對照 §2 更新 harness 修改集的摘要；對照 §4 確認每個轉接的假設仍成立，必要時新增 `D<n>` 修改並寫退場條件。
4. 更新 §1 的鎖定表與 `docs/upstream/cordis-port.md`。
5. 執行 `pnpm --filter @ditto/host-runtime typecheck`、`pnpm --filter @ditto/host-runtime test`（含 L-01～L-04、L-08 與釘選測試）、`pnpm --filter @ditto/host-runtime build`，再跑全 workspace 的 `pnpm -r test`。
6. 以 `scripts/check-vendor-manifest.sh --working` 確認本檔已隨變更更新。
