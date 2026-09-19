# 02｜Cordis 沿用範圍、橋接設計與契約測試

PRD 15.6 要求實作來源必須列出「直接沿用 Cordis」「新增 Ditto 橋接」「Rust 原生能力」與「尚未支援」的對照，並於 G1 交付生命週期契約測試。本文是該對照表與其設計。

## 1. 來源與版本鎖定

**決策建議：沿用 `deepseek-harness` 的 vendored fork，而非上游 `cordiverse/cordis`。**

| 項目 | 值 |
| --- | --- |
| 套件 | `@deepseek-ai/cordis` 4.0.2（上游 `cordis` 4.0.0-rc.7） |
| 上游 commit | `56b3d4f725681cf4556c1a8695a709cc3b6eed74`（`cordiverse/cordis`，`packages/core`） |
| 配套 | `cordis-plugin-{loader,include,group,timer,hmr,logger-console}`、`cosmokit` 1.8.1、`schemastery` 3.18.0 |
| 授權 | MIT，各套件目錄保留上游 LICENSE |

理由：

1. **上游 API 尚未穩定**（4.0.0-rc）。PRD 24.2 已把「依浮動版本上線」列為風險，要求固定 commit。
2. **fork 已修復可重入卸載缺口**（`vendor/README.md` 第 6 項）：effect 的擁有者包裝在 setup 執行前註冊、同步 setup 失敗回滾已收集的 cleanup、`UNLOADING` 期間拒絕建立新 effect、子 fiber 在 `internal/plugin` 發布前取得父擁有的 disposer、teardown 通知失敗逐觀察者隔離。**這些正是 Ditto 交易式卸載與回復所依賴的性質**，自行從上游重新修復不划算。
3. **第 15 項 lazy config 解析**與第 20 項 fiber 身分修正，直接影響「更新供應者與消費者時消費者不被困在 PENDING」——對應 AT-31。
4. fork 的 `logger.ts` exporter disposal 修正（第 21 項）避免移除較早 exporter 時誤刪較晚者，對診斷可靠性有直接影響。

**取用方式**：以 vendored 方式複製進 Ditto 倉庫（`packages/host-runtime/vendor/`），記錄上游 repo、commit、版本與 Ditto 自身的修改集，維持與 Harness 相同的同步程序。Ditto 的修改集必須逐條可查（第 24.1 節的來源義務）。

**不採用的部分**：`@deepseek-ai/cordis-plugin-include`（檔案回寫路徑）不進產品執行期——配置權威在 Core。`hmr` 僅開發期使用。

## 2. 沿用對照表

### 2.1 直接沿用 Cordis

| 機制 | Ditto 用途 | 約束 |
| --- | --- | --- |
| 函式／物件／`Service` 三種插件形態 | 桌面服務插件的作者介面 | 服務名稱共用扁平命名空間，Ditto 服務一律加 `ditto` 前綴或命名空間 |
| `Context` 與 `ctx.<key>` 服務查找 | 宿主內能力消費，不 import 實作 | Context **不跨程序傳送**，也不等於安全權限（C11） |
| `inject` 依賴宣告與載入後追蹤 | 宿主內的依賴就緒與供應者替換 | 跨宿主依賴由 Rust 預檢，不由 `inject` 表達 |
| `ctx.effect()` 與可逆註冊 | 插件撤除時釋放所屬監聽與註冊 | 釋放註冊 ≠ 撤銷已發生的外部副作用 |
| Fiber 狀態機與 `ctx.registry` 列舉 | 插件中心的宿主狀態、啟動原因與診斷（MOD-01、REC-07） | 同程序插件不得冒充精確獨立 RSS（RUN-08） |
| 五種事件分發模式 | 宿主內事件契約 | 跨程序事件另定非同步、順序、背壓與斷線語意，不假裝遠端呼叫是同步本地方法 |
| `waterfall` 環繞中介軟體 | 權限應答、策略攔截、變更裝飾 | 僅觀察或標註的監聽器**必須呼叫 `next()`**；不呼叫即為有意短路 |
| `ctx.isolate` 服務隔離 realm | 同一宿主內不同 Profile 區段看到不同供應者實例 | **不是安全邊界**；未信任程式仍需程序隔離 |
| schemastery config schema | 插件設定驗證與預設值補齊 | 能力契約的權威 schema 仍在 Rust（見 [01 §2.2](01-architecture.md#22-型別單一事實來源)） |
| `id`-keyed 條目差異語意 | ChangeSet 對插件樹的差異表達 | 每個條目必須有穩定 `id`，否則任何編輯都變成刪除再新增 |

### 2.2 新增 Ditto 橋接

| 橋接 | 解決的缺口 | 對應需求 |
| --- | --- | --- |
| `ditto-host-loader` | 以 Core 推送的條目列表取代 file-based Include；補上交易式套用 | CHG-02、CHG-04、RUN-11 |
| 能力註冊代理（`ctx.ditto.capabilities`） | 把宿主內註冊發布為跨宿主能力，附擁有者與租約 | RUN-11、15.6 |
| 租約與撤銷協定 | 宿主故障後跨宿主註冊失效並可重建 | RUN-11、RUN-12 |
| 事件橋（seq／快照／背壓） | Cordis 型別化事件 ↔ RPC 事件流 | 15.2、RUN-07 |
| 健康檢查契約 | 候選插件取得正式獨占資源前的就緒判定 | CHG-02 |
| 交接協定（drain／cancel／handoff） | 受控交接等級的熱換 | CHG-03、14.2 |
| Core-backed `SessionPersistence` 提供方 | 會話儲存與 Agent 程序分離 | 第 13 節、RUN-04 |
| Core-backed settings 提供方 | 使用者設定寫入即產生 revision | CFG-05 |
| Keyring credentials 提供方 | 秘密以引用存取，不進 Profile | SEC-07 |
| 資源回報適配 | 宿主與插件的 PSS／CPU／程序數上報 | RUN-08、NFR-15 |

### 2.3 Rust 原生能力（不經 Cordis）

配置 revision 與譜系、權限授予與撤銷、能力綁定與路由、ChangeSet／Operation 協調與提交、快照與回復、宿主監督與重啟風暴偵測、合成器與系統轉接、秘密引用解析的授權判定、救援模式與 `dittoctl`、資源配額（cgroup）施加。

### 2.4 尚未支援（明確不承諾）

上游 Cordis **不提供**：桌面交易、跨程序沙箱、配置回復、跨宿主租約、熱換等級語意、資源預算施加。任何文件或說明都不得把這些寫成「Cordis 已提供」。

## 3. `ditto-host-loader` 設計

### 3.1 問題

上游 loader 的條目／群組／樹變更是 **eager、非交易式**的，失敗不還原先前的插件與選項（`vendor/README.md` 第 8 項）。Ditto 的 CHG-02／CHG-04 要求「候選先健康檢查、失敗自動回復」，兩者不相容。

### 3.2 兩階段套用

Core 與 hostd 之間的一次替換：

```
1. Core   → host.prepare(change_id, base_revision, entries[])
             hostd 建立候選 Context（isolate realm），掛載新／變更條目
             舊條目維持 ACTIVE，候選不註冊正式能力
2. hostd  → 回報 per-entry 結果：ready | failed(reason) | pending(missing_service)
             Core 驗證所有 required 條目 ready，否則 host.abort(change_id)
3. Core   → host.commit(change_id)
             舊供應者 drain／cancel／handoff（依熱換等級）
             候選發布正式能力，取得租約
             舊條目 dispose（等待所有 disposer 完成）
4. Core   → 透過 readback 驗證真實狀態；不一致則 host.rollback(change_id)
5. Core   → 提交 revision；或回復並記錄部分完成範圍
```

設計要點：

- **候選不得取得正式獨占資源**（快捷鍵、命令、單一供應者能力）直到 `commit`，避免重複註冊（CHG-03、AT-31）。
- `host.abort` 必須把候選 Context 整棵 dispose，並等待非同步 disposer 完成後才回報，利用 fork 的 `fiber.dispose()` 語意。
- **需要順序的拆解放在同一個 effect 內**（Cordis 的非同步 disposer 併發執行）。交接步驟因此寫成單一 effect 的內部序列。
- `pending(missing_service)` 是合法狀態不是錯誤，但**在 prepare 階段等同未就緒**：Core 有界等待後判定失敗，不無限等待。
- 條目 `id` 由 Core 產生並持久化於 Profile revision，hostd 不自行生成。

### 3.3 能力註冊與租約

```ts
// host-sdk 提供給插件作者的介面（示意）
export const inject = ['ditto']

export function apply(ctx: Context) {
  // 註冊是 effect：插件卸載時自動撤銷本地註冊並通知 Core 撤銷租約
  ctx.ditto.capabilities.register({
    id: 'desktop.tasks.list',
    version: '1.0.0',
    input: Schema.object({ scope: Schema.string().default('today') }),
    output: TaskListSchema,
    readback: 'desktop.tasks.list',
    handler: async (input) => todo.list(input.scope),
  })
}
```

租約規則：

- Core 發放 `lease_id`，附到期時間；hostd 定期續約。
- 宿主崩潰或租約逾期 → Core 立即把該能力標示不可用，進行中的變更停止或補償（RUN-12）。
- 重啟後 hostd 重建依賴與代理；**不得重播已完成的外部副作用**。
- 撤銷後阻止新呼叫，並處理既有訂閱與任務（SEC-04）。

### 3.4 事件橋

- 宿主內事件保持 Cordis 原生語意（五種分發模式）。
- 需要跨程序的事件另行宣告，附 `seq`、`revision`、佇列上限與丟棄策略。
- 訂閱方重連：先取快照 → 再補 `seq` 之後的事件；佇列溢位時回報「需要重新快照」而非靜默丟失。

## 4. G1 生命週期契約測試清單

PRD 15.6 指定涵蓋五類情境。以下為必須通過的測試項，對應 AT-30／31／32。

| # | 情境 | 期望行為 |
| --- | --- | --- |
| L-01 | 依賴消失：卸載供應者插件 | 消費者自動卸載並釋放註冊；Core 標示相關能力不可用；供應者恢復後消費者重新載入 |
| L-02 | 服務替換：以另一實作替換同名服務 | 所有 `inject` 該服務的插件重新啟動並使用新實作；無孤兒註冊 |
| L-03 | 重複註冊：候選與現役同時宣告同一單一供應者能力 | 候選在 `commit` 前不得發布；`commit` 後只有一個正式供應者；快捷鍵與命令無重複 |
| L-04 | Context 撤除：反覆掛載與撤除同一 realm 100 次 | 無殘留註冊、無殘留訂閱、穩態 PSS 中位數增幅 ≤10% 且不單調成長（NFR-07） |
| L-05 | 跨宿主斷線：prepare 後終止 hostd | Core 判定變更失敗並回復；能力即時標示不可用；合成器與救援持續可用 |
| L-06 | 交接階段終止 hostd | 變更有明確結果（部分完成範圍可列出）；恢復服務不重播副作用 |
| L-07 | 租約逾期不續約 | Core 撤銷能力綁定；後續呼叫拒絕；hostd 重連後重新註冊取得新租約 |
| L-08 | 非同步 disposer 未完成即再次掛載 | 第二次掛載等待前次清理完成；不出現兩個實例並存 |
| L-09 | prepare 期間使用者手動改同一項配置 | 基底 revision 過期，變更被拒並要求重新規劃（CFG-06、AT-10） |
| L-10 | Agent 程序終止（受理前／受理後各一次） | 受理前不執行；受理後由 Core 協調完成或回復；重連查真實結果（AT-28） |

測試宿主：Vitest（TS 側）＋ Rust 整合測試，另加故障注入層（可在指定階段終止程序、延遲回應、丟棄訊息）。

## 5. 移植紀錄要求

每個從 Harness 移植的套件必須記錄（第 9 節、AT-18）：

```
package            上游套件名與版本
upstream_commit    固定 commit
port_kind          直接沿用 | 薄轉接 | 修改移植 | 保留外部宿主
modifications      修改摘要（逐條）
host_contract      執行於哪個宿主、信任等級
license            授權與 NOTICE 義務
test_matrix        對應測試與實際結果
```

MVP 驗證三類上游能力（第 9 節）：**模型適配器**（`ctx.llm` seam）、**工具**（`ctx.tools` 與執行流水線）、**會話**（`SessionPersistence`）。具體套件清單由 G0／G1 盤點決定並寫回本文件。

## 6. 禁止事項

- 不得為追求單一語言而把已可沿用的 Cordis 插件重寫為 Rust（15.6）。
- 不得讓 Cordis 自行寫入第二份正式 Profile。
- 不得把 `ctx.isolate`、Node Worker 或 `node:vm` 當作 OS 安全沙箱（15.3）。
- 不得在文件中把 Ditto 新增的桌面交易、跨程序沙箱或配置回復描述為 Cordis 既有能力。
- 不得依浮動版本上線；每次同步更新 commit、版本與修改集紀錄。
