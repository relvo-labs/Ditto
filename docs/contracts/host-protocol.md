# Core ↔ `ditto-hostd` 協定

| 欄位 | 內容 |
| --- | --- |
| 版本 | 協定 0.2 的一部分（同一條 `core.sock`，同一次握手） |
| 狀態 | 實作中；D-27（連線與身分）、D-32（候選策略）為待決策提案，實作暫採 plan/03 預設值 |
| 相關 | [protocol-0.2.md](protocol-0.2.md)、[manifest.md](manifest.md)、plan/03/03 |

## 1. 啟動與身分

1. Core 在作用中的 Profile 含有已啟用的 `host: cordis` 條目時，經受控啟動器以 kind `hostd` 啟動 `ditto-hostd`，token 經 fd 3 交付，放進 `ditto-hostd.scope`（D-06b 的服務配額；施加失敗就**不啟動**）。
2. hostd 以協定 0.2 握手（`client.kind = "hostd"`），握手回應帶 `host_generation`：每次新連線加一。
3. hostd 呼叫 `host.hello`，回報版本與 vendored 指紋。
4. hostd 建立根 `Context`、掛上交易層與根層級的 `ditto` 服務，然後**什麼都不載入**，等 Core 推送條目。

**hostd 沒有任何磁碟上的條目來源。** 重啟後條目列表是空的；唯一的真相在 Core。

```jsonc
// → host.hello
{ "hostd_version": "0.2.0", "node_version": "22.23.2", "cordis_version": "4.0.4",
  "vendor_fingerprint": "sha256:...", "strategy": "isolate_rebuild" }   // D-32：isolate_rebuild（A）｜in_place（B）
// ←
{ "host_generation": 3, "mode": "normal", "heartbeat_interval_ms": 2000, "lease_ttl_ms": 10000 }
```

## 2. `on_behalf_of`

hostd 連線上的每一個 `desktop.*` 呼叫與 `host.*` 呼叫（`host.hello`、`host.heartbeat`、`host.lease.renew`、`host.resources`、`host.entry_state` 除外）都必須在 `_meta.on_behalf_of` 帶一個 `entry_id`：

- Core 確認該 entry **已分派給這個 hostd 連線**（Core 推送過且目前在該連線的條目表中）→ 主體為 `host:<entry_id>`。
- 否則 → `identity_rejected`。未分派、已移除、屬於另一個 generation 的 entry 都一樣（EX1-06 ⑤）。

同程序插件沒有獨立的程序身分，所以這不是隔離；它是「Core 知道自己把哪個條目交給了誰」的可驗證事實。信任等級如實標示為「可信 TS 桌面服務插件，同宿主、無隔離」。

## 3. 心跳與斷線

- hostd 每 2 秒呼叫 `host.heartbeat {}`；6 秒沒收到 → Core 視同斷線，先 `SIGTERM`、1 秒後 `SIGKILL`。
- 連線中斷 → Core **立即**（≤500 ms，EX1-08）把該 hostd 的所有能力標為 `unavailable`（`host_unavailable`）、撤銷所有租約、對相關訂閱送 `resync_required`；進行中的交易轉回復或補償。
- 重啟退避 1、2、4、8 秒，上限 30 秒；10 分鐘內 5 次 → 停止重啟，能力原因為 `host_crash_loop`。

## 4. 條目推送與交易

Core 以協定 0.2 的 `participant.*` 方法推送條目。hostd 的投影：

```jsonc
// HostProjection（participant.prepare 的 target）
{ "role": "hostd",
  "entries": [
    { "entry_id": "ent-...", "package": "ditto.svc.tasks", "version": "1.0.0",
      "module_path": "/home/.../ditto/packages/sha256/<hash>/dist/index.mjs",
      "data_dir": "/home/.../ditto/plugin-data/ditto.svc.tasks",
      "config": { ... }, "disabled": false,
      "provides": ["desktop.tasks.list", "desktop.tasks.add", "desktop.tasks.complete"],
      "hot_swap": "controlled_handoff", "health_timeout_ms": 2000, "cleanup_timeout_ms": 5000 } ] }
// HostObservation（participant.state 的 observed）
{ "role": "hostd",
  "entries": [ { "entry_id": "ent-...", "fiber_state": "active", "mode": "active",
                 "waiting_for": null, "failure": null } ] }
```

- `module_path` 必須位於 `$XDG_DATA_HOME/ditto/packages/sha256/` 之下（開發建置另允許 `DITTO_DEV_PACKAGES` 指定的來源樹）；hostd 不從 `node_modules`、相對路徑或其他絕對路徑載入。**這不是安全邊界**，只讓「載入的是哪個版本」可以驗證。
- `data_dir` 由 Core 分配，插件只能經 `ctx.ditto.data` 在其中讀寫。
- 開機與重建：`origin = "participant_boot"`，prepare → commit，沒有 ChangeSet。

hostd 內**只有交易層**可以呼叫 `ctx.loader.create/update/remove`。

### 4.1 候選策略（D-32）

`host.hello.strategy` 宣告這個 hostd 版本採用哪一種；**兩者不混用**。

| | `isolate_rebuild`（策略 A，預設） | `in_place`（策略 B） |
| --- | --- | --- |
| prepare | 在 isolate 子 realm 掛載候選並跑健康檢查；現役不動 | 靜態檢查（模組可載入、設定 schema、`inject` 名稱有供應者） |
| commit | 舊實例 drain／handoff → dispose → dispose 候選 → 主 realm 以相同設定重建 → 第二次健康檢查 | 舊實例 drain／handoff → dispose → 主 realm 掛載 → 健康檢查 |
| commit 後失敗 | 在主 realm 重掛舊實例 | 同左 |
| 使用者可見結果 | 候選失敗時「現役不受影響」 | 候選失敗時「已回復，中間有 N ms 服務空窗」——**不得寫成即時替換** |

實作後補充（G1-HOST，D-32 試作）：

- **策略 A 在 commit 也有空窗。** 「現役不受影響」只描述 prepare：commit 時舊實例 dispose 到主 realm 重建並通過健康檢查之間，該能力沒有租約。這段時間的呼叫得到 `unavailable`（`not_bound`），不排隊；文案不得把策略 A 寫成零中斷。
- **清理不收斂的插件在策略 A 下無法啟用。** Cordis 不能把 isolate 中的實例升格到主 realm，所以 commit 的第一步是 dispose 候選；候選超過 `cleanup_timeout_ms` 仍未清理完時，該項 commit 回 `failed`（`candidate_cleanup_timeout`），此時舊實例還沒被動，變更回復。舊實例本身清理逾時則是 `cleanup_timeout`；清理從未完成的 entry 之後不會再被掛載第二次（`entry_faulted`，L-08 負例）。
- **回復會重掛。** commit 後任何一步失敗，rollback 在主 realm 以基底投影重掛舊實例；重掛前的清理逾時時該項回報 `not_restored`（`cleanup_timeout`），變更結果為 `partially_applied`，不假裝已回復。
- **`resync_required` 是保留事件名。** 事件橋佇列滿時，hostd 丟棄新事件，並在佇列中放一個（且只放一個）名為 `resync_required` 的 `host.event`；插件自己不能發這個名字（`invalid_params`），它也不需要 manifest 宣告。Core 收到後對訂閱了該主題的呼叫方送 `resync_required`。
- 程式位置：`packages/host-runtime/src/loader/transaction.ts`、`…/events.ts`；試作數據見 [D-32](../../.agents/notes/decisions/2026-09-27-d32-host-candidate-strategy.md)（策略 A 的 commit 空窗程序內 p50 0.72 ms、p95 1.17 ms）。

### 4.2 候選不得取得正式獨占資源

- `ctx.ditto.mode === 'candidate'` 時，`ctx.ditto.capabilities.register` 只在本地記錄，commit 時才一次送出 `host.capability.register`。
- 候選 entry（Core 的條目表中狀態為 `candidate`）若送出 `host.capability.register` 或呼叫任何會綁定獨占資源的能力 → `conflict`（`candidate_cannot_claim`）。這是 L-03 的故障注入負例。

## 5. 能力註冊與租約

```jsonc
// → host.capability.register（_meta.on_behalf_of = "ent-..."）
{ "capability_id": "desktop.tasks.list", "version": "1.0.0" }
// ←
{ "lease_id": "lease-...", "ttl_ms": 10000, "generation": 3 }
// → host.capability.revoke
{ "lease_id": "lease-..." }
// → host.lease.renew（每 3 秒一次，批次）
{ "lease_ids": ["lease-...", "..."] }
// ←
{ "renewed": ["lease-..."], "expired": [] }
```

Core 在註冊時檢查：entry 已分派且不是候選；`capability_id` 在該 entry 的 manifest `provides` 中；若是 `desktop.*` 能力，必須在靜態目錄中且 `provider = hostd`；插件命名空間的能力（`plugin.<package>.*`）描述子來自 manifest；單一供應者（同一 `capability_id` 同時最多一個有效租約，否則 `conflict`／`single_provider_taken`）。

租約逾期（沒有續約）→ Core 撤銷綁定、能力轉 `unavailable`（`lease_expired`）。舊 generation 的 `lease_id` 一律無效（L-07 負例）。

## 6. 轉送呼叫

呼叫方對 `hostd` 能力的請求由 Core 授權後轉送：

```jsonc
// Core → hostd：host.invoke
{ "lease_id": "lease-...", "entry_id": "ent-...", "capability_id": "desktop.tasks.add",
  "input": { "text": "買牛奶" }, "caller": "shell", "operation_id": "op-...", "deadline_ms": 2000 }
// ← 一般結果物件（不含 _meta）或錯誤
```

hostd 回應中的任何 `readback_verified` 都被忽略。寫入型能力由 **Core 自己呼叫 readback** 驗證（例如 `tasks.add` 之後 Core 以 `tasks.list` 確認該項存在）。

## 7. 事件橋

```jsonc
// → host.event（_meta.on_behalf_of = "ent-..."）
{ "name": "tasks/changed", "payload": { ... }, "coalesce_key": "tasks/changed" }
```

- 跨程序事件必須在 manifest 的 `events` 宣告（名稱、schema、`coalesce` 政策）；未宣告的事件 → `invalid_params`。
- hostd 端每個 entry 佇列上限 256；`coalesce: latest` 的事件在佇列內以 `coalesce_key` 合併；佇列滿時丟棄**並**送出一次 `resync_required`，不靜默丟失。
- Core 把事件放進同一個 `EventBroker`，以 `host_event` 的形式發給訂閱了對應主題的呼叫方，`seq` 與其他事件共用。

## 8. 條目狀態與資源

```jsonc
// → host.entry_state（fiber 狀態變化時送出，最多每 250 ms 一次）
{ "entries": [ { "entry_id": "ent-...", "fiber_state": "pending", "waiting_for": ["tasksStore"],
                 "failure": null, "effects": 7, "timers": 1, "subscriptions": 2, "capabilities": 3 } ] }
// → host.resources（每 10 秒）
{ "heap_used": 12345678, "external": 234567, "array_buffers": 34567 }
```

- 程序層級的 PSS、RSS、CPU、執行緒與 fd **由 Core 讀 `/proc/<pid>/`**，不採信 hostd 自報。
- `heap_used`、`external`、`array_buffers` 三者分列，**不相加、不與 PSS 相加**（NFR-15）。
- 每個 entry **沒有**記憶體數字；插件中心顯示「與 N 個插件共用宿主，無法單獨計量」（RUN-08）。

## 9. 權限撤銷

Core 撤銷一項屬於 `host:<entry_id>` 的授予時送出通知 `host.permission_revoked { entry_id, grant_id, scope }`。插件須經 `ctx.ditto.permissions` 處理（例如 tasks 停止監看檔案），否則 Core 在 5 秒後以 `origin = supervisor` 的 ChangeSet 停用該 entry。

## 10. 回收

hostd **從不因閒置而退出**。只有在四件事同時成立時 Core 才回收它：沒有啟用中的 `host: cordis` 條目、沒有活躍訂閱、沒有排程工作、沒有有效租約；回收後 30 秒內完成，重新啟用條目時重建。
