# Core 協定 0.2

| 欄位 | 內容 |
| --- | --- |
| 版本 | `0.2.0`（`ditto_protocol::PROTOCOL_VERSION`） |
| 狀態 | 實作中。M3 起依 D-35 凍結：之後只允許新增**選用**欄位；破壞性變更升 0.3 |
| 型別權威 | `crates/ditto-protocol`；產物 `schema/*.json`、`packages/protocol/src/generated/` |
| 前一版 | 0.1.0（G0）。**不相容**：0.1 客戶端一律以 `protocol_version_unsupported` 拒絕，不做相容層 |

## 1. 傳輸

沿用 G0（D-14）：`$XDG_RUNTIME_DIR/ditto/core.sock`（`DITTO_RUNTIME_DIR` 可覆寫），0600，換行分幀 JSON-RPC 2.0，單行上限 1 MiB。

0.2 的新東西是**雙向請求**：Core 會在同一條連線上對 Shell、hostd 發出請求（`participant.*`、`host.invoke`），id 一律以 `core-` 開頭；客戶端回一般的 JSON-RPC 回應。客戶端自己的請求 id 不得以 `core-` 開頭，否則該請求以 `invalid_params` 拒絕。

## 2. 握手與呼叫方

```jsonc
// → core.handshake
{ "protocol_version": "0.2.0",
  "client": { "kind": "quickshell", "version": "0.2.0" },
  "auth": { "token": "<launcher token>" } }
// ←
{ "protocol_version": "0.2.0", "catalog_revision": 3, "server": "ditto-core/g1-bound",
  "compositor": "wayfire 0.11.0", "mode": "normal", "subject": "shell",
  "connection_id": "conn-7", "host_generation": null }
```

身分由受控啟動器綁定（PID ＋ `/proc/<pid>/exe` ＋ kind ＋ version），**不由訊息內容決定**。`kind` 對應到授權主體：

| `client.kind` | 主體（subject） | 說明 |
| --- | --- | --- |
| `quickshell` | `shell` | 主 Shell；同時是交易參與者 |
| `dittoctl` | `cli` | 一般 CLI |
| `dittoctl-rescue` | `cli:rescue` | 救援子命令；只能呼叫救援允許的能力 |
| `rescue-shell` | `rescue_ui` | `shell/rescue/` 的救援介面 |
| `hostd` | `hostd` 連線；每個請求再以 `_meta.on_behalf_of` 決定 `host:<entry_id>` | 見 [host-protocol.md](host-protocol.md) |
| `agent` | `agent` | G1 為 Agent 替身，G2 為 Agent |
| `lock` | `lock` | 鎖定客戶端 `ditto-lock` |

開發模式（`--development`，共用 token）照 G0：它**不是身分證據**，`client.kind` 仍依上表對應主體，只供本機開發與 CI 契約測試。

`mode` 是 `normal` 或 `rescue`。救援模式下依賴 Cordis 的能力 `availability` 為 `rescue_mode`。

## 3. 請求與結果的 `_meta`

```jsonc
"_meta": { "protocol_version": "0.2.0", "operation_id": "op-...", "deadline_ms": 2000,
           "on_behalf_of": "ent-..." }   // 只有 hostd 連線可以、也必須帶 on_behalf_of
```

```jsonc
"_meta": { "observed_seq": 412, "profile_revision": "rev-01J9...",
           "readback_verified": true, "not_cancellable": true, "handled_us": 8423 }
```

`handled_us` 是 Core 以單調時鐘量的處理時間（微秒）：從讀到請求到寫出這個結果。`readback_verified` 為 `true` 的寫入，它涵蓋受理到回讀完成，是 NFR-03 的量測值；它不含呼叫端的往返，呼叫端不得拿自己的時鐘取代它。

0.1 的 `ResultMeta.revision` 拆成兩個欄位：`observed_seq` 是觀測事件的序號（G0 的語意），`profile_revision` 是作用中 Profile 的 head revision（Core 尚未載入 Profile 時為 `null`）。

`params` 裡出現 `plugin_id`、`client_id` 或 `subject` 一律 `identity_rejected`（G0 規則延續）。

## 4. 錯誤

封閉集合，0.2 新增一個：

| name | code | 0.2 的用法 |
| --- | --- | --- |
| `unsupported` | -32000 | 平台或合成器沒有路徑 |
| `invalid_params` | -32001 | |
| `not_found` | -32002 | 包括撤銷所屬 Profile 已刪除的變更（§8.6） |
| `permission_denied` | -32003 | **G1 開始實際回傳**；`data.reason` ∈ `not_granted`、`policy_denied`、`approval_unavailable` |
| `timeout` | -32004 | 可帶 `outcome: "unknown"` |
| `cancelled` | -32005 | |
| `conflict` | -32006 | `data.reason` ∈ `base_revision_stale`、`candidate_cannot_claim`、`single_provider_taken`、`undo_blocked_by_newer_change`、`profile_in_use`、`change_in_progress`、`readback_mismatch` |
| `unavailable` | -32007 | `data.reason` 見 §6 |
| `protocol_version_unsupported` | -32008 | |
| `identity_rejected` | -32009 | 含偽造 `on_behalf_of` |
| `preflight_rejected` | **-32010** | `data.reasons[]`：預檢的**全部**失敗原因（§8.3） |
| `internal` | -32099 | |

`RpcError` 多一個選用欄位 `data`（物件）。產品語言的說明**不在錯誤裡**：`data` 帶的是原因碼與翻譯鍵，Shell 依語系呈現；`message` 是診斷層文字。

## 5. 能力描述子

欄位與 G0 相同（`capability_id`、`version`、`input_schema`、`output_schema`、`errors`、`resource_scope`、`cancellable`、`idempotency`、`timeout_ms`、`readback`、`claimable`、`provider`、`availability`），0.2 的變化：

- **`resource_scope` 不得為空**（目錄 gate 的第五項檢查）。值見 §7。
- `provider` ∈ `core`、`compositor-adapter`、`system`、`shell`、`hostd`。執行期目錄中由 hostd 提供的能力會寫成 `hostd:<entry_id>`。
- `availability` 新增 `depends_on_provider`：

```jsonc
{ "kind": "depends_on_provider", "slot": "svc.tasks", "available": false,
  "reason": "host_unavailable", "entry_id": null }
```

`catalog_revision` 升為 3。目錄清單以 `schema/catalog.json` 為準。

## 6. 不可用原因（`unavailable` 與 `availability.reason`）

封閉集合：`compositor_offline`、`host_unavailable`、`host_crash_loop`、`lease_expired`、`not_bound`、`rescue_mode`、`recovering`、`system_unavailable`、`participant_unavailable`、`session_locked`、`storage_full`、`storage_error`（後兩者：寫入被儲存層拒絕，**沒有任何東西被改變**）。

## 7. 授權：主體與資源範圍

每一個能力呼叫都經過 Core 的 `authorize(subject, capability, resource)`，GUI 與 Agent 共用同一個入口與同一張授予表。決定是封閉集合：`allowed`、`denied`、`needs_approval`。G1 沒有應答者，`needs_approval` 一律回 `permission_denied`（`approval_unavailable`），**失敗即拒絕**。

| scope | shell | cli | cli:rescue | rescue_ui | host:<entry> | agent | lock |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `desktop.read`（目錄、Profile、歷史、面板、布局等讀取） | 允許 | 允許 | 允許 | 允許 | 允許 | 允許 | 拒絕 |
| `desktop.config`（外觀、布局、面板替換等有界可逆的變更） | 允許 | 允許 | 拒絕 | 拒絕 | 需授予 | 允許 | 拒絕 |
| `profiles.delete`（刪除已儲存的設定檔，無法復原；與 `desktop.config` 一起要求） | 允許 | 允許 | 拒絕 | 拒絕 | 拒絕 | 需授予 | 拒絕 |
| `desktop.windows.read` | 允許 | 允許 | 允許 | 允許 | 需授予 | 需授予 | 拒絕 |
| `desktop.windows.control` | 允許 | 允許 | 允許 | 允許 | 需授予 | 需授予 | 拒絕 |
| `desktop.rescue`（停用插件、恢復最近可用組合、回到一般 Shell） | 允許 | 允許 | 允許 | 允許 | 拒絕 | 拒絕 | 拒絕 |
| `plugins.manage` | 允許 | 允許 | 拒絕 | 拒絕 | 拒絕 | 需授予 | 拒絕 |
| `permissions.manage` | 允許 | 允許 | 拒絕 | 拒絕 | 拒絕 | 拒絕 | 拒絕 |
| `session.power` | 允許 | 允許 | 允許 | 拒絕 | 拒絕 | 拒絕 | 拒絕 |
| `session.lock` | 允許 | 允許 | 允許 | 允許 | 拒絕 | 需授予 | 允許 |
| `notifications.read` | 允許 | 允許 | 拒絕 | 拒絕 | 需授予 | 需授予 | 拒絕 |
| `tasks.read`、`tasks.write` | 允許 | 允許 | 拒絕 | 拒絕 | 需授予 | 需授予 | 拒絕 |
| `apps.launch` | 允許 | 允許 | 拒絕 | 允許 | 需授予 | 需授予 | 拒絕 |
| `files:<grant>` | 需授予 | 需授予 | 拒絕 | 拒絕 | 需授予 | 需授予 | 拒絕 |
| `core`（只有 Core 自己呼叫，例如通知策略詢問） | 拒絕 | 拒絕 | 拒絕 | 拒絕 | 拒絕 | 拒絕 | 拒絕 |
| `network`、`process.exec`、`clipboard`、`screenshot` | 需授予 | 需授予 | 拒絕 | 拒絕 | 需授予 | 需授予 | 拒絕 |

「需授予」＝有有效的 `permission_grants` 列（`revoked_at` 為空、未過期）就允許，否則 `needs_approval` → 拒絕。`agent` 的 `desktop.config` 為允許，是因為 PRD 把有界可逆的配置變更列為預設已授權；**它仍然只能經 ChangeSet 寫入**。

每個決定都寫入 `audit_log`。

## 8. 變更交易

### 8.1 ChangeSet 與 op

```jsonc
// → desktop.changes.propose
{ "profile_id": null,                 // null = 作用中的 Profile
  "base_revision": "rev-01J9...",     // 必填（CFG-06）
  "mode": "apply",                    // apply | preview（試看，§8.5）
  "idempotency_key": "gui-7f3...",
  "surface": "composition_center",    // GUI 的哪個畫面；只用於歷史描述
  "ops": [
    { "op": "bind_slot", "slot": "ui.dock", "from": "ent-A", "to": "ent-B" },
    { "op": "set_value", "path": "/appearance/tokens/accent", "before": "#b9a4ff", "after": "#9d7bff" },
    { "op": "add_entry", "entry": { "package": "ditto.dock.pill", "version": "1.0.0", "host": "qml",
                                     "config": {}, "disabled": false }, "slot": "ui.dock" },
    { "op": "remove_entry", "entry_id": "ent-A" },
    { "op": "set_entry_config", "entry_id": "ent-B", "before": {...}, "after": {...} },
    { "op": "set_entry_disabled", "entry_id": "ent-B", "disabled": true },
    { "op": "switch_profile", "to_profile": "prf-...", "to_revision": null }
  ] }
```

- `before` 是**意圖比對**：Core 在 `validated` 時以基底 revision 的實際值重填；呼叫方給了 `before` 且與實際值不同 → `stale_intent`。
- `add_entry` 的 `entry_id` 由 Core 產生（`ent-<ULID>`），跨 revision 穩定；`slot` 選填，給了就在同一個 op 裡綁定。`slot` 若是多條目區域（`ui.status_item`），條目改為加入該區域（記在條目的 `area`），不綁定 `slots`；`bind_slot` 不接受區域（`schema_invalid`，`area_is_not_a_slot`）。區域語意見 [profile-document.md](profile-document.md#多條目區域uistatus_item)。
- `switch_profile` 必須單獨出現，並從作用中的 Profile 提出：`profile_id` 省略或等於作用中的 Profile，`base_revision` 是它的 head。切換改變的是桌面，預檢以作用中的 Profile 為基準；指名其他 Profile 時以 `precondition_failed`（`switch_not_from_active_profile`，`detail` 有 `profile_id` 與 `active_profile`）拒絕，紀錄留在被指名的 Profile 下。
- 其他 op 的 `profile_id` 指名**非作用中**的 Profile 時，這筆 ChangeSet 只改那個 Profile 的文件，因為桌面顯示的是作用中的 Profile：預檢照常執行（含 `config_schema`），通過後寫入 revision、移動該 Profile 的 head，**不呼叫任何參與者**（§9 的 prepare、commit、readback 都沒有）。紀錄為 `state = committed`、`result = succeeded`，`items[]` 為空，並帶 `saved_only`（見 §8.2）；`hot_swap_level` 只是記錄，不排程下次登入。不倒數確認：`mode: preview` 或需要限時回復的 op 也一樣，`confirmation` 為 `not_required`。生成插件的資料不搬動，桌面的 revision 不變，也不開始觀察期（last-known-good 不更新）；`profile_changed` 的 `active` 為 `false`。之後切換到這個 Profile，切換本身才把它投影到桌面。撤銷、限時回復與救援還原以它們作用的 Profile 判斷，規則相同（§8.5、§8.6）。
- 主體與來源由連線決定：`shell` → `gui{surface}`、`cli` → `cli`、`agent` → `agent_standin`（G1）、救援 → `rescue`、監督 → `supervisor`、計時回復 → `timed_revert`、撤銷 → `undo`、匯入 → `import`。呼叫方不能指定來源。

寫入配置的能力（`appearance.set` 等）**都是 ChangeSet 的包裝**：Core 在內部建立只有一個 op 的 ChangeSet，回傳同一種 `ChangeRecord`。

### 8.2 狀態與結果類別

```
draft ─► validated ─► prepared ─► applying ─► verifying ─► committed
  │                     │            │            │
  ▼                     ▼            ▼            ▼
rejected             aborted   rolling_back ─► rolled_back ｜ partially_applied
                                                     │
                                                     ▼
                                                  unknown    （只在恢復時）
```

十二個狀態；每個轉移在 Core 內以單一 SQLite 交易寫入，**先寫紀錄、再做副作用**；非法轉移由 trigger 擋下。終態對應結果類別（`result`）：

| 終態 | `result` |
| --- | --- |
| `committed` | `succeeded`；每一項都是 `scheduled` 時為 `scheduled` |
| `rejected`、`aborted`、`rolled_back` | `failed` |
| `partially_applied` | `partial` |
| `unknown` | `unknown` |

回應與歷史**永遠同時帶** `state` 與 `result`。`result = partial` 時，`items[]` 逐項列出 `applied`、`not_restored` 與原因。

`saved_only = { "reason": "inactive_profile", "profile_name": "<名稱>" }`：只出現在「寫進非作用中的 Profile、沒有套用到桌面」的已提交變更（§8.1），`ChangeRecord` 與 `ChangeSummary`（`changes.list`、`change_updated`）都帶；其他紀錄省略這個欄位。store schema 6 之前寫入的紀錄都不會有它；沒有 `saved_only` 並不代表變更已套用到桌面，仍要照舊看 `state` 與 `result`。`result` 仍是 `succeeded`：對那個 Profile 的編輯已完成，`saved_only` 說的是它去了哪裡。`reason` 是封閉集合，目前只有 `inactive_profile`；`profile_name` 是讀取紀錄時該 Profile 的名稱（改名後跟著變）。介面不得把它寫成「已套用」，要說已存到哪個組合、桌面沒有改變、切換到該組合時才會套用；那個 Profile 還在時，這種變更照常可以撤銷（§8.6）。這是選用的新增欄位，不新增結果類別或原因碼（store schema 6 的 `changesets.saved_only`）。

`saved_only.profile_deleted = true`（#171）：那個 Profile 之後被刪除了。刪除是軟刪除，紀錄與 `profile_name` 都還讀得到；`profile_deleted` 與 `profile_name` 在同一次讀取中由該 Profile 的 `deleted_at` 算出，未刪除時省略（不會出現 `false`），不寫入 store、不需遷移。已刪除的 Profile 不能再切換過去，所以這筆變更不會再套用，撤銷也會被拒絕（§8.6）；介面要說它曾存到哪個組合、那個組合已刪除，不得再說切換時會套用或可以撤銷，也不提供撤銷入口。這同樣是選用的新增欄位，不新增結果類別或原因碼。

`result = scheduled`：變更已存成 revision（`state = committed`、head 已移動），但**還沒有任何東西生效**——`items[]` 全部是 `scheduled`，原因 `next_login`（§8.4 的 `session_restart`）或 `rescue_mode`（救援模式下只動到 hostd 的變更，回到一般模式時生效）。介面只能呈現為「待下次登入套用」或「回到一般模式後套用」，不得寫成已套用。判定規則在 `ditto_protocol::change::result_of`，store 的 `result_kind` 欄與回應用同一條。

### 8.3 預檢

`draft → validated` 依序執行十三項，**全部跑完**才回報（一次看到所有問題），任一失敗即 `rejected`，回應為 `preflight_rejected`，`data.reasons[]` 每項：

```jsonc
{ "code": "single_provider_violation", "op_index": 0,
  "detail_key": "preflight.single_provider_violation", "detail": { "slot": "ui.dock" } }
```

原因碼（封閉）：`base_revision_stale`、`schema_invalid`、`stale_intent`、`package_missing`、`integrity_mismatch`、`protocol_incompatible`、`dependency_missing`、`dependency_cycle`、`version_conflict`、`declared_conflict`、`single_provider_violation`、`shortcut_conflict`、`command_conflict`、`permission_required`、`precondition_failed`、`budget_exceeded`。

條目 `config` 的 `schema_invalid` 以 `detail.why` 區分（規則見 [manifest.md「config 的檢查」](manifest.md#config-的檢查)）：

| `why` | 意思 | `detail` 的其他欄位 |
| --- | --- | --- |
| `config_not_object` | `config` 不是 JSON 物件 | 由 `add_entry`／`set_entry_config` 產生時無；切換 Profile 時有 `entry_id` |
| `config_schema_violation` | `config` 不符該套件版本的 `config_schema` | `entry_id`、`package`、`version`；`pointer` 是第一處不符的 JSON pointer（RFC 6901，`""` 為整個 `config`）；`violations[]` 依序列出最多 16 項 `{pointer, keyword, message}`，`violation_count` 為總數。`message` 是診斷用的英文，不是產品文案 |
| `config_schema_unsupported` | `config_schema` 超出 SDK 允許的子集，Core 不據以判定。安裝時已會拒絕這種套件，只有之前安裝的才會走到這裡 | `entry_id`、`package`、`version`；`schema_pointer` 指向 `config_schema` 中出問題的位置；`message` |

`op_index` 指向寫入該 `config` 的 op：新條目是它的 `add_entry`，既有條目是最後一個 `set_entry_config` 或 `upgrade_entry`；切換 Profile 時沒有 `op_index`。

預檢**不呼叫任何模型，也不呼叫任何參與者的副作用方法**。被拒絕的 ChangeSet 仍然寫入歷史（`rejected`），所以「原配置未改變」有紀錄可查（AT-05）。

### 8.4 熱換等級

`hot_swap_level` ∈ `instant`、`controlled_handoff`、`host_restart`、`session_restart`。Core 取「manifest 宣告值」與「op 類型推導值」的較高者：

| op 的對象 | 推導值 |
| --- | --- |
| `/appearance/*`、`/avatar/*`、`ui.*` slot、`host: qml` 條目 | `instant` |
| `layout.strategy` slot、`/layout/*`、`svc.*` slot、`host: cordis` 條目 | `controlled_handoff` |
| hostd 的 Node 或 vendored Cordis 版本 | `host_restart` |
| 合成器啟動設定中無法經 IPC 變更的項目 | `session_restart`：**不執行**，存成 revision 供下次登入掛載；`state = committed`、`result = scheduled`，每一項 `scheduled`（`next_login`），參與者不會收到 prepare |

### 8.5 回讀、提交、限時回復與試看

- `verifying`：Core 對每個 op 讀回參與者的**觀測**（Shell 的掛載回報、hostd 的條目狀態與 Core 自己的租約表、合成器的回讀），與目標比對。**不採信參與者自述的成功。**
- 全部一致 → 同一個 SQLite 交易內 INSERT 新 revision、移動 head、`committed`，發布 `change_updated` 與 `profile_changed`。
- 限時回復（CHG-09）：主要快捷鍵、輸出縮放與排列、鍵盤配置、減少透明度關閉。提交後 `confirmation = { "state": "pending", "deadline": "<ISO 8601>" }`，15 秒內 `desktop.changes.confirm` 才轉為 `confirmed`；逾時由 Core 的計時器自動產生 `origin = timed_revert` 的回復變更。**Shell 死掉不會中斷倒數。** 倒數期間若已切換到別的 Profile，回復變更只改原 Profile 的文件，桌面不動（§8.1）。
- 試看（`mode: preview`）：與限時回復同一機制，差別只在「一律倒數」與歷史中的來源描述。

### 8.6 撤銷

`desktop.changes.undo { change_id }` 產生新的 ChangeSet（`origin = undo`），目標是該變更之前的內容：

- 被撤銷的是該 Profile 最新一筆已提交的變更 → 目標 = 它的父 revision。
- 不是最新，且後續變更碰過同樣的路徑 → `conflict`（`undo_blocked_by_newer_change`），產品語言為「請先撤銷較新的變更」。
- 不是最新，但沒有路徑重疊 → 以反向 op 套用到目前的 head。
- 該變更所屬的 Profile 已刪除（#171）→ `not_found`，`message` 說明那個組合已刪除、這筆變更不能撤銷。在寫入任何紀錄之前拒絕，不呼叫參與者。撤銷從已刪除的 Profile 切走的切換也一樣：沒有組合可以切回去。

被撤銷的變更所屬 Profile 目前不是作用中的 Profile 時，撤銷只改那個 Profile 的文件，不呼叫參與者（§8.1）。撤銷切換 Profile 則是一次從作用中 Profile 出發的切換，照常套用到桌面。`desktop.rescue.restore_last_good` 指名非作用中的 Profile 時也一樣，只改它的 head。

撤銷放回的條目 `config` 若與所放回的 revision 中的套件、版本與 `config` 完全相同，預檢不再依 `config_schema` 檢查（[manifest.md「config 的檢查」](manifest.md#config-的檢查)）；限時回復與救援還原相同。

### 8.7 查詢與冪等

- `desktop.changes.get` 以 `change_id` 或該變更任一 `operation_id` 查詢（CHG-07）。
- 同一 `idempotency_key` 重送 → 回傳既有的 `ChangeRecord`，不產生第二筆。
- `desktop.changes.propose` 會等到終態或 `pending_confirmation` 才回應，上限為 `deadline_ms`（預設 15 秒，最多 30 秒）；逾時回傳目前的紀錄（非終態），呼叫方以 `changes.get` 或 `change_updated` 事件追蹤。**逾時不是失敗，也不重送**。

## 9. 交易參與者方法

Shell、hostd 與合成器轉接在交易中扮演同一種角色，Core 對它們使用同一組方法。Shell 與 hostd 在自己的連線上接收這些請求；合成器轉接在 Core 程序內實作同一個介面。

| 方法 | 參數 | 回應 | 逾時（提案值） |
| --- | --- | --- | --- |
| `participant.prepare` | `{ change_id, origin, target: Projection }` | `{ items: [{ key, status: ready｜failed｜pending, reason?, missing? }] }` | 10 s |
| `participant.commit` | `{ change_id }` | `{ items: [{ key, status: applied｜failed, reason? }] }` | 5 s |
| `participant.abort` | `{ change_id }` | `{}`，**等所有候選清理完成才回應** | 5 s |
| `participant.rollback` | `{ change_id }` | `{ items: [{ key, status: restored｜not_restored, reason? }] }` | 5 s |
| `participant.state` | `{ change_id? }` | `{ change: { change_id, phase }｜null, observed: Observation }` | 2 s |

`target` 是該參與者負責的**完整期望狀態**（投影），不是差異。參與者自己比對目前狀態決定要換什麼；這讓開機同步、回復與一般變更是同一條路：

- 開機或重連：Core 以 `origin = "participant_boot"` 推送目前 head 的投影（prepare → commit），沒有 ChangeSet。
- 回復：Core 以基底 revision 的投影呼叫 `participant.rollback`；參與者保留舊實例直到 commit 被確認，所以 rollback 是恢復舊實例，不是重新建立。

`pending` 在 prepare 等同未就緒；Core 有界等待後判定失敗。參與者在交易中途失去連線 → Core 視為該參與者失敗，走回復；重連的參與者收到同一 `change_id` 的 `participant.state` 回答 `phase: "unknown"`（不記得）時，Core 以回讀判定。

### 9.1 Shell 的投影與觀測

```jsonc
// ShellProjection
{ "role": "shell",
  "appearance": { "theme": "soft-jelly", "tokens": { "accent": "#b9a4ff" }, "reduced_motion": false,
                  "reduced_transparency": false, "low_power_style": false, "locale": "zh-TW" },
  "avatar": { "enabled": true, "hidden": false, "scale": 1.0, "animations": true },
  "slots": [ { "slot": "ui.dock", "entry_id": "ent-...", "package": "ditto.dock.pill", "version": "1.0.0",
               "qml_url": "file:///home/.../packages/sha256/<hash>/qml/DockPill.qml", "config": {} } ],
  "shortcuts": [ { "chord": "Super+Space", "command": "launcher.toggle" } ] }
// ShellObservation（participant.state 的 observed，以及 shell.report 的內容）
{ "role": "shell",
  "mounts": [ { "slot": "ui.dock", "entry_id": "ent-...", "mounted": true, "visible": true } ],
  "appearance": { ... }, "avatar": { ... } }
```

Shell 在每次掛載變化後主動呼叫 `shell.report`（與 `observed` 同形），Core 以最新的回報回答 `desktop.panels.list`。readback 規則：`bind_slot(ui.x → E)` 要求 `mounts` 中 `ui.x` 的 `entry_id = E` 且 `mounted = visible = true`；`/appearance/*` 要求觀測到的 `appearance` 與目標在 JSON 上相等。

多條目區域：投影在單一 slot 的綁定之後，為區域的每個未停用成員各附一筆綁定（`slot` 是區域名稱，各有自己的 `entry_id`），順序即 Profile 的條目順序。Shell 把每個成員當成獨立的單元走 prepare／commit／rollback：prepare、commit、rollback 的項目 `key` 是成員的 `entry_id`（單一 slot 仍是 slot 名稱）；一個候選載入失敗只讓這次變更中止，已掛載的成員不受影響。觀測中每個成員各有一筆 `mounts`（`slot = "ui.status_item"`、各自的 `entry_id`）；`visible` 表示它已放進畫面上的狀態區（頂部面板提供的 `statusRegion`，面板沒有提供或未掛載時為 Shell 自己的狀態條），不只是 `shown`。readback 逐成員比對 `(slot, entry_id)`，判定的鍵是 `entry_id`；Profile 已移除的成員仍掛著即不一致。`desktop.panels.list` 為每個未停用成員列一列（`bound_entry` 為該成員），再列出仍掛著但已不是成員的項目（`bound_entry = null`）。狀態項目是同程序的可信 QML，沒有隔離；它們自己的計時器屬於它們，Shell 擺放它們不經任何 RPC，也不在動畫熱路徑上。

### 9.2 hostd 的投影與觀測

見 [host-protocol.md §4](host-protocol.md#4-條目推送與交易)。

## 10. 事件

`desktop.events.subscribe { after_seq?, topics? }`；`topics` 未給時為 `["desktop"]`（G0 語意）。可選主題與所需 scope：

| topic | 事件 | 所需 scope |
| --- | --- | --- |
| `desktop` | `window_*`、`workspace_*`、`output_*` | `desktop.windows.read` |
| `changes` | `change_updated`、`profile_changed` | `desktop.read` |
| `plugins` | `capabilities_changed`、`panels_changed`、`jobs_updated` | `desktop.read` |
| `notifications` | `notification_posted`、`notification_closed` | `notifications.read` |
| `tasks` | `host_event`（`name` 以 `tasks/` 開頭） | `tasks.read` |
| `session` | `session_changed` | `desktop.read` |

所有主題共用一條 `seq`，所以一個訂閱看到的 `seq` 本來就會跳號（中間是它沒訂的主題）。缺口偵測因此看 `prev_seq`：每則通知帶 Core 送給**這個訂閱**的上一則通知的 `seq`（第一則連到訂閱回應中的 `seq`，即快照或重播所到的位置）；`prev_seq` 不等於客戶端手上最後一則的 `seq` 就是漏收，客戶端丟掉增量狀態、重新取快照並重訂。`resync_required` 的語意與 G0 相同（溢位、斷線、`permission_revoked`）。通知事件中的 `DesktopEventNotification.revision` 在 0.2 改名為 `profile_revision`（作用中 head，字串或 `null`）。

## 11. 能力群組

確切的描述子（schema、錯誤、`resource_scope`、逾時、`readback`、`claimable`）以 `schema/catalog.json` 為準。群組與寫入路徑：

| 群組 | 能力 | 寫入？ | readback |
| --- | --- | --- | --- |
| capabilities／outputs／workspaces／windows／events | G0 的 13 項 | 部分 | 同 G0 |
| profiles | `list` `get` `create` `duplicate` `rename` `delete` `diff` `export` `import_validate` `import` | 部分；**不產生內容變化的操作**（命名、刪除）不經 ChangeSet | `profiles.get` |
| changes | `propose` `get` `list` `cancel` `undo` `confirm` | 是 | `changes.get` |
| plugins | `list` `get` `inspect` `install` `remove` `diagnostics` | `install`／`remove` | `plugins.get` |
| permissions | `list` `check` `grant` `revoke` | `grant`／`revoke` | `permissions.list` |
| appearance | `get` `set` | `set`（ChangeSet 包裝） | `appearance.get` |
| panels | `list` | 否 | —（本身是 UI 替換的回讀） |
| launcher | `search` `list_apps` `launch` | `launch`（`claimable: false`） | `windows.list` |
| commands | `list` `invoke` | `invoke`（`claimable: false`） | `commands.list` |
| shortcuts | `list` | 否 | — |
| notifications | `list` `dismiss` `policy_status` | `dismiss` | `notifications.list` |
| notifications.policy | `decide`（scope `core`）`get` | 否 | — |
| layout | `get` | 否 | —（布局切換的回讀） |
| session | `state` `lock` `logout` `suspend` `poweroff` | 是（`claimable` 依能力） | `session.state` |
| jobs | `get` `list` `cancel` | `cancel` | `jobs.get` |
| tasks | `list` `add` `complete` `subscribe` | `add`／`complete` | `tasks.list` |
| rescue | `status` `disable` `restore_last_good` `resume_shell` | `disable`／`restore_last_good`（各自產生一筆 ChangeSet，來源 `rescue`）；`resume_shell` 不改 Profile：離開救援介面、清除監督者的救援請求並重新啟動一般 Shell，回讀為新 Shell 的連線（`shell_connected`） | `rescue.status` |

`desktop.plugins.install` 與「啟用」是兩件事：安裝只寫套件庫，啟用是另一筆 ChangeSet（`add_entry`），歷史分別記錄。

## 12. 控制方法（不在能力目錄中）

只有特定種類的連線可以呼叫，其他連線呼叫一律 `identity_rejected`：

| 方法 | 方向 | 誰 |
| --- | --- | --- |
| `shell.report` | Shell → Core | `quickshell` |
| `shell.command`（通知，無 id） | Core → Shell | —— |
| `host.*` | 見 host-protocol.md | `hostd` |
| `participant.*`、`host.invoke` | Core → 參與者 | —— |
